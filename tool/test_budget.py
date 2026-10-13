#!/usr/bin/env python3
"""Counts the test suite against its budget (spec TEST-05).

A code line is a line of a .dart file that is neither blank nor a `//`
comment. The budget counts test/ except test/review/ (the screenshot
review, reported on its own line) and test/fixtures/ (recorded data). The
cap is in tool/test_budget.json; raising it needs the user's consent.

`lib_at_cap` is lib/'s code line count when the cap was set. Once lib/ has
grown 10% past it the report asks for the cap to be reviewed; it never
changes the cap itself.

Usage:
  python3 tool/test_budget.py                 count the working tree
  python3 tool/test_budget.py --base REF      also report the change from REF
  python3 tool/test_budget.py --summary FILE  append a Markdown report
      (CI passes $GITHUB_STEP_SUMMARY)

Exit status is 1 when the counted lines exceed the cap.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BUDGET = REPO / 'tool/test_budget.json'
REVIEW_DIR = 'test/review/'
UNCOUNTED = (REVIEW_DIR, 'test/fixtures/')
REVIEW_GROWTH = 0.10


@dataclass(frozen=True)
class Count:
    tests: int
    review: int
    lib: int


def git(*args: str) -> str:
    return subprocess.run(['git', *args], cwd=REPO, check=True,
                          capture_output=True, text=True).stdout


def code_lines(text: str) -> int:
    return sum(1 for line in text.splitlines()
               if line.strip() and not line.lstrip().startswith('//'))


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
    return Count(
        tests=sum(code_lines(text) for path, text in tests.items()
                  if not path.startswith(UNCOUNTED)),
        review=sum(code_lines(text) for path, text in tests.items()
                   if path.startswith(REVIEW_DIR)),
        lib=sum(code_lines(text) for text in dart_sources('lib', ref).values()),
    )


def signed(delta: int) -> str:
    return f'{delta:+,}'


def report(now: Count, base: Count | None, base_name: str | None,
           cap: int, lib_at_cap: int) -> tuple[list[str], list[str]]:
    """Plain lines for the log and Markdown lines for the job summary."""
    change = (f' ({signed(now.tests - base.tests)} against {base_name})'
              if base else '')
    growth = now.lib / lib_at_cap - 1
    ratio = now.tests / now.lib
    log = [
        f'test/ code lines: {now.tests:,}{change}, cap {cap:,}',
        f'test/review/ (not counted): {now.review:,}',
        f'lib/ code lines: {now.lib:,}, {growth:+.1%} since the cap was set; '
        f'test/lib {ratio:.2f}',
    ]
    summary = [
        '### Test budget (TEST-05)',
        '',
        '| | Code lines |',
        '|---|---:|',
        f'| test/ (counted) | {now.tests:,}{change} |',
        f'| Cap | {cap:,} |',
        f'| test/review/ (not counted) | {now.review:,} |',
        f'| lib/ | {now.lib:,} ({growth:+.1%} since the cap was set) |',
        f'| test/ ÷ lib/ | {ratio:.2f} |',
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
    parser.add_argument('--base', help='git ref to report the change from')
    parser.add_argument('--summary', type=Path,
                        help='append a Markdown report to this file')
    args = parser.parse_args()

    budget = json.loads(BUDGET.read_text())
    cap, lib_at_cap = budget['cap'], budget['lib_at_cap']
    now = count(None)
    base = count(args.base) if args.base else None
    log, summary = report(now, base, args.base, cap, lib_at_cap)
    print('\n'.join(log))
    if args.summary:
        with args.summary.open('a', encoding='utf-8') as out:
            out.write('\n'.join(summary) + '\n')

    if now.lib >= lib_at_cap * (1 + REVIEW_GROWTH):
        annotate('notice',
                 f'lib/ has grown {REVIEW_GROWTH:.0%} since the test cap was '
                 f'set ({lib_at_cap:,} to {now.lib:,} code lines): ask the '
                 f'user whether the {cap:,} cap still fits. Only they change '
                 'it.')
    if now.tests > cap:
        annotate('error',
                 f'TEST-05 test/ has {now.tests:,} code lines, over the '
                 f'{cap:,} cap. Make room in the spec\'s order: share '
                 'duplicated doubles and table-drive near-copies, then drop '
                 'UI tests of colour, spacing, order or copy, then tests of '
                 'removed code, then a second layer covering one behaviour. '
                 'Raising the cap needs the user\'s consent.')
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
