#!/usr/bin/env bash
# Local gate before a pull request or dev merge: the checks CI's analyze job
# runs, then the tests of what changed. CI still runs the whole suite
# (spec TEST-06) and the Android and Rust jobs.
#
# Usage: tool/gate.sh [--full | --matrix | --fast | --no-tests] [--base REF] [test files...]
#   (default)   the test files affected via Dart's transitive import/export/
#               part graph (tool/affected_tests.py), plus the architecture
#               scans in test/architecture/ (PR tier, excluding `matrix`);
#               changes to dependencies or root test config run the PR suite;
#               docs/tooling-only changes skip Dart format/analyze/tests
#   --full      the whole PR-tier suite (`-x matrix`)
#   --matrix    the nightly/l10n/route/theme matrix (`-t matrix`)
#   --fast      checks, architecture scans, and any explicit test files only
#   --no-tests  checks only
#   --base REF  what the change is measured from: the merge base of HEAD
#               and REF (default: closest of origin/dev or origin/main on
#               task/* branches, otherwise origin/main)
#   files       run these test files instead of the selection
#
# Every step runs even after one fails; the exit status is 1 when any
# failed, 2 on a usage error. Flutter and Dart must be on PATH.
#
# Where systemd-run is available the tests run under a memory cap
# (GATE_TEST_MEMORY; default 4G, 8G above 10 files besides the architecture
# scans or for the whole suite) and bounded concurrency
# (GATE_TEST_CONCURRENCY; default 4 under 4G, 6 under 8G). A killed child
# (frontend_server, flutter_tester) still leaves `flutter test` exiting 0, so
# the log is read for "did not complete" and "No tests ran." and the kernel
# log for an out-of-memory kill.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root" || exit 2

mode=changed
base_ref=""
explicit=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --full) mode=full ;;
    --matrix) mode=matrix ;;
    --fast) mode=fast ;;
    --no-tests) mode=none ;;
    --base)
      [[ $# -ge 2 ]] || { echo "gate: --base needs a ref" >&2; exit 2; }
      base_ref="$2"
      shift
      ;;
    -h | --help)
      sed -n '2,/^set -uo/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'
      exit 0
      ;;
    -*) echo "gate: unknown option $1" >&2; exit 2 ;;
    *) explicit+=("$1") ;;
  esac
  shift
done

for tool in flutter dart python3; do
  command -v "$tool" >/dev/null || { echo "gate: $tool is not on PATH" >&2; exit 2; }
done

