#!/usr/bin/env python3
"""Checks .trellis/spec against the format rules in .trellis/spec/index.md.

Usage:
  python3 tool/check_spec.py               check every spec file (CI)
  python3 tool/check_spec.py --for PATH..  list the spec files covering PATHs
  python3 tool/check_spec.py --diff [BASE] spec files for this branch's changes
  python3 tool/check_spec.py --tasks       task context files name real paths
  python3 tool/check_spec.py --self-test   run the checker's own tests

Exit status is 1 when an error is reported; warnings never fail.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SPEC_DIR = Path('.trellis/spec')

SOFT_LINE_LIMIT = 300
HARD_LINE_LIMIT = 500
CONTENTS_THRESHOLD = 100
MAX_EXAMPLE_LINES = 10
REVIEW_MAX_AGE_DAYS = 90

RULE_FIELDS = ('Rule', 'Why', 'Check', 'Code')
RULE_FILE_KEYS = {'prefix', 'applies_to', 'reviewed'}
INDEX_KEYS = {'reviewed'}

PREFIX_RE = re.compile(r'^[A-Z]{2,6}$')
RULE_HEADING_RE = re.compile(r'^### ([A-Z]{2,6})-(\d{2}) \S')
FIELD_RE = re.compile(r'^- \*\*(\w+):\*\*')
BACKTICK_RE = re.compile(r'`([^`\n]+)`')
CHECK_ITEM_RE = re.compile(r'`([^`\n]+)`((?:\s*"[^"\n]+")*)')
QUOTED_RE = re.compile(r'"([^"\n]+)"')
LINK_RE = re.compile(r'\[[^\]]*\]\(([^)\s]+)\)')
INDEX_ENTRY_RE = re.compile(r'\[[^\]]+\]\(\./([^)#\s]+\.md)\)(.*)')

# Backticked tokens starting with one of these are repository paths.
PATH_ROOTS = (
    'lib/', 'test/', 'android/', 'plugins/', 'tool/', '.github/', 'assets/',
    'windows/', 'linux/', 'ios/', 'macos/', '.trellis/spec/',
)
ROOT_FILES = {
    'pubspec.yaml', 'pubspec.lock', 'analysis_options.yaml', 'l10n.yaml',
    'rust-toolchain.toml', 'AGENTS.md', 'CONTRIBUTING.md', 'NOTICE',
}

# Process records that do not belong in a public spec.
FORBIDDEN = (
    (re.compile(r'\b20\d\d-\d\d(-\d\d)?\b'), 'a date'),
    (re.compile(r'\b\d\d-\d\d-[a-z][a-z0-9]*(-[a-z0-9]+)+'), 'a task name'),
    (re.compile(r'\.trellis/(tasks|workspace)|/root/|journal-\d'),
     'a private path'),
    (re.compile(r'(?<![\w/&])#\d+\b'), 'an issue or PR number'),
    (re.compile(r'\b(?=[0-9a-f]*\d)(?=[0-9a-f]*[a-f])[0-9a-f]{7,40}\b'),
     'a commit hash'),
)


@dataclass
class Report:
    errors: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    def error(self, where: str, message: str) -> None:
        self.errors.append(f'error: {where}: {message}')

    def warn(self, where: str, message: str) -> None:
        self.warnings.append(f'warning: {where}: {message}')


@dataclass
class SpecFile:
    path: Path  # repo-relative
    lines: list[str]
    meta: dict[str, object]
    body_start: int  # index of the first line after the frontmatter

    @property
    def is_index(self) -> bool:
        return self.path.name == 'index.md'

    @property
    def layer(self) -> str:
        rel = self.path.relative_to(SPEC_DIR)
        return rel.parts[0] if len(rel.parts) > 1 else ''


class Repo:
    """The checked tree: a root directory and its file list."""

    def __init__(self, root: Path, files: set[str]):
        self.root = root
        self.files = files
        self.dirs = {str(p) for f in files for p in Path(f).parents} - {'.'}

    def exists(self, path: str) -> bool:
        path = path.rstrip('/')
        return path in self.files or path in self.dirs

    def matches(self, glob: str) -> list[str]:
        pattern = glob_regex(glob)
        return [f for f in self.files if pattern.fullmatch(f)]

    def read(self, path: str) -> str:
        return (self.root / path).read_text(encoding='utf-8')


def glob_regex(glob: str) -> re.Pattern[str]:
    out = ''
    i = 0
    while i < len(glob):
        if glob.startswith('**/', i):
            out += '(?:.*/)?'
            i += 3
        elif glob.startswith('**', i):
            out += '.*'
            i += 2
        elif glob[i] == '*':
            out += '[^/]*'
            i += 1
        elif glob[i] == '?':
            out += '[^/]'
            i += 1
        else:
            out += re.escape(glob[i])
            i += 1
    return re.compile(out)


def git_files(root: Path) -> set[str]:
    out = subprocess.run(
        ['git', 'ls-files', '--cached', '--others', '--exclude-standard'],
        cwd=root, check=True, capture_output=True, text=True,
    ).stdout
    return {line for line in out.splitlines() if (root / line).exists()}


def parse_frontmatter(lines: list[str]) -> tuple[dict[str, object], int]:
    if not lines or lines[0] != '---':
        raise ValueError('missing frontmatter')
    meta: dict[str, object] = {}
    key = None
    for i, line in enumerate(lines[1:], start=1):
        if line == '---':
            return meta, i + 1
        if line.startswith('  - ') and key is not None:
            value = meta.setdefault(key, [])
            if not isinstance(value, list):
                raise ValueError(f'line {i + 1}: "{key}" mixes scalar and list')
            value.append(line[4:].strip())
        elif ':' in line and not line.startswith(' '):
            key, _, value = line.partition(':')
            key = key.strip()
            meta[key] = value.strip() if value.strip() else []
        else:
            raise ValueError(f'line {i + 1}: unreadable frontmatter line')
    raise ValueError('frontmatter is not closed')


def load_spec(repo: Repo, report: Report) -> list[SpecFile]:
    specs = []
    for path in sorted(p for p in repo.files
                       if p.startswith(f'{SPEC_DIR}/') and p.endswith('.md')):
        lines = repo.read(path).splitlines()
        try:
            meta, start = parse_frontmatter(lines)
        except ValueError as e:
            report.error(path, str(e))
            continue
        specs.append(SpecFile(Path(path), lines, meta, start))
    return specs


def body_lines(spec: SpecFile):
    """Yields (line number, text, inside a fenced block) after frontmatter."""
    fenced = False
    for i in range(spec.body_start, len(spec.lines)):
        line = spec.lines[i]
        if line.lstrip().startswith('```'):
            yield i + 1, line, True
            fenced = not fenced
            continue
        yield i + 1, line, fenced


def slug(heading: str) -> str:
    text = re.sub(r'[^\w\- ]', '', heading.strip().lower())
    return text.replace(' ', '-')


def is_repo_path(token: str) -> bool:
    if any(c in token for c in ' <>{}$'):
        return False
    return token.startswith(PATH_ROOTS) or token in ROOT_FILES


def path_exists(repo: Repo, token: str) -> bool:
    if '*' in token or '?' in token:
        return bool(repo.matches(token))
    return repo.exists(token)


def check_meta(spec: SpecFile, repo: Repo, report: Report,
               today: dt.date) -> None:
    where = str(spec.path)
    allowed = INDEX_KEYS if spec.is_index else RULE_FILE_KEYS
    for key in spec.meta.keys() - allowed:
        report.error(where, f'unknown frontmatter key "{key}"')
    for key in allowed - spec.meta.keys():
        report.error(where, f'missing frontmatter key "{key}"')
    reviewed = spec.meta.get('reviewed')
    if isinstance(reviewed, str):
        try:
            age = (today - dt.date.fromisoformat(reviewed)).days
        except ValueError:
            report.error(where, f'"reviewed" is not a date: {reviewed}')
        else:
            if age > REVIEW_MAX_AGE_DAYS:
                report.warn(where, f'not reviewed for {age} days')
    if spec.is_index:
        return
    prefix = spec.meta.get('prefix')
    if not isinstance(prefix, str) or not PREFIX_RE.match(prefix):
        report.error(where, f'"prefix" must be 2-6 capitals: {prefix}')
    globs = spec.meta.get('applies_to')
    if not isinstance(globs, list) or not globs:
        report.error(where, '"applies_to" must be a non-empty list')
        return
    for glob in globs:
        if not repo.matches(glob):
            report.error(where, f'applies_to "{glob}" matches no file')


def check_text(spec: SpecFile, repo: Repo, report: Report) -> None:
    where = str(spec.path)
    fence_start = None
    for number, line, fenced in body_lines(spec):
        at = f'{where}:{number}'
        if line.lstrip().startswith('```'):
            if fence_start is None:
                fence_start = number
            else:
                length = number - fence_start - 1
                if length > MAX_EXAMPLE_LINES:
                    report.error(f'{where}:{fence_start}',
                                 f'code block of {length} lines '
                                 f'(limit {MAX_EXAMPLE_LINES})')
                fence_start = None
            continue
        if fenced:
            continue
        for pattern, what in FORBIDDEN:
            hit = pattern.search(line)
            if hit:
                report.error(at, f'contains {what}: "{hit.group(0)}"')
        for token in BACKTICK_RE.findall(line):
            if is_repo_path(token) and not path_exists(repo, token):
                report.error(at, f'path does not exist: {token}')
        for target in LINK_RE.findall(line):
            if target.startswith(('http://', 'https://', '#')):
                continue
            resolved = (spec.path.parent / target.split('#')[0])
            normal = Path(*[p for p in resolved.parts if p != '.'])
            parts: list[str] = []
            for part in normal.parts:
                if part == '..':
                    parts.pop()
                else:
                    parts.append(part)
            if not repo.exists('/'.join(parts)):
                report.error(at, f'link target does not exist: {target}')
    if fence_start is not None:
        report.error(f'{where}:{fence_start}', 'unclosed code block')


def check_size_and_contents(spec: SpecFile, report: Report) -> None:
    where = str(spec.path)
    count = len(spec.lines)
    if count > HARD_LINE_LIMIT:
        report.error(where, f'{count} lines (hard limit {HARD_LINE_LIMIT})')
    elif count > SOFT_LINE_LIMIT:
        report.warn(where, f'{count} lines (aim for {SOFT_LINE_LIMIT})')
    if count <= CONTENTS_THRESHOLD:
        return
    sections = [(n, line[3:]) for n, line, fenced in body_lines(spec)
                if not fenced and line.startswith('## ')]
    names = [name for _, name in sections]
    if 'Contents' not in names:
        report.error(where, f'over {CONTENTS_THRESHOLD} lines without a '
                     '"## Contents" section')
        return
    start = names.index('Contents')
    contents_end = (sections[start + 1][0] if start + 1 < len(sections)
                    else len(spec.lines))
    contents = '\n'.join(spec.lines[sections[start][0]:contents_end - 1])
    anchors = set(re.findall(r'\]\(#([^)]+)\)', contents))
    for number, name in sections:
        if name != 'Contents' and slug(name) not in anchors:
            report.error(f'{where}:{number}',
                         f'section "{name}" is missing from Contents')


def check_rules(spec: SpecFile, repo: Repo, report: Report,
                seen_ids: dict[str, str]) -> int:
    where = str(spec.path)
    prefix = spec.meta.get('prefix')
    rules: list[tuple[int, str, list[tuple[int, str]]]] = []
    for number, line, fenced in body_lines(spec):
        if fenced:
            continue
        if line.startswith('### '):
            match = RULE_HEADING_RE.match(line)
            if not match:
                report.error(f'{where}:{number}',
                             'a ### heading must be "### <PREFIX>-<NN> Title"')
                continue
            rule_id = f'{match.group(1)}-{match.group(2)}'
            if match.group(1) != prefix:
                report.error(f'{where}:{number}',
                             f'{rule_id} does not use the file prefix {prefix}')
            if rule_id in seen_ids:
                report.error(f'{where}:{number}', f'{rule_id} is already '
                             f'used in {seen_ids[rule_id]}')
            seen_ids[rule_id] = f'{where}:{number}'
            rules.append((number, rule_id, []))
        elif line.startswith('## '):
            rules.append((number, '', []))
        elif rules and rules[-1][1]:
            rules[-1][2].append((number, line))
    count = 0
    for number, rule_id, body in rules:
        if not rule_id:
            continue
        count += 1
        check_rule_fields(f'{where}:{number}', rule_id, body, repo, report)
    return count


def check_rule_fields(at: str, rule_id: str, body: list[tuple[int, str]],
                      repo: Repo, report: Report) -> None:
    fields: dict[str, str] = {}
    order: list[str] = []
    current = None
    for _, line in body:
        match = FIELD_RE.match(line)
        if match and match.group(1) in RULE_FIELDS:
            current = match.group(1)
            order.append(current)
            fields[current] = line[match.end():]
        elif current and line.startswith('  '):
            fields[current] += ' ' + line.strip()
        else:
            current = None
    if tuple(order[:4]) != RULE_FIELDS:
        report.error(at, f'{rule_id} needs the fields '
                     f'{", ".join(RULE_FIELDS)} in that order')
        return
    for name in RULE_FIELDS:
        if not fields[name].strip():
            report.error(at, f'{rule_id} has an empty {name}')
    check_field = fields['Check'].strip()
    items = CHECK_ITEM_RE.findall(check_field)
    if not items and not check_field.startswith('manual'):
        report.error(at, f'{rule_id} Check must name a test file or "manual"')
    for path, names in items:
        if not repo.exists(path):
            report.error(at, f'{rule_id} Check names a missing file: {path}')
            continue
        # Dart sources escape apostrophes inside single-quoted test names.
        text = repo.read(path).replace("\\'", "'") if path in repo.files else ''
        for name in QUOTED_RE.findall(names):
            if name not in text:
                report.error(at, f'{rule_id} Check names a test that is not '
                             f'in {path}: "{name}"')
    code = BACKTICK_RE.findall(fields['Code'])
    if not code:
        report.error(at, f'{rule_id} Code must name at least one path')
    for path in code:
        if not path_exists(repo, path):
            report.error(at, f'{rule_id} Code names a missing path: {path}')


def check_indexes(specs: list[SpecFile], report: Report) -> None:
    by_layer: dict[str, list[SpecFile]] = {}
    for spec in specs:
        by_layer.setdefault(spec.layer, []).append(spec)
    for layer, files in sorted(by_layer.items()):
        index = next((f for f in files if f.is_index), None)
        if layer == '':
            for f in files:
                if not f.is_index:
                    report.error(str(f.path), 'only index.md may sit at the '
                                 'spec root; move it into a layer')
            if index is None:
                report.error(str(SPEC_DIR), 'missing index.md')
                continue
            text = '\n'.join(index.lines)
            for other in sorted(by_layer):
                if other and f'./{other}/index.md' not in text:
                    report.error(str(index.path),
                                 f'does not link {other}/index.md')
            continue
        if index is None:
            report.error(f'{SPEC_DIR}/{layer}', 'missing index.md')
            continue
        entries = {}
        for line in index.lines:
            for match in INDEX_ENTRY_RE.finditer(line):
                entries[match.group(1)] = match.group(2)
        for f in files:
            if f.is_index:
                continue
            summary = entries.get(f.path.name)
            if summary is None:
                report.error(str(index.path), f'does not list {f.path.name}')
            elif not re.sub(r'[|\s—–-]', '', summary):
                report.error(str(index.path),
                             f'lists {f.path.name} without a summary')


def check_all(repo: Repo, today: dt.date) -> tuple[Report, dict[str, int]]:
    report = Report()
    specs = load_spec(repo, report)
    seen_ids: dict[str, str] = {}
    prefixes: dict[str, str] = {}
    stats = {'files': len(specs), 'lines': 0, 'rules': 0, 'tested': 0}
    for spec in specs:
        stats['lines'] += len(spec.lines)
        check_meta(spec, repo, report, today)
        check_text(spec, repo, report)
        check_size_and_contents(spec, report)
        if spec.is_index:
            continue
        prefix = spec.meta.get('prefix')
        if isinstance(prefix, str):
            if prefix in prefixes:
                report.error(str(spec.path), f'prefix {prefix} is already '
                             f'used by {prefixes[prefix]}')
            prefixes[prefix] = str(spec.path)
        stats['rules'] += check_rules(spec, repo, report, seen_ids)
        stats['tested'] += sum(
            1 for line in spec.lines
            if line.startswith('- **Check:**') and '`test/' in line)
    check_indexes(specs, report)
    return report, stats


def specs_for(repo: Repo, paths: list[str]) -> list[tuple[str, str]]:
    """Rule files whose applies_to covers one of [paths], with summaries."""
    report = Report()
    specs = load_spec(repo, report)
    summaries = {}
    for spec in specs:
        if spec.is_index:
            for line in spec.lines:
                for match in INDEX_ENTRY_RE.finditer(line):
                    name = str(spec.path.parent / match.group(1))
                    summaries[name] = match.group(2).strip(' |—-')
    hits = []
    for spec in specs:
        globs = spec.meta.get('applies_to')
        if spec.is_index or not isinstance(globs, list):
            continue
        patterns = [glob_regex(g) for g in globs]
        if any(p.fullmatch(path) for p in patterns for path in paths):
            hits.append((str(spec.path), summaries.get(str(spec.path), '')))
    return hits


def run_git(*args: str) -> str:
    return subprocess.run(['git', *args], cwd=REPO, check=True,
                          capture_output=True, text=True).stdout


def changed_paths(base: str) -> list[str]:
    merge_base = run_git('merge-base', base, 'HEAD').strip()
    changed = set(run_git('diff', '--name-only', merge_base).splitlines())
    changed |= set(run_git('ls-files', '--others',
                           '--exclude-standard').splitlines())
    return sorted(changed)


def current_task() -> Path | None:
    result = subprocess.run(
        [sys.executable, '.trellis/scripts/task.py', 'current'], cwd=REPO,
        capture_output=True, text=True)
    name = result.stdout.strip()
    if result.returncode != 0 or not name:
        return None
    return REPO / name


def context_entries(task: Path) -> list[tuple[str, int, str]]:
    entries = []
    for name in ('implement.jsonl', 'check.jsonl'):
        path = task / name
        if not path.is_file():
            continue
        for number, line in enumerate(path.read_text().splitlines(), 1):
            if line.strip():
                entries.append((f'{path.relative_to(REPO)}:{number}', number,
                                line))
    return entries


def check_tasks() -> Report:
    report = Report()
    tasks_dir = REPO / '.trellis/tasks'
    for task in sorted(tasks_dir.iterdir()):
        if not task.is_dir() or task.name == 'archive':
            continue
        for where, _, line in context_entries(task):
            try:
                entry = json.loads(line)
            except json.JSONDecodeError as e:
                report.error(where, f'not JSON: {e}')
                continue
            target = entry.get('file') if isinstance(entry, dict) else None
            if not isinstance(target, str):
                report.error(where, 'entry has no "file"')
            elif not (REPO / target).exists():
                report.error(where, f'file does not exist: {target}')
    return report


def print_report(report: Report) -> int:
    for line in report.warnings + report.errors:
        print(line)
    return 1 if report.errors else 0


def main_check() -> int:
    repo = Repo(REPO, git_files(REPO))
    report, stats = check_all(repo, dt.date.today())
    status = print_report(report)
    print(f'{stats["files"]} spec files, {stats["lines"]} lines, '
          f'{stats["rules"]} rules, {stats["tested"]} with a test; '
          f'{len(report.errors)} errors, {len(report.warnings)} warnings')
    return status


def main_for(paths: list[str]) -> int:
    repo = Repo(REPO, git_files(REPO))
    for path, summary in specs_for(repo, paths):
        print(f'{path}  {summary}')
    return 0


def main_diff(base: str) -> int:
    repo = Repo(REPO, git_files(REPO))
    paths = [p for p in changed_paths(base)
             if not p.startswith('.trellis/')]
    needed = specs_for(repo, paths)
    print(f'{len(paths)} changed paths since {base}; spec files to read:')
    for path, summary in needed:
        print(f'  {path}  {summary}')
    task = current_task()
    if task is None:
        print('no current Trellis task; context files not compared')
        return 0
    listed = set()
    for _, _, line in context_entries(task):
        entry = json.loads(line)
        if isinstance(entry, dict) and isinstance(entry.get('file'), str):
            listed.add(entry['file'])
    if not listed:
        print(f'{task.name} has no context entries (inline mode); '
              'read the files above directly')
        return 0
    for path, _ in needed:
        if path not in listed:
            print(f'warning: {task.name} context does not list {path}')
    return 0


# ----------------------------------------------------------------- self-test

GOOD_RULE_FILE = '''---
prefix: NAV
applies_to:
  - lib/app/**
reviewed: {today}
---

# Navigation

### NAV-01 Back goes home
- **Rule:** Back at a branch root returns to the first branch.
- **Why:** Users lost their place.
- **Check:** `test/nav_test.dart` "back goes home"
- **Code:** `lib/app/nav.dart`
'''

GOOD_INDEX = '''---
reviewed: {today}
---

# Frontend

- [nav.md](./nav.md) — read when changing navigation.
'''

GOOD_ROOT = '''---
reviewed: {today}
---

# Spec

- [frontend](./frontend/index.md)
'''


def self_test_case(edit) -> Report:
    today = dt.date(2026, 1, 31)
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        files = {
            'lib/app/nav.dart': '',
            'test/nav_test.dart': "test('back goes home', () {});",
            f'{SPEC_DIR}/index.md': GOOD_ROOT.format(today=today),
            f'{SPEC_DIR}/frontend/index.md': GOOD_INDEX.format(today=today),
            f'{SPEC_DIR}/frontend/nav.md':
                GOOD_RULE_FILE.format(today=today),
        }
        edit(files)
        for path, text in files.items():
            (root / path).parent.mkdir(parents=True, exist_ok=True)
            (root / path).write_text(text, encoding='utf-8')
        report, _ = check_all(Repo(root, set(files)), today)
        return report


def self_test() -> int:
    nav = f'{SPEC_DIR}/frontend/nav.md'

    def replace(old: str, new: str):
        def edit(files: dict[str, str]) -> None:
            assert old in files[nav], old
            files[nav] = files[nav].replace(old, new)
        return edit

    def append(text: str):
        def edit(files: dict[str, str]) -> None:
            files[nav] += text
        return edit

    def too_long(files: dict[str, str]) -> None:
        files[nav] += '\nfiller\n' * (HARD_LINE_LIMIT // 2)

    def unlisted(files: dict[str, str]) -> None:
        files[f'{SPEC_DIR}/frontend/other.md'] = files[nav].replace(
            'prefix: NAV', 'prefix: OTH').replace('NAV-01', 'OTH-01')

    cases = [
        ('valid tree', lambda files: None, None),
        ('over the hard limit', too_long, 'hard limit'),
        ('no Contents over 100 lines', append('\nline\n' * 60), 'Contents'),
        ('a task name', append('\nSee 10-12-spec-governance.\n'),
         'a task name'),
        ('a date', append('\nDecided on 2026-01-02.\n'), 'a date'),
        ('a PR number', append('\nFixed in #85.\n'), 'issue or PR number'),
        ('a private path', append('\nSee .trellis/tasks/x.\n'),
         'private path'),
        ('a duplicate ID', append(GOOD_RULE_FILE.split('---\n')[2]
                                  .split('# Navigation\n')[1]),
         'already used'),
        ('a wrong prefix', replace('### NAV-01', '### NAX-01'),
         'file prefix'),
        ('a missing field', replace('- **Why:** Users lost their place.\n',
                                    ''), 'needs the fields'),
        ('a missing test name', replace('"back goes home"', '"other"'),
         'not in test/nav_test.dart'),
        ('a missing code path', replace('lib/app/nav.dart', 'lib/app/x.dart'),
         'missing path'),
        ('a dead glob', replace('lib/app/**', 'lib/none/**'),
         'matches no file'),
        ('a long example', append('\n```\n' + 'x\n' * 11 + '```\n'),
         'code block'),
        ('a file missing from the index', unlisted, 'does not list other.md'),
    ]
    failures = 0
    for name, edit, expected in cases:
        report = self_test_case(edit)
        if expected is None:
            ok = not report.errors
        else:
            ok = any(expected in e for e in report.errors)
        if not ok:
            failures += 1
            print(f'FAIL {name}: expected {expected or "no errors"}, got:')
            for line in report.errors or ['(no errors)']:
                print(f'  {line}')
    print(f'{len(cases) - failures}/{len(cases)} self-test cases passed')
    return 1 if failures else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    group = parser.add_mutually_exclusive_group()
    group.add_argument('--for', dest='paths', nargs='+', metavar='PATH')
    group.add_argument('--diff', nargs='?', const='main', metavar='BASE')
    group.add_argument('--tasks', action='store_true')
    group.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    if args.paths:
        return main_for(args.paths)
    if args.diff:
        return main_diff(args.diff)
    if args.tasks:
        return print_report(check_tasks())
    return main_check()


if __name__ == '__main__':
    sys.exit(main())
