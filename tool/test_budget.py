#!/usr/bin/env python3
"""Counts the test suite against its budget (spec TEST-05).

A code line is a line of a .dart file that is neither blank nor a `//`
comment. The budget counts test/ except test/review/ (the screenshot
review, reported on its own line) and test/fixtures/ (recorded data). The
cap is `ratio` (tool/test_budget.json) times lib/'s code lines, without
the localizations `flutter gen-l10n` writes, so tests may grow with the
code but not faster; changing the ratio needs the user's consent. The
case count (call sites of `test(` and `testWidgets(` on code lines; a
table-driven loop counts once) and the code lines per case are reported
for the trend, never enforced.

With --base, a change whose test/ growth exceeds `ratio` times its lib/
growth (none when lib/ shrinks: the cap already tightens) by more than
`growth_warning` code lines gets a warning, never a failure.

Usage:
  python3 tool/test_budget.py                 count the working tree
  python3 tool/test_budget.py --base REF      also report the change from REF
  python3 tool/test_budget.py --summary FILE  append a Markdown report
      (CI passes $GITHUB_STEP_SUMMARY)

Exit status is 1 when the counted lines exceed the cap; growth only warns.
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
REVIEW_DIR = 'test/review/'
UNCOUNTED = (REVIEW_DIR, 'test/fixtures/')
CASE = re.compile(r'(?<![\w.])(?:testWidgets|test)\(')
# `flutter gen-l10n` output: app_localizations.dart and one
# app_localizations_<language>.dart per language, generated from the ARB
# files. Hand-written files beside them (the delegates) still count.
GENERATED_LIB = re.compile(r'lib/l10n/app_localizations(?:_[a-z]{2,3})?\.dart')


@dataclass(frozen=True)
class Count:
    tests: int
    cases: int
    review: int
    lib: int

    def cap(self, ratio: float) -> int:
        return int(self.lib * ratio)


def git(*args: str) -> str:
    return subprocess.run(['git', *args], cwd=REPO, check=True,
                          capture_output=True, text=True).stdout


def code_lines(text: str) -> int:
    return sum(1 for line in text.splitlines()
               if line.strip() and not line.lstrip().startswith('//'))


def case_count(text: str) -> int:
    return sum(len(CASE.findall(line)) for line in text.splitlines()
               if not line.lstrip().startswith('//'))


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
    return Count(
        tests=sum(code_lines(text) for text in counted),
        cases=sum(case_count(text) for text in counted),
        review=sum(code_lines(text) for path, text in tests.items()
                   if path.startswith(REVIEW_DIR)),
        lib=sum(code_lines(text)
                for path, text in dart_sources('lib', ref).items()
                if not GENERATED_LIB.fullmatch(path)),
    )


def signed(delta: int) -> str:
    return f'{delta:+,}'


@dataclass(frozen=True)
class Growth:
    tests: int
    allowance: int

    @property
    def over(self) -> int:
        return self.tests - self.allowance


def growth(now: Count, base: Count, ratio: float) -> Growth:
    """test/ lines added against [base], and what [ratio] allows for the
    lib/ lines added; a change that removes lib/ code is allowed none."""
    return Growth(tests=now.tests - base.tests,
                  allowance=int(max(now.lib - base.lib, 0) * ratio))


def report(now: Count, base: Count | None, base_name: str | None,
           ratio: float, grown: Growth | None,
           warn: int) -> tuple[list[str], list[str]]:
    """Plain lines for the log and Markdown lines for the job summary."""
    cap = now.cap(ratio)
    change = (f' ({signed(now.tests - base.tests)} against {base_name}, '
              f'lib/ {signed(now.lib - base.lib)})' if base else '')
    case_change = (f' ({signed(now.cases - base.cases)} against {base_name})'
                   if base else '')
    per_case = now.tests / now.cases if now.cases else 0
    log = [
        f'test/ code lines: {now.tests:,}{change}',
        f'cap: {ratio} x lib/ {now.lib:,} = {cap:,}; '
        f'test/lib {now.tests / now.lib:.3f}',
        f'cases: {now.cases:,}{case_change}; '
        f'{per_case:.1f} code lines per case',
        f'test/review/ (not counted): {now.review:,}',
    ]
    if grown is not None:
        log.append(f'growth over {ratio} x lib/ growth: {grown.over:,} '
                   f'(warns above {warn:,})')
    summary = [
        '### Test budget (TEST-05)',
        '',
        '| | Code lines |',
        '|---|---:|',
        f'| test/ (counted) | {now.tests:,}{change} |',
        f'| Cap ({ratio} × lib/ {now.lib:,}) | {cap:,} |',
        f'| Cases{case_change} | {now.cases:,} '
        f'({per_case:.1f} lines each) |',
        f'| test/review/ (not counted) | {now.review:,} |',
    ]
    if grown is not None:
        summary.append(f'| Growth over {ratio} × lib/ growth '
                       f'(warns above {warn:,}) | {grown.over:,} |')
    summary.append('')
    return log, summary


def annotate(level: str, message: str) -> None:
    if os.environ.get('GITHUB_ACTIONS') == 'true':
        print(f'::{level}::{message}')
    else:
        print(f'{level}: {message}', file=sys.stderr)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--base', help='git ref to report the change from')
    parser.add_argument('--summary', type=Path,
                        help='append a Markdown report to this file')
    args = parser.parse_args()

    budget = json.loads(BUDGET.read_text())
    ratio, warn = budget['ratio'], budget['growth_warning']
    now = count(None)
    base = count(args.base) if args.base else None
    grown = growth(now, base, ratio) if base else None
    log, summary = report(now, base, args.base, ratio, grown, warn)
    print('\n'.join(log))
    if args.summary:
        with args.summary.open('a', encoding='utf-8') as out:
            out.write('\n'.join(summary) + '\n')

    if grown is not None and grown.over > warn:
        annotate('warning',
                 f'TEST-05 this change adds {grown.tests:,} test/ code lines, '
                 f'{grown.over:,} more than {ratio} x its lib/ growth allows '
                 f'({grown.allowance:,}); the warning starts above {warn:,}. '
                 'Before adding more, table-drive near-copies and drop cases '
                 'another case covers. This never fails the build.')
    cap = now.cap(ratio)
    if now.tests > cap:
        annotate('error',
                 f'TEST-05 test/ has {now.tests:,} code lines, over the '
                 f'{cap:,} cap ({ratio} x lib/). Make room in the spec\'s '
                 'order: share duplicated doubles and table-drive '
                 'near-copies, then drop UI tests of colour, spacing, order '
                 'or copy, then tests of removed code, then a second layer '
                 'covering one behaviour, then prune passing tests whose '
                 'condition another case covers (TEST-13). Changing the '
                 'ratio needs the user\'s consent.')
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