if [[ -z "$base_ref" ]]; then
  base_ref="origin/main"
  branch="$(git symbolic-ref --quiet --short HEAD || true)"
  if [[ "$branch" == task/* ]] &&
    git rev-parse --verify --quiet refs/remotes/origin/dev >/dev/null &&
    git rev-parse --verify --quiet refs/remotes/origin/main >/dev/null; then
    mb_dev="$(git merge-base HEAD origin/dev 2>/dev/null || true)"
    mb_main="$(git merge-base HEAD origin/main 2>/dev/null || true)"
    if [[ -n "$mb_dev" && -n "$mb_main" ]]; then
      dist_dev="$(git rev-list --count "${mb_dev}..HEAD")"
      dist_main="$(git rev-list --count "${mb_main}..HEAD")"
      if ((dist_dev <= dist_main)); then
        base_ref="origin/dev"
      fi
    fi
  fi
fi

base="$(git merge-base HEAD "$base_ref")" ||
  { echo "gate: no merge base with $base_ref" >&2; exit 2; }

tmp_files=()
cleanup() {
  local f
  for f in "${tmp_files[@]}"; do
    [[ -n "$f" && -f "$f" ]] && rm -f "$f"
  done
}
trap cleanup EXIT

# Committed since the base, uncommitted, and untracked; deleted paths stay
# in the list (a deleted lib file still selects the tests that import it).
changed_list="$(mktemp -t gate-changed.XXXXXX)"
tmp_files+=("$changed_list")
{
  git -c core.quotepath=false diff --name-only "$base"...HEAD &&
    git -c core.quotepath=false diff --name-only HEAD &&
    git -c core.quotepath=false ls-files --others --exclude-standard
} > "$changed_list" && sort -u -o "$changed_list" "$changed_list" ||
  { echo "gate: cannot list the changed files" >&2; exit 2; }
mapfile -t changed < "$changed_list"

results=()
failed=0
step() {
  local name="$1"
  shift
  echo
  echo "== $name"
  if "$@"; then
    results+=("ok    $name")
  else
    results+=("FAIL  $name")
    failed=1
  fi
}

diff_check() {
  git diff --check "$base"...HEAD && git diff --check HEAD
}

selection_json="$(mktemp -t gate-affected.XXXXXX.json)"
tmp_files+=("$selection_json")
affected_mode="selected"
affected_reason=""
run_dart_checks=1
selected_tests=()
if python3 tool/affected_tests.py \
  --changed-list "$changed_list" \
  --include-architecture \
  --json > "$selection_json"; then
  affected_mode="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["mode"])' "$selection_json")"
  affected_reason="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["reason"])' "$selection_json")"
  dart_flag="$(python3 -c 'import json, sys; print("1" if json.load(open(sys.argv[1]))["run_dart_checks"] else "0")' "$selection_json")"
  run_dart_checks="$dart_flag"
  mapfile -t selected_tests < <(
    python3 -c 'import json, sys; print("\n".join(json.load(open(sys.argv[1]))["tests"]))' "$selection_json"
  )
  # mapfile produces 1 empty element for empty output; trim it cleanly.
  if [[ ${#selected_tests[@]} -eq 1 && -z "${selected_tests[0]}" ]]; then
    selected_tests=()
  fi
else
  results+=("FAIL  test selection (tool/affected_tests.py)")
  failed=1
fi

run_tests() {
  local memory="${GATE_TEST_MEMORY:-}" concurrency="${GATE_TEST_CONCURRENCY:-}"
  local log since status=0 file heavy=0
  if [[ -z "$memory" ]]; then
    for file in "${tests[@]}"; do
      [[ "$file" == test/architecture/* ]] || heavy=$((heavy + 1))
    done
    if [[ ${#tests[@]} -eq 0 || $heavy -gt 10 ]]; then memory=8G; else memory=4G; fi
  fi
  if [[ -z "$concurrency" ]]; then
    case "$memory" in
      [1-4]G) concurrency=4 ;;
      *) concurrency=6 ;;
    esac
  fi
  log="$(mktemp -t gate-test.XXXXXX.log)"
  since="$(date +%s)"
  local command=(flutter test --concurrency="$concurrency" "${test_args[@]}" "${tests[@]}")
  # A systemd-run whose system manager is unreachable (a container) fails
  # before running anything: probe it, and say when there is no cap.
  if command -v systemd-run >/dev/null &&
    systemd-run --scope --quiet -p "MemoryMax=$memory" true 2>/dev/null; then
    echo "memory cap $memory, concurrency $concurrency; log $log"
    systemd-run --scope --quiet -p "MemoryMax=$memory" -p MemorySwapMax=0 \
      "${command[@]}" 2>&1 | tee "$log"
    status=${PIPESTATUS[0]}
  else
    echo "systemd-run cannot create a scope here: running without a memory cap (concurrency $concurrency); log $log"
    "${command[@]}" 2>&1 | tee "$log"
    status=${PIPESTATUS[0]}
  fi
  if grep -q 'did not complete' "$log"; then
    echo "gate: a test file did not complete" >&2
    status=1
  fi
  if grep -q 'No tests ran' "$log"; then
    echo "gate: no tests ran" >&2
    status=1
  fi
  if command -v journalctl >/dev/null &&
    grep -qi 'out of memory' < <(journalctl -k --since "@$since" 2>/dev/null); then
    echo "gate: the kernel killed a process for memory during the run" \
      "(raise GATE_TEST_MEMORY or lower GATE_TEST_CONCURRENCY)" >&2
    status=1
  fi
  if [[ "$status" -eq 0 ]]; then
    rm -f "$log"
  fi
  return "$status"
}

step "git diff --check" diff_check
step "check_spec" python3 tool/check_spec.py
step "spec/test deletion audit" python3 tool/check_spec.py --audit-diff "$base"
step "verify_catalog (3D matrix)" python3 tool/dev_workbench/verify_catalog.py
step "dev_workbench unit tests" python3 -m unittest \
  tool/dev_workbench/test_assertions.py \
  tool/dev_workbench/test_catalog_matrix.py \
  tool/dev_workbench/test_server.py
step "affected_tests self-test" python3 tool/affected_tests.py --self-test
step "test budget" python3 tool/test_budget.py --base "$base"

if [[ "$mode" == "changed" && ${#explicit[@]} -eq 0 && "$run_dart_checks" == "0" ]]; then
  results+=("skip  dart format ($affected_reason)")
  results+=("skip  flutter analyze ($affected_reason)")
else
  step "dart format" dart format --output=none --set-exit-if-changed lib test
  step "flutter analyze" flutter analyze
fi

tests=()
test_args=()
whole_suite_reason=""
case "$mode" in
  none) results+=("skip  tests (--no-tests)") ;;
  full)
    whole_suite_reason="--full"
    test_args=(-x matrix)
    step "tests (PR whole suite, -x matrix)" run_tests
    ;;
  matrix)
    test_args=(-t matrix)
    tests=(test/locale_layout/)
    step "tests (matrix, -t matrix)" run_tests
    ;;
  fast)
    selection="$(mktemp -t gate-selection.XXXXXX)"
    tmp_files+=("$selection")
    if ! {
      printf '%s\n' test/architecture/*_test.dart
      if [[ ${#explicit[@]} -gt 0 ]]; then
        printf '%s\n' "${explicit[@]}"
      fi
    } | sort -u > "$selection"; then
      results+=("FAIL  test selection (fast)")
      failed=1
    fi
    mapfile -t tests < "$selection"
    step "tests (fast: ${#tests[@]} files)" run_tests
    ;;
  changed)
    if [[ ${#explicit[@]} -gt 0 ]]; then
      tests=("${explicit[@]}")
      step "tests (${#tests[@]} explicit files)" run_tests
    elif [[ "$affected_mode" == "skip_dart" ]]; then
      results+=("skip  tests ($affected_reason)")
    elif [[ "$affected_mode" == "whole_suite" ]]; then
      whole_suite_reason="$affected_reason"
      test_args=(-x matrix)
      step "tests (PR whole suite: $whole_suite_reason)" run_tests
    else
      # Exclude pure file-level @Tags(['matrix']) files when running -x matrix,
      # keeping architecture and PR-tier affected tests clean without triggering
      # "No tests ran." if only matrix files were touched.
      mapfile -t tests < <(
        python3 - "${selected_tests[@]}" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, str(Path("tool").resolve()))
import test_shards

for rel in sys.argv[1:]:
    if not rel:
        continue
    if "matrix" in test_shards.file_tags(rel):
        continue
    print(rel)
PY
      )
      if [[ ${#tests[@]} -eq 1 && -z "${tests[0]}" ]]; then
        tests=()
      fi
      test_args=(-x matrix)
      if [[ ${#tests[@]} -eq 0 ]]; then
        results+=("skip  tests (0 PR-tier affected files; use --matrix for matrix tests)")
      else
        step "tests (${#tests[@]} files)" run_tests
      fi
    fi
    ;;
esac

for file in "${changed[@]}"; do
  case "$file" in
    android/* | plugins/*)
      results+=("note  android/ or plugins/ changed: CI's android-unit and plugin jobs cover them")
      break
      ;;
  esac
done

echo
echo "== gate against $(git rev-parse --short "$base") ($base_ref)"
printf '%s\n' "${results[@]}"
exit "$failed"
