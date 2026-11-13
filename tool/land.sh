#!/usr/bin/env bash
# Land a pull request using the repository's required noreply author identity,
# verify the merge commit author, and fast-forward local main.
#
# Usage: tool/land.sh [<pr-number>] [--wait [--all-checks] | --auto]
#   <pr-number>   Pull request number (defaults to the current branch's PR).
#   --wait        Wait for required CI checks, merge, verify author, sync main (default).
#   --all-checks  With --wait, also wait for every pull_request workflow run on the head commit.
#   --auto        Enable GitHub auto-merge with the noreply author email and exit.
set -euo pipefail

NOREPLY_EMAIL="70460628+Lopution@users.noreply.github.com"

usage() {
  sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'
}

pr=""
mode="wait"
all_checks=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --wait) mode="wait" ;;
    --all-checks) all_checks=1 ;;
    --auto) mode="auto" ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      echo "land: unknown option $1" >&2
      exit 2
      ;;
    *)
      if [[ -n "$pr" ]]; then
        echo "land: unexpected argument $1" >&2
        exit 2
      fi
      pr="$1"
      ;;
  esac
  shift
done

if [[ "$mode" == "auto" && "$all_checks" -eq 1 ]]; then
  echo "land: --all-checks cannot be combined with --auto" >&2
  exit 2
fi

for tool in git gh; do
  command -v "$tool" >/dev/null || { echo "land: $tool is not on PATH" >&2; exit 2; }
done

if [[ -z "$pr" ]]; then
  pr="$(gh pr view --json number -q .number)" || {
    echo "land: could not determine PR for current branch (pass <pr-number>)" >&2
    exit 2
  }
fi

if ! [[ "$pr" =~ ^[0-9]+$ ]]; then
  echo "land: invalid PR number '$pr'" >&2
  exit 2
fi

read_pr_state() {
  gh pr view "$pr" --json state,mergeStateStatus,headRefName,headRefOid \
    --jq '[.state, (.mergeStateStatus // "UNKNOWN"), .headRefName, .headRefOid] | @tsv'
}

pr_tsv="$(read_pr_state)"
IFS=$'\t' read -r state merge_state head_ref head_oid <<<"$pr_tsv"

if [[ "$state" == "MERGED" ]]; then
  echo "land: PR #$pr ($head_ref) is already merged; verifying merge commit and syncing main"
elif [[ "$state" != "OPEN" ]]; then
  echo "land: PR #$pr is in state '$state' (expected OPEN)" >&2
  exit 1
else
  expected_oid="$(git rev-parse --verify --quiet "refs/remotes/origin/$head_ref" || true)"
  if [[ -n "$expected_oid" && "$head_oid" != "$expected_oid" ]] &&
    git merge-base --is-ancestor "$head_oid" "$expected_oid" 2>/dev/null; then
    for _ in 1 2 3 4 5; do
      sleep 2
      pr_tsv="$(read_pr_state)"
      IFS=$'\t' read -r state merge_state head_ref head_oid <<<"$pr_tsv"
      if [[ "$head_oid" == "$expected_oid" ]]; then
        break
      fi
    done
  fi

  case "$merge_state" in
    BEHIND | DIRTY)
      echo "land: PR #$pr ($head_ref) is $merge_state relative to main; run 'git fetch origin main && git merge origin/main && git push' first (never gh pr update-branch)" >&2
      exit 1
      ;;
  esac

  if [[ "$mode" == "auto" ]]; then
    if ! gh pr merge "$pr" --auto --merge --author-email "$NOREPLY_EMAIL"; then
      echo "land: failed to enable auto-merge (check repo allow_auto_merge or PR state)" >&2
      exit 1
    fi
    echo "land: auto-merge enabled for PR #$pr ($head_ref) with author $NOREPLY_EMAIL"
    exit 0
  fi

  echo "land: locating CI workflow run for PR #$pr ($head_ref @ ${head_oid:0:8})..."
  ci_run_id=""
  for _ in $(seq 1 12); do
    ci_run_id="$(
      gh run list -c "$head_oid" -w ci.yml -e pull_request -L 1 \
        --json databaseId -q '.[0].databaseId // empty'
    )"
    if [[ -n "$ci_run_id" ]]; then
      break
    fi
    sleep 3
  done

  if [[ -z "$ci_run_id" ]]; then
    echo "land: no CI workflow run registered for commit $head_oid on PR #$pr" >&2
    exit 1
  fi

  echo "land: watching CI workflow run $ci_run_id..."
  gh run watch "$ci_run_id" --interval 15 --exit-status

  if [[ "$all_checks" -eq 1 ]]; then
    other_runs_raw="$(
      gh run list -c "$head_oid" -e pull_request \
        --json databaseId -q '.[].databaseId'
    )"
    if [[ -n "$other_runs_raw" ]]; then
      mapfile -t other_runs <<<"$other_runs_raw"
      for run_id in "${other_runs[@]}"; do
        if [[ -n "$run_id" && "$run_id" != "$ci_run_id" ]]; then
          echo "land: watching workflow run $run_id..."
          gh run watch "$run_id" --interval 15 --exit-status
        fi
      done
    fi
  fi

  gh pr checks "$pr" --required

  echo "land: merging PR #$pr ($head_ref)..."
  gh pr merge "$pr" --merge --author-email "$NOREPLY_EMAIL"
fi

merge_sha="$(gh pr view "$pr" --json mergeCommit -q '.mergeCommit.oid // empty')"
if [[ -z "$merge_sha" ]]; then
  echo "land: mergeCommit.oid unavailable for PR #$pr" >&2
  exit 1
fi

git fetch origin main
if ! git cat-file -e "${merge_sha}^{commit}" 2>/dev/null; then
  echo "land: merge commit $merge_sha not found on origin/main after fetch" >&2
  exit 1
fi

IFS=$'\t' read -r author_email committer_email < <(
  git log -1 --format=$'%ae\t%ce' "$merge_sha"
)
if [[ "$author_email" != "$NOREPLY_EMAIL" ]] ||
  [[ "$committer_email" != "noreply@github.com" && "$committer_email" != "$NOREPLY_EMAIL" ]]; then
  echo "land: unexpected commit identity on $merge_sha: author='$author_email' committer='$committer_email'" >&2
  exit 1
fi

main_wt=""
current_wt=""
while IFS= read -r line; do
  case "$line" in
    "worktree "*) current_wt="${line#worktree }" ;;
    "branch refs/heads/main") main_wt="$current_wt" ;;
  esac
done < <(git worktree list --porcelain)

if [[ -n "$main_wt" ]]; then
  if [[ -z "$(git -C "$main_wt" status --porcelain)" ]]; then
    git -C "$main_wt" merge --ff-only origin/main
  else
    echo "land: warning: main worktree at $main_wt is dirty; skipped ff-only update" >&2
  fi
else
  git fetch origin main:main
fi

short_merge="$(git rev-parse --short "$merge_sha")"
parent_list="$(git rev-list --no-merges --abbrev-commit "${merge_sha}^1..${merge_sha}^2" | paste -sd, - || true)"
echo "land: PR #$pr verified on origin/main"
echo "merge_commit: $short_merge"
if [[ -n "$parent_list" ]]; then
  echo "pr_commits: $parent_list"
fi
