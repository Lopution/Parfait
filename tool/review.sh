#!/usr/bin/env bash
# UX review harness: renders the page-state shots and interaction films in
# test/review into $PARFAIT_REVIEW_OUT/runs/<stamp>/ and writes manifest.md
# there, the coverage table of what was rendered.
#
# Usage: tool/review.sh [flutter test arguments]
#   No arguments runs every shots_*.dart and films_*.dart file; arguments
#   replace that list, e.g. tool/review.sh test/review/films_expand.dart
#
# PARFAIT_REVIEW_OUT  output root (default ~/parfait-ux4-review)
# PARFAIT_REVIEW_RUN  run name (default: a timestamp)
# REVIEW_CONCURRENCY  test files rendered at once (default 4; each holds a
#                     whole app, mind the memory)
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PARFAIT_REVIEW_OUT="${PARFAIT_REVIEW_OUT:-$HOME/parfait-ux4-review}"
export PARFAIT_REVIEW_RUN="${PARFAIT_REVIEW_RUN:-$(date +%Y%m%d-%H%M%S)}"
run="$PARFAIT_REVIEW_OUT/runs/$PARFAIT_REVIEW_RUN"
if [[ -e "$run" ]]; then
  # The manifest is appended to; a second run would mix into the first.
  echo "$run exists; choose another PARFAIT_REVIEW_RUN" >&2
  exit 1
fi

python3 "$root/tool/fetch_review_fonts.py" "$PARFAIT_REVIEW_OUT/fonts"

cd "$root"
if (($# == 0)); then
  set -- test/review/shots_*.dart test/review/films_*.dart
fi
status=0
flutter test --no-pub --concurrency="${REVIEW_CONCURRENCY:-4}" \
  -r failures-only "$@" || status=$?

if [[ -f "$run/manifest.tsv" ]]; then
  python3 - "$run" <<'PY'
import sys
from collections import defaultdict
from pathlib import Path

run = Path(sys.argv[1])
shots, films = [], []
for line in (run / "manifest.tsv").read_text().splitlines():
    kind, name, location, detail, path = line.split("\t")
    (shots if kind == "shot" else films).append((name, location, detail, path))

by_route = defaultdict(list)
for name, location, detail, path in sorted(shots):
    by_route[location].append((name, detail, path))
unsettled = [name for name, _, detail, _ in shots if "UNSETTLED" in detail]

out = [f"# Review run {run.name}", ""]
out.append(f"{len(shots)} shots on {len(by_route)} routes, {len(films)} films.")
if unsettled:
    out.append("")
    out.append("Still animating after 10s (spinner that never stops?):")
    out += [f"- {name}" for name in sorted(unsettled)]
out += ["", "## Shots", "", "| route | shot | state, variant |", "| --- | --- | --- |"]
for location in sorted(by_route):
    for i, (name, detail, path) in enumerate(by_route[location]):
        route = f"`{location}`" if i == 0 else ""
        out.append(f"| {route} | [{name}]({path}) | {detail} |")
out += ["", "## Films", "", "| film | starts at | frames | notes |", "| --- | --- | --- | --- |"]
for name, location, detail, path in sorted(films):
    out.append(
        f"| [{name}]({path}/sheet-00.png) | `{location}` | {detail} "
        f"| [notes]({path}/notes.md) |"
    )
(run / "manifest.md").write_text("\n".join(out) + "\n")
PY
  echo "review run: $run/manifest.md"
else
  echo "review run: nothing rendered into $run" >&2
fi
exit "$status"
