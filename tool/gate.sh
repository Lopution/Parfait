#!/usr/bin/env bash
# Local gate before a pull request: the checks CI's analyze job runs, then
# the tests of what changed. CI still runs the whole suite (spec TEST-06)
# and the Android and Rust jobs.
#
# Usage: tool/gate.sh [--full | --fast | --no-tests] [--base REF] [test files...]
#   (default)   the test files that changed or import a changed file, plus
#               the architecture scans in test/architecture/ (they read
#               the whole tree, so any change can break them); a change to
#               dependencies or to shared test configuration runs the
#               whole suite
#   --full      the whole suite
#   --fast      checks, architecture scans, and any explicit test files only
#   --no-tests  checks only
#   --base REF  what the change is measured from: the merge base of HEAD
#               and REF (default origin/main)
#   files       run these test files instead of the selection
#
# Every step runs even after one fails; the exit status is 1 when any
# failed, 2 on a usage error. Flutter and Dart must be on PATH.
#
# Where systemd-run is available the tests run under a memory cap
# (GATE_TEST_MEMORY; default 4G, 8G above 10 files besides the
# architecture scans or for the whole suite). A killed child (frontend_server, flutter_tester) still leaves
# `flutter test` exiting 0, so the log is read for "did not complete" and
# "No tests ran." and the kernel log for an out-of-memory kill.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root" || exit 2

mode=changed
base_ref=origin/main
explicit=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --full) mode=full ;;
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
base="$(git merge-base HEAD "$base_ref")" ||
  { echo "gate: no merge base with $base_ref" >&2; exit 2; }
# The package name turns a changed lib/ file into the import tests use.
pkg="$(sed -n 's/^name: *//p' pubspec.yaml | head -n 1)"
[[ -n "$pkg" ]] || { echo "gate: no package name in pubspec.yaml" >&2; exit 2; }

# Committed since the base, uncommitted, and untracked; deleted paths stay
# in the list (a deleted lib file still selects the tests that import it).
changed_list="$(mktemp -t gate-changed.XXXXXX)"
{
  git diff --name-only "$base"...HEAD &&
    git diff --name-only HEAD &&
    git ls-files --others --exclude-standard
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

# A change every test file depends on runs the whole suite.
whole_suite_trigger() {
  local file
  for file in "${changed[@]}"; do
    case "$file" in
      pubspec.yaml | pubspec.lock | analysis_options.yaml | \
        test/flutter_test_config.dart)
        whole_suite_reason="$file changed"
        return
        ;;
    esac
  done
}

# The test files that changed or import a changed file directly; fails
# when grep cannot read test/ (exit 1 only means no file imports it).
select_tests() {
  local file needle status=0
  for file in "${changed[@]}"; do
    case "$file" in
      test/*_test.dart) [[ -f "$file" ]] && echo "$file" ;;
      lib/*.dart)
        needle="package:$pkg/${file#lib/}"
        grep -rlF --include='*_test.dart' "$needle" test || [[ $? -eq 1 ]] || status=1
        ;;
      test/*.dart)
        needle="${file#test/}"
        grep -rlF --include='*_test.dart' "$needle" test || [[ $? -eq 1 ]] || status=1
        ;;
    esac
  done
  return "$status"
}

run_tests() {
  local memory="${GATE_TEST_MEMORY:-}" log since status=0 file heavy=0
  if [[ -z "$memory" ]]; then
    for file in "${tests[@]}"; do
      [[ "$file" == test/architecture/* ]] || heavy=$((heavy + 1))
    done
    if [[ ${#tests[@]} -eq 0 || $heavy -gt 10 ]]; then memory=8G; else memory=4G; fi
  fi
  log="$(mktemp -t gate-test.XXXXXX.log)"
  since="$(date +%s)"
  local command=(flutter test "${tests[@]}")
  # A systemd-run whose system manager is unreachable (a container) fails
  # before running anything: probe it, and say when there is no cap.
  if command -v systemd-run >/dev/null &&
    systemd-run --scope --quiet -p "MemoryMax=$memory" true 2>/dev/null; then
    echo "memory cap $memory; log $log"
    systemd-run --scope --quiet -p "MemoryMax=$memory" -p MemorySwapMax=0 \
      "${command[@]}" 2>&1 | tee "$log"
    status=${PIPESTATUS[0]}
  else
    echo "systemd-run cannot create a scope here: running without a memory cap; log $log"
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
    journalctl -k --since "@$since" 2>/dev/null | grep -qi 'out of memory'; then
    echo "gate: the kernel killed a process for memory during the run" \
      "(raise GATE_TEST_MEMORY or run fewer files)" >&2
    status=1
  fi
  return "$status"
}

step "git diff --check" diff_check
step "check_spec" python3 tool/check_spec.py
step "test budget" python3 tool/test_budget.py --base "$base"
step "dart format" dart format --output=none --set-exit-if-changed lib test
step "flutter analyze" flutter analyze

tests=()
whole_suite_reason=""
case "$mode" in
  none) results+=("skip  tests (--no-tests)") ;;
  full)
    whole_suite_reason="--full"
    step "tests (whole suite)" run_tests
    ;;
  fast)
    selection="$(mktemp -t gate-selection.XXXXXX)"
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
    else
      whole_suite_trigger
      if [[ -z "$whole_suite_reason" ]]; then
        selection="$(mktemp -t gate-selection.XXXXXX)"
        if ! select_tests > "$selection" ||
          ! printf '%s\n' test/architecture/*_test.dart >> "$selection" ||
          ! sort -u -o "$selection" "$selection"; then
          results+=("FAIL  test selection (could not read test/)")
          failed=1
        fi
        mapfile -t tests < "$selection"
      fi
    fi
    if [[ -n "$whole_suite_reason" ]]; then
      step "tests (whole suite: $whole_suite_reason)" run_tests
    else
      step "tests (${#tests[@]} files)" run_tests
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
