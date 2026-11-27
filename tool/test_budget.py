#!/usr/bin/env python3
"""Gates each change's test growth against its lib growth (spec TEST-05).

A code line is a line of a .dart file that is neither blank nor a `//`
comment. The count covers test/ except test/review/ (the screenshot
review, reported on its own line) and test/fixtures/ (recorded data), and
lib/ without the localizations `flutter gen-l10n` writes.

With --base, a change may add `ratio` (tool/test_budget.json) times its
gross added `lib/` code lines plus `change_tolerance` `test/` code lines;
more fails. Counting gross added `lib/` lines ensures refactoring/deleting
duplicate `lib/` code never strips test allowance from fixes in the same
change. The suite's test/lib ratio is reported on every run and warns
above `trend_warning`, the user's cue for a slimming round; it never
fails. Only the user changes the three numbers. Case counts (broken down
into unit `test(` vs `testWidgets(`), code lines per case, and unrecorded
`tool/test_durations.json` files are reported for the trend.

Usage:
  python3 tool/test_budget.py                 count the working tree
  python3 tool/test_budget.py --base REF      also gate the change from REF
  python3 tool/test_budget.py --summary FILE  append a Markdown report
      (CI passes $GITHUB_STEP_SUMMARY)

Exit status is 1 when the change from --base adds more than it may; the
suite's ratio only warns.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BUDGET = REPO / 'tool/test_budget.json'
DURATIONS = REPO / 'tool/test_durations.json'
REVIEW_DIR = 'test/review/'
UNCOUNTED = (REVIEW_DIR, 'test/fixtures/')
UNIT_CASE = re.compile(r'(?<![\w.])test\(')
WIDGET_CASE = re.compile(r'(?<![\w.])(?:testWidgets|testE2e)\(')
# `flutter gen-l10n` output: app_localizations.dart and one
# app_localizations_<language>.dart per language, generated from the ARB
# files. Hand-written files beside them (the delegates) still count.
GENERATED_LIB = re.compile(r'lib/l10n/app_localizations(?:_[a-z]{2,3})?\.dart')


@dataclass(frozen=True)
class Count:
    tests: int
    unit_cases: int
    widget_cases: int
    review: int
    lib: int

    @property
    def cases(self) -> int:
        return self.unit_cases + self.widget_cases

    @property
    def widget_share(self) -> float:
        return (self.widget_cases / self.cases * 100.0) if self.cases else 0.0

    @property
    def ratio(self) -> float:
        return self.tests / self.lib if self.lib else 0.0


def git(*args: str) -> str:
    return subprocess.run(['git', *args], cwd=REPO, check=True,
                          capture_output=True, text=True).stdout


def is_code_line(line: str) -> bool:
    return bool(line.strip()) and not line.lstrip().startswith('//')


def code_lines(text: str) -> int:
    return sum(1 for line in text.splitlines() if is_code_line(line))


def case_counts(text: str) -> tuple[int, int]:
    unit = 0
    widget = 0
    for line in text.splitlines():
        if line.lstrip().startswith('//'):
            continue
        unit += len(UNIT_CASE.findall(line))
        widget += len(WIDGET_CASE.findall(line))
    return unit, widget


def dart_sources(root: str, ref: str | None) -> dict[str, str]:
    """Repo-relative path to text, for the .dart files under [root]."""
    if ref is None:
        listed = git('ls-files', '--cached', '--others', '--exclude-standard',
                     '--', root).splitlines()
        return {path: (REPO / path).read_text(encoding='utf-8')
                for path in listed
                if path.endswith('.dart') and (REPO / path).exists()}
    paths = [path for path in
             git('ls-tree', '-r', '--name-only', ref, '--', root).splitlines()
             if path.endswith('.dart')]
    # One `git cat-file --batch` for every blob: "<oid> blob <size>\n<data>\n".
    out = subprocess.run(
        ['git', 'cat-file', '--batch'], cwd=REPO, check=True,
        input=''.join(f'{ref}:{path}\n' for path in paths).encode(),
        capture_output=True,
    ).stdout
    sources = {}
    position = 0
    for path in paths:
        header_end = out.index(b'\n', position)
        size = int(out[position:header_end].split()[2])
        start = header_end + 1
        sources[path] = out[start:start + size].decode('utf-8')
        position = start + size + 1
    return sources


def count(ref: str | None) -> Count:
    tests = dart_sources('test', ref)
    counted = [text for path, text in tests.items()
               if not path.startswith(UNCOUNTED)]
    unit = 0
    widget = 0
    for text in counted:
        u, w = case_counts(text)
        unit += u
        widget += w
    return Count(
        tests=sum(code_lines(text) for text in counted),
        unit_cases=unit,
        widget_cases=widget,
        review=sum(code_lines(text) for path, text in tests.items()
                   if path.startswith(REVIEW_DIR)),
        lib=sum(code_lines(text)
                for path, text in dart_sources('lib', ref).items()
                if not GENERATED_LIB.fullmatch(path)),
    )


def lib_added_code_lines(base_ref: str) -> int:
    """Gross added Dart code lines under lib/ (excluding generated l10n)
    between [base_ref] and the working tree, including untracked files."""
    diff = git('diff', '-U0', '--no-renames', base_ref, '--', 'lib/')
    added = 0
    active_counted = False
    in_hunk = False
    for line in diff.splitlines():
        if line.startswith('diff --git '):
            active_counted = False
            in_hunk = False
            continue
        if not in_hunk and line.startswith('+++ b/'):
            path = line[6:]
            active_counted = (
                path.endswith('.dart') and not GENERATED_LIB.fullmatch(path)
            )
            continue
        if not in_hunk and line.startswith('+++ '):
            active_counted = False
            continue
        if line.startswith('@@ '):
            in_hunk = True
            continue
        if in_hunk and active_counted and line.startswith('+'):
            if is_code_line(line[1:]):
                added += 1
    untracked = git('ls-files', '--others', '--exclude-standard', '--', 'lib/').splitlines()
    for path in untracked:
        if path.endswith('.dart') and not GENERATED_LIB.fullmatch(path):
            file_path = REPO / path
            if file_path.exists():
                added += code_lines(file_path.read_text(encoding='utf-8'))
    return added


def unrecorded_duration_files() -> int:
    """Number of runnable test/*_test.dart files absent from test_durations.json."""
    listed = git('ls-files', '--cached', '--others', '--exclude-standard',
                 '--', 'test/*_test.dart').splitlines()
    all_tests = [p for p in listed if (REPO / p).exists()]
    durations = json.loads(DURATIONS.read_text()) if DURATIONS.exists() else {}
    return sum(1 for p in all_tests if p not in durations)


def signed(delta: int) -> str:
    return f'{delta:+,}'


@dataclass(frozen=True)
class Growth:
    tests: int
    lib_net: int
    lib_added: int
    allowance: int

    @property
    def over(self) -> int:
        return self.tests - self.allowance


def growth(now: Count, base: Count, lib_added: int, ratio: float,
           tolerance: int) -> Growth:
    """test/ lines added against [base], and what the change may add:
    [ratio] times gross added lib/ code lines plus [tolerance]."""
    return Growth(
        tests=now.tests - base.tests,
        lib_net=now.lib - base.lib,
        lib_added=lib_added,
        allowance=int(max(lib_added, 0) * ratio) + tolerance,
    )


def report(now: Count, base: Count | None, base_name: str | None,
           budget: dict, grown: Growth | None,
           unrecorded: int) -> tuple[list[str], list[str]]:
    """Plain lines for the log and Markdown lines for the job summary."""
    ratio, tolerance = budget['ratio'], budget['change_tolerance']
    trend = budget['trend_warning']
    case_change = (f' ({signed(now.cases - base.cases)} against {base_name})'
                   if base else '')
    per_case = now.tests / now.cases if now.cases else 0
    log = [
        f'test/ code lines: {now.tests:,}; lib/ {now.lib:,}; '
        f'test/lib {now.ratio:.3f} (warns above {trend})',
        f'cases: {now.cases:,}{case_change} '
        f'(unit {now.unit_cases:,}, widget {now.widget_cases:,} '
        f'[{now.widget_share:.1f}%]); {per_case:.1f} code lines per case',
        f'test/review/ (not counted): {now.review:,}; '
        f'unrecorded duration files: {unrecorded}',
    ]
    summary = [
        '### Test budget (TEST-05)',
        '',
        '| | Value |',
        '|---|---:|',
    ]
    if grown is not None:
        log.append(
            f'change from {base_name}: test/ {signed(grown.tests)}, '
            f'lib/ net {signed(grown.lib_net)} (gross +{grown.lib_added:,}); '
            f'may add {grown.allowance:,} '
            f'({ratio} x lib/ added + {tolerance:,}); '
            f'{"over by " + format(grown.over, ",") if grown.over > 0 else "within"}')
        summary += [
            f'| test/ change | {signed(grown.tests)} |',
            f'| lib/ change (net / gross added) | {signed(grown.lib_net)} / +{grown.lib_added:,} |',
            f'| May add ({ratio} × lib/ added + {tolerance:,}) '
            f'| {grown.allowance:,} |',
        ]
    summary += [
        f'| test/ (counted) | {now.tests:,} |',
        f'| lib/ (without generated strings) | {now.lib:,} |',
        f'| test/lib (warns above {trend}) | {now.ratio:.3f} |',
        f'| Cases{case_change} | {now.cases:,} '
        f'(unit {now.unit_cases:,}, widget {now.widget_cases:,} '
        f'[{now.widget_share:.1f}%], {per_case:.1f} lines each) |',
        f'| Unrecorded duration files | {unrecorded} |',
        f'| test/review/ (not counted) | {now.review:,} |',
        '',
    ]
    return log, summary


def annotate(level: str, message: str) -> None:
    if os.environ.get('GITHUB_ACTIONS') == 'true':
        print(f'::{level}::{message}')
    else:
        print(f'{level}: {message}', file=sys.stderr)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--base', help='git ref to gate the change from')
    parser.add_argument('--summary', type=Path,
                        help='append a Markdown report to this file')
    args = parser.parse_args()

    budget = json.loads(BUDGET.read_text())
    now = count(None)
    base = count(args.base) if args.base else None
    lib_added = lib_added_code_lines(args.base) if args.base else 0
    grown = (growth(now, base, lib_added, budget['ratio'],
                    budget['change_tolerance'])
             if base else None)
    unrecorded = unrecorded_duration_files()
    log, summary = report(now, base, args.base, budget, grown, unrecorded)
    print('\n'.join(log))
    if args.summary:
        with args.summary.open('a', encoding='utf-8') as out:
            out.write('\n'.join(summary) + '\n')

    if now.ratio > budget['trend_warning']:
        annotate('warning',
                 f'TEST-05 test/lib is {now.ratio:.3f}, above '
                 f'{budget["trend_warning"]}: the suite is due a slimming '
                 'round, which the user schedules. This never fails the '
                 'build.')
    if grown is not None and grown.over > 0:
        annotate('error',
                 f'TEST-05 this change adds {grown.tests:,} test/ code lines, '
                 f'{grown.over:,} more than it may ({budget["ratio"]} x its '
                 f'gross lib/ added of {grown.lib_added:,} + '
                 f'{budget["change_tolerance"]:,}). Make room in the spec\'s '
                 'order: share duplicated doubles and table-drive '
                 'near-copies, then drop UI tests of colour, spacing, order '
                 'or copy, then tests of removed code, then a second layer '
                 'covering one behaviour, then prune passing tests whose '
                 'condition another case covers (TEST-13). Changing the '
                 'numbers needs the user\'s consent.')
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
