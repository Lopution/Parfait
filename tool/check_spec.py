#!/usr/bin/env python3
"""Checks .trellis/spec against the format rules in .trellis/spec/index.md.

Usage:
  python3 tool/check_spec.py                  check every spec file (CI)
  python3 tool/check_spec.py --for PATH..     list the spec files covering PATHs
  python3 tool/check_spec.py --by-test PATH.. list spec rules anchored on test PATHs
  python3 tool/check_spec.py --diff [BASE]    spec files for this branch's changes
  python3 tool/check_spec.py --audit-diff [B] audit deleted tests/rules since BASE
  python3 tool/check_spec.py --tasks          task context files name real paths
  python3 tool/check_spec.py --self-test      run the checker's own tests

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
HARD_LINE_LIMIT = 400
SOFT_RULE_WORD_LIMIT = 300
CONTENTS_THRESHOLD = 100
MAX_EXAMPLE_LINES = 10
REVIEW_MAX_AGE_DAYS = 90

RULE_FIELDS = ('Rule', 'Why', 'Check', 'Code')
RULE_FILE_KEYS = {'prefix', 'applies_to', 'reviewed'}
INDEX_KEYS = {'reviewed'}

PREFIX_RE = re.compile(r'^[A-Z]{2,6}$')
RULE_HEADING_RE = re.compile(r'^### ([A-Z]{2,6})-(\d{2}) (\S.*)$')
RULE_REF_RE = re.compile(r'\b([A-Z]{2,6})-(\d{2})\b')
# Declared Dart test entry points plus explicit repo test-helper whitelist.
DART_TEST_DECL_CALLS = (
    'test',
    'testWidgets',
    'testE2e',
    'testGoldens',
    'group',
    'localeLayoutMatrix',
)
DART_TEST_DECL_START_RE = re.compile(
    r'\b(?:' + '|'.join(DART_TEST_DECL_CALLS) + r')\s*\('
)
DART_FOR_HEAD_RE = re.compile(r'\bfor\s*\(')
OS_E2E_FLOWS_PATH = 'tool/dev_workbench/catalog/os_e2e_flows.json'
FIELD_RE = re.compile(r'^- \*\*(\w+):\*\*')
BACKTICK_RE = re.compile(r'`([^`\n]+)`')
CHECK_ITEM_RE = re.compile(r'`([^`\n]+)`((?:\s*"(?:[^"\\\n]|\\.)+")*)')
QUOTED_RE = re.compile(r'"((?:[^"\\\n]|\\.)+)"')
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

# Process records and stale/internal implementation details that do not belong
# in a public spec.
FORBIDDEN = (
    (re.compile(r'\b20\d\d-\d\d(-\d\d)?\b'), 'a date'),
    (re.compile(r'(?<![\w./-])(?:0[1-9]|1[0-2])-(?:0[1-9]|[12]\d|3[01])(?![\w/-]|\.\d)'),
     'a bare MM-DD date'),
    (re.compile(r'\b\d\d-\d\d-[a-z][a-z0-9]*(-[a-z0-9]+)+'), 'a task name'),
    (re.compile(r'\.trellis/(tasks|workspace)|/root/|journal-\d'),
     'a private path'),
    (re.compile(r'(?<![\w/&])#\d+\b'), 'an issue or PR number'),
    (re.compile(r'\b(?=[0-9a-f]*\d)(?=[0-9a-f]*[a-f])[0-9a-f]{7,40}\b'),
     'a commit hash'),
    (re.compile(r'\bIcons\.[a-zA-Z_]\w*'),
     'a removed Material Icons.* reference'),
)

PRIVATE_SYMBOL_RE = re.compile(
    r'^_[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*(?:\(\))?$'
)
ADJ_SINGLE_STR_RE = re.compile(r"(?<!\\)'(?:\s*//[^\n]*)*\s*'")
ADJ_DOUBLE_STR_RE = re.compile(r'(?<!\\)"(?:\s*//[^\n]*)*\s*"')


def normalize_dart_strings(text: str) -> str:
    """Joins adjacent Dart string literals and unescapes quotes for matching."""
    joined = ADJ_SINGLE_STR_RE.sub('', text)
    joined = ADJ_DOUBLE_STR_RE.sub('', joined)
    return joined.replace("\\'", "'").replace('\\"', '"')


def _mask_dart_comments_and_strings(src: str) -> tuple[str, str]:
    """Returns (no_comments, code_only) with identical character offsets.

    `no_comments` blanks // and /* ... */ comments and triple-quoted string
    interiors while preserving single/double-quoted string literals for
    argument parsing. `code_only` blanks all comments and all string literal
    interiors so test declaration calls inside strings can never match.
    """
    no_comments: list[str] = []
    code_only: list[str] = []
    i = 0
    n = len(src)

    def emit(ch: str, *, blank_nc: bool = False, blank_co: bool = False) -> None:
        if ch == '\n':
            no_comments.append('\n')
            code_only.append('\n')
        else:
            no_comments.append(' ' if blank_nc else ch)
            code_only.append(' ' if blank_co else ch)

    while i < n:
        ch = src[i]
        if src.startswith('//', i):
            while i < n and src[i] != '\n':
                emit(src[i], blank_nc=True, blank_co=True)
                i += 1
            continue
        if src.startswith('/*', i):
            emit('/', blank_nc=True, blank_co=True)
            emit('*', blank_nc=True, blank_co=True)
            i += 2
            while i < n and not src.startswith('*/', i):
                emit(src[i], blank_nc=True, blank_co=True)
                i += 1
            if i < n:
                emit('*', blank_nc=True, blank_co=True)
                emit('/', blank_nc=True, blank_co=True)
                i += 2
            continue
        raw = False
        if ch == 'r' and i + 1 < n and src[i + 1] in ("'", '"'):
            raw = True
            emit(ch, blank_nc=False, blank_co=False)
            i += 1
            ch = src[i]
        if ch in ("'", '"'):
            if src.startswith(ch * 3, i):
                delim = ch * 3
                for c in delim:
                    emit(c, blank_nc=False, blank_co=False)
                i += 3
                while i < n and not src.startswith(delim, i):
                    if not raw and src[i] == '\\' and i + 1 < n:
                        emit(src[i], blank_nc=True, blank_co=True)
                        emit(src[i + 1], blank_nc=True, blank_co=True)
                        i += 2
                        continue
                    emit(src[i], blank_nc=True, blank_co=True)
                    i += 1
                if i < n:
                    for c in delim:
                        emit(c, blank_nc=False, blank_co=False)
                    i += 3
                continue
            q = ch
            emit(q, blank_nc=False, blank_co=False)
            i += 1
            while i < n:
                c = src[i]
                if not raw and c == '\\' and i + 1 < n:
                    emit(c, blank_nc=False, blank_co=True)
                    emit(src[i + 1], blank_nc=False, blank_co=True)
                    i += 2
                    continue
                if not raw and c == '$' and i + 1 < n and src[i + 1] == '{':
                    emit('$', blank_nc=False, blank_co=True)
                    emit('{', blank_nc=False, blank_co=True)
                    i += 2
                    depth = 1
                    in_sub: str | None = None
                    while i < n and depth > 0:
                        c2 = src[i]
                        if in_sub is not None:
                            if c2 == '\\' and i + 1 < n:
                                emit(c2, blank_nc=False, blank_co=True)
                                emit(src[i + 1], blank_nc=False, blank_co=True)
                                i += 2
                                continue
                            if c2 == in_sub:
                                in_sub = None
                            emit(c2, blank_nc=False, blank_co=True)
                            i += 1
                        elif c2 in ("'", '"'):
                            in_sub = c2
                            emit(c2, blank_nc=False, blank_co=True)
                            i += 1
                        elif c2 == '{':
                            depth += 1
                            emit(c2, blank_nc=False, blank_co=True)
                            i += 1
                        elif c2 == '}':
                            depth -= 1
                            emit(c2, blank_nc=False, blank_co=True)
                            i += 1
                        else:
                            emit(c2, blank_nc=False, blank_co=True)
                            i += 1
                    continue
                if c == q:
                    emit(c, blank_nc=False, blank_co=False)
                    i += 1
                    break
                emit(c, blank_nc=False, blank_co=True)
                i += 1
            continue
        emit(ch)
        i += 1
    return ''.join(no_comments), ''.join(code_only)


def _parse_dart_string_expr(src: str, pos: int) -> tuple[str, bool, int] | None:
    """Parses one or more adjacent Dart string literals at pos.

    Returns (decoded_value, has_interpolation, next_pos) or None.
    """
    n = len(src)
    while pos < n and src[pos].isspace():
        pos += 1
    if pos >= n:
        return None
    parts: list[str] = []
    has_interp = False
    while pos < n:
        raw = False
        if pos + 1 < n and src[pos] == 'r' and src[pos + 1] in ("'", '"'):
            raw = True
            pos += 1
        if pos >= n or src[pos] not in ("'", '"'):
            break
        q = src[pos]
        pos += 1
        buf: list[str] = []
        while pos < n:
            ch = src[pos]
            if not raw and ch == '\\' and pos + 1 < n:
                nxt = src[pos + 1]
                if nxt in ("'", '"', '\\', '$'):
                    buf.append(nxt)
                elif nxt == 'n':
                    buf.append('\n')
                else:
                    buf.append('\\' + nxt)
                pos += 2
                continue
            if not raw and ch == '$' and pos + 1 < n and src[pos + 1] == '{':
                has_interp = True
                buf.append('${')
                pos += 2
                depth = 1
                in_sub: str | None = None
                while pos < n and depth > 0:
                    c2 = src[pos]
                    if in_sub is not None:
                        buf.append(c2)
                        if c2 == '\\' and pos + 1 < n:
                            buf.append(src[pos + 1])
                            pos += 2
                            continue
                        if c2 == in_sub:
                            in_sub = None
                        pos += 1
                    elif c2 in ("'", '"'):
                        in_sub = c2
                        buf.append(c2)
                        pos += 1
                    elif c2 == '{':
                        depth += 1
                        buf.append(c2)
                        pos += 1
                    elif c2 == '}':
                        depth -= 1
                        buf.append(c2)
                        pos += 1
                    else:
                        buf.append(c2)
                        pos += 1
                continue
            if not raw and ch == '$':
                has_interp = True
            if ch == q:
                pos += 1
                break
            buf.append(ch)
            pos += 1
        parts.append(''.join(buf))
        while pos < n and src[pos].isspace():
            pos += 1
    if not parts:
        return None
    return ''.join(parts), has_interp, pos


def extract_dart_test_declarations(text: str) -> tuple[list[str], list[str]]:
    """Extracts declared Dart test names as (static_names, interp_templates)."""
    clean, code_only = _mask_dart_comments_and_strings(text)
    static: list[str] = []
    interp: list[str] = []
    seen_static: set[str] = set()
    seen_interp: set[str] = set()

    def add_static(name: str) -> None:
        if name not in seen_static:
            seen_static.add(name)
            static.append(name)

    def add_interp(tpl: str) -> None:
        if tpl not in seen_interp:
            seen_interp.add(tpl)
            interp.append(tpl)

    n = len(clean)
    for match in DART_TEST_DECL_START_RE.finditer(code_only):
        pos = match.end()
        while pos < n and clean[pos].isspace():
            pos += 1
        parsed = _parse_dart_string_expr(clean, pos)
        if parsed is not None:
            val, has_i, _ = parsed
            (add_interp if has_i else add_static)(val)
            continue
        # Scan first argument expression up to top-level ',' or ')'.
        j = pos
        dp = db = dc = 0
        in_s: str | None = None
        while j < n:
            c = clean[j]
            if in_s is not None:
                if c == '\\' and j + 1 < n:
                    j += 2
                    continue
                if c == in_s:
                    in_s = None
            elif c in ("'", '"'):
                in_s = c
            elif c == '(':
                dp += 1
            elif c == ')':
                if dp == 0:
                    break
                dp -= 1
            elif c == '[':
                db += 1
            elif c == ']':
                db -= 1
            elif c == '{':
                dc += 1
            elif c == '}':
                dc -= 1
            elif c == ',' and dp == 0 and db == 0 and dc == 0:
                break
            j += 1
        expr = clean[pos:j].strip()
        if '?' in expr and ':' in expr:
            q_idx = expr.find('?')
            c_idx = expr.find(':', q_idx)
            for seg in (expr[q_idx + 1:c_idx], expr[c_idx + 1:]):
                branch = _parse_dart_string_expr(seg, 0)
                if branch is not None:
                    (add_interp if branch[1] else add_static)(branch[0])
        elif re.fullmatch(r'[A-Za-z_]\w*', expr):
            window = clean[max(0, match.start() - 1200):match.start()]
            arr_start = -1
            for fm in DART_FOR_HEAD_RE.finditer(window):
                # Linear paren-balanced scan of the `for (...)` header.
                p_idx = fm.end() - 1
                p_depth = 0
                in_q: str | None = None
                while p_idx < len(window):
                    ch = window[p_idx]
                    if in_q is not None:
                        if ch == '\\' and p_idx + 1 < len(window):
                            p_idx += 2
                            continue
                        if ch == in_q:
                            in_q = None
                    elif ch in ("'", '"'):
                        in_q = ch
                    elif ch == '(':
                        p_depth += 1
                    elif ch == ')':
                        p_depth -= 1
                        if p_depth == 0:
                            break
                    p_idx += 1
                header = window[fm.end():p_idx]
                in_m = re.search(r'\bin\s*\[', header)
                if in_m is not None:
                    arr_start = fm.end() + in_m.end() - 1
            if arr_start >= 0:
                k = arr_start
                depth = 0
                ins: str | None = None
                while k < len(window):
                    ck = window[k]
                    if ins is not None:
                        if ck == '\\' and k + 1 < len(window):
                            k += 2
                            continue
                        if ck == ins:
                            ins = None
                    elif ck in ("'", '"'):
                        ins = ck
                    elif ck == '[':
                        depth += 1
                    elif ck == ']':
                        depth -= 1
                        if depth == 0:
                            break
                    k += 1
                arr_body = window[arr_start + 1:k]
                idx = 0
                while idx < len(arr_body):
                    if arr_body[idx] in ("'", '"'):
                        lit = _parse_dart_string_expr(arr_body, idx)
                        if lit is not None:
                            (add_interp if lit[1] else add_static)(lit[0])
                            idx = lit[2]
                            continue
                    idx += 1
    return static, interp


def extract_os_e2e_assertion_ids(text: str) -> list[str]:
    """Extracts declarative assertion IDs from `os_e2e_flows.json` in order."""
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        return []
    seen: set[str] = set()
    ids: list[str] = []
    for flow in data.get('flows') or []:
        if not isinstance(flow, dict):
            continue
        for spec in flow.get('assertions') or []:
            if not isinstance(spec, dict):
                continue
            aid = spec.get('id')
            if isinstance(aid, str) and aid.strip() and aid not in seen:
                seen.add(aid)
                ids.append(aid)
    return ids


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
            if is_repo_path(token):
                if not path_exists(repo, token):
                    report.error(at, f'path does not exist: {token}')
            elif (
                PRIVATE_SYMBOL_RE.match(token)
                and not token.endswith('.dart')
            ):
                report.error(
                    at, f'exposes a private Dart symbol: `{token}`'
                )
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
    prose_words = len((fields['Rule'] + ' ' + fields['Why']).split())
    if prose_words > SOFT_RULE_WORD_LIMIT:
        report.warn(
            at,
            f'{rule_id} is {prose_words} words '
            f'(aim for <= {SOFT_RULE_WORD_LIMIT}; consider splitting)',
        )
    check_field = fields['Check'].strip()
    items = CHECK_ITEM_RE.findall(check_field)
    if not items and not check_field.startswith('manual'):
        report.error(at, f'{rule_id} Check must name a test file or "manual"')
    for path, names in items:
        if not repo.exists(path):
            report.error(at, f'{rule_id} Check names a missing file: {path}')
            continue
        quoted = [q.replace('\\"', '"') for q in QUOTED_RE.findall(names)]
        if path == OS_E2E_FLOWS_PATH:
            if not quoted:
                report.error(
                    at,
                    f'{rule_id} Check names {path} without a quoted assertion ID',
                )
                continue
            raw_json = repo.read(path) if path in repo.files else ''
            known_ids = set(extract_os_e2e_assertion_ids(raw_json))
            for aid in quoted:
                if aid not in known_ids:
                    report.error(
                        at,
                        f'{rule_id} Check names an assertion ID that is not in {path}: "{aid}"',
                    )
            continue
        if path.endswith('_test.dart'):
            if not quoted:
                report.error(
                    at,
                    f'{rule_id} Check names {path} without a quoted test name',
                )
                continue
            raw_dart = repo.read(path) if path in repo.files else ''
            static_names, interp_templates = extract_dart_test_declarations(raw_dart)
            declared_set = set(static_names) | set(interp_templates)
            for name in quoted:
                if name in declared_set:
                    continue
                report.error(
                    at,
                    f'{rule_id} Check names a test that is not declared '
                    f'in {path}: "{name}"',
                )
            continue
        text = (
            normalize_dart_strings(repo.read(path))
            if path in repo.files
            else ''
        )
        for name in quoted:
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


def check_rule_refs(specs: list[SpecFile], prefixes: dict[str, str],
                    seen_ids: dict[str, str], report: Report) -> None:
    """Reject inline references to non-existent rule IDs of known prefixes."""
    known_prefixes = set(prefixes)
    for spec in specs:
        where = str(spec.path)
        for number, line, fenced in body_lines(spec):
            if fenced or line.startswith('### '):
                continue
            for match in RULE_REF_RE.finditer(line):
                prefix, num = match.group(1), match.group(2)
                if prefix not in known_prefixes:
                    continue
                rule_id = f'{prefix}-{num}'
                if rule_id not in seen_ids:
                    report.error(f'{where}:{number}',
                                 f'unknown rule reference: {rule_id}')


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
            if line.startswith('- **Check:**')
            and ('`test/' in line or f'`{OS_E2E_FLOWS_PATH}`' in line))
    check_rule_refs(specs, prefixes, seen_ids, report)
    check_indexes(specs, report)
    return report, stats


def parse_rule_checks(
    spec: SpecFile,
) -> list[tuple[str, str, list[tuple[str, list[str]]]]]:
    """Extracts (rule_id, title, [(check_path, [quoted_names])]) from a spec."""
    entries: list[tuple[str, str, list[tuple[str, list[str]]]]] = []
    cur_id = ''
    cur_title = ''
    check_text_buf = ''
    in_check = False

    def flush() -> None:
        nonlocal cur_id, cur_title, check_text_buf, in_check
        if not cur_id:
            return
        items = [
            (
                path.lstrip('./').rstrip('/'),
                [q.replace('\\"', '"') for q in QUOTED_RE.findall(names)],
            )
            for path, names in CHECK_ITEM_RE.findall(check_text_buf)
        ]
        entries.append((cur_id, cur_title, items))
        cur_id = ''
        cur_title = ''
        check_text_buf = ''
        in_check = False

    for _, line, fenced in body_lines(spec):
        if fenced:
            continue
        if line.startswith('### '):
            flush()
            match = RULE_HEADING_RE.match(line)
            if match:
                cur_id = f'{match.group(1)}-{match.group(2)}'
                cur_title = match.group(3).strip()
            continue
        if line.startswith('## '):
            flush()
            continue
        if not cur_id:
            continue
        field_match = FIELD_RE.match(line)
        if field_match:
            if field_match.group(1) == 'Check':
                in_check = True
                check_text_buf = line[field_match.end():].strip()
            else:
                in_check = False
        elif in_check and line.startswith('  '):
            check_text_buf += ' ' + line.strip()
        else:
            in_check = False
    flush()
    return entries


def rules_by_test(
    specs: list[SpecFile], test_paths: list[str]
) -> dict[str, list[tuple[str, str, str, list[str]]]]:
    """Reverse-maps each test path (or directory) to rules referencing it."""
    normalized = [p.lstrip('./').rstrip('/') for p in test_paths]
    hits: dict[str, list[tuple[str, str, str, list[str]]]] = {
        p: [] for p in normalized
    }
    for spec in specs:
        if spec.is_index:
            continue
        spec_path = str(spec.path)
        for rule_id, title, items in parse_rule_checks(spec):
            for target in normalized:
                matched_names: list[str] = []
                matched = False
                for check_path, quoted in items:
                    if (check_path == target
                            or check_path.startswith(f'{target}/')):
                        matched = True
                        matched_names.extend(quoted)
                if matched:
                    hits[target].append(
                        (rule_id, spec_path, title, matched_names)
                    )
    return hits


def is_audited_test_file(path: str) -> bool:
    return (
        (path.startswith('test/') and path.endswith('_test.dart'))
        or (path.startswith('android/app/src/test/') and path.endswith('.kt'))
        or path == OS_E2E_FLOWS_PATH
    )


def extract_dart_test_cases(text: str) -> list[str]:
    """Extracts declared Dart test case names in order."""
    static_names, interp_templates = extract_dart_test_declarations(text)
    return static_names + [t for t in interp_templates if t not in set(static_names)]


def extract_rule_headings(spec: SpecFile) -> dict[str, str]:
    headings: dict[str, str] = {}
    for _, line, fenced in body_lines(spec):
        if fenced or not line.startswith('### '):
            continue
        match = RULE_HEADING_RE.match(line)
        if match:
            rule_id = f'{match.group(1)}-{match.group(2)}'
            headings[rule_id] = match.group(3).strip()
    return headings


def parse_spec_from_text(path: str, text: str) -> SpecFile | None:
    lines = text.splitlines()
    try:
        meta, start = parse_frontmatter(lines)
    except ValueError:
        return None
    return SpecFile(Path(path), lines, meta, start)


def audit_deletions(
    base_files: dict[str, str],
    current_files: dict[str, str],
    current_specs: list[SpecFile],
    base_specs: list[SpecFile],
) -> dict[str, object]:
    """Computes deleted test files, removed test cases, and removed rules."""
    current_rule_checks: dict[str, tuple[str, set[str]]] = {}
    for spec in current_specs:
        if spec.is_index:
            continue
        for rule_id, _, items in parse_rule_checks(spec):
            current_rule_checks[rule_id] = (
                str(spec.path), {path for path, _ in items}
            )

    deleted_test_paths = sorted(
        p for p in base_files
        if is_audited_test_file(p) and p not in current_files
    )
    base_anchors = rules_by_test(base_specs, deleted_test_paths)
    deleted_test_files: list[tuple[str, int, list[tuple[str, str, str]]]] = []
    for test_path in deleted_test_paths:
        if test_path.startswith('test/') and test_path.endswith('_test.dart'):
            base_case_count = len(extract_dart_test_cases(base_files[test_path]))
        elif test_path == OS_E2E_FLOWS_PATH:
            base_case_count = len(extract_os_e2e_assertion_ids(base_files[test_path]))
        else:
            base_case_count = 0
        rule_statuses: list[tuple[str, str, str]] = []
        for rule_id, spec_path, _, _ in base_anchors.get(test_path, []):
            if rule_id not in current_rule_checks:
                status = 'RULE DELETED'
            elif test_path in current_rule_checks[rule_id][1]:
                status = 'STILL REFERENCED'
            else:
                status = 'migrated'
            rule_statuses.append((rule_id, spec_path, status))
        deleted_test_files.append((test_path, base_case_count, rule_statuses))

    deleted_test_cases: list[tuple[str, list[str]]] = []
    for path in sorted(base_files):
        if path not in current_files or base_files[path] == current_files[path]:
            continue
        if path.startswith('test/') and path.endswith('_test.dart'):
            base_cases = extract_dart_test_cases(base_files[path])
            cur_cases = set(extract_dart_test_cases(current_files[path]))
        elif path == OS_E2E_FLOWS_PATH:
            base_cases = extract_os_e2e_assertion_ids(base_files[path])
            cur_cases = set(extract_os_e2e_assertion_ids(current_files[path]))
        else:
            continue
        removed = [c for c in base_cases if c not in cur_cases]
        if removed:
            deleted_test_cases.append((path, removed))

    deleted_spec_rules: list[tuple[str, str, str]] = []
    cur_rules_by_path: dict[str, dict[str, str]] = {
        str(s.path): extract_rule_headings(s)
        for s in current_specs if not s.is_index
    }
    for spec in base_specs:
        if spec.is_index:
            continue
        spec_path = str(spec.path)
        if spec_path not in base_files:
            continue
        cur_rules = cur_rules_by_path.get(spec_path, {})
        for rule_id, title in extract_rule_headings(spec).items():
            if rule_id not in cur_rules:
                deleted_spec_rules.append((rule_id, spec_path, title))

    return {
        'deleted_test_files': deleted_test_files,
        'deleted_test_cases': deleted_test_cases,
        'deleted_spec_rules': deleted_spec_rules,
    }


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


def main_by_test(paths: list[str]) -> int:
    repo = Repo(REPO, git_files(REPO))
    specs = load_spec(repo, Report())
    hits = rules_by_test(specs, paths)
    for target, rules in hits.items():
        if not rules:
            print(f'{target}: (no spec Check: references)')
            continue
        print(f'{target}: {len(rules)} spec rule(s)')
        for rule_id, spec_path, title, quoted in rules:
            detail = (
                ' — ' + ', '.join(f'"{q}"' for q in quoted)
                if quoted else ''
            )
            print(f'  {rule_id} ({spec_path}) {title}{detail}')
    return 0


def git_show_optional(rev: str, path: str) -> str | None:
    result = subprocess.run(
        ['git', 'show', f'{rev}:{path}'],
        cwd=REPO, capture_output=True, text=True,
    )
    return result.stdout if result.returncode == 0 else None


def main_audit_diff(base: str) -> int:
    merge_base = run_git('merge-base', base, 'HEAD').strip()
    diff_lines = run_git(
        'diff', '--name-status', '--no-renames', merge_base,
    ).splitlines()
    touched_tests: list[tuple[str, str]] = []
    touched_specs: list[tuple[str, str]] = []
    for line in diff_lines:
        if not line.strip():
            continue
        status, path = line.split('\t', 1)
        if is_audited_test_file(path):
            touched_tests.append((status, path))
        elif path.startswith(f'{SPEC_DIR}/') and path.endswith('.md'):
            touched_specs.append((status, path))

    base_files: dict[str, str] = {}
    current_files: dict[str, str] = {}
    for status, path in touched_tests + touched_specs:
        if status != 'A':
            old_text = git_show_optional(merge_base, path)
            if old_text is not None:
                base_files[path] = old_text
        cur_path = REPO / path
        if status != 'D' and cur_path.is_file():
            current_files[path] = cur_path.read_text(encoding='utf-8')

    repo = Repo(REPO, git_files(REPO))
    current_specs = load_spec(repo, Report())
    # Reconstruct base-side specs only when needed (deleted tests or edited specs).
    base_specs: list[SpecFile] = []
    if any(st == 'D' for st, _ in touched_tests) or touched_specs:
        base_spec_paths = run_git(
            'ls-tree', '-r', '--name-only', merge_base, str(SPEC_DIR),
        ).splitlines()
        for sp in sorted(p for p in base_spec_paths if p.endswith('.md')):
            txt = base_files.get(sp)
            if txt is None:
                txt = git_show_optional(merge_base, sp)
            if txt is not None:
                parsed = parse_spec_from_text(sp, txt)
                if parsed is not None:
                    base_specs.append(parsed)

    audit = audit_deletions(base_files, current_files, current_specs, base_specs)
    del_files = audit['deleted_test_files']
    del_cases = audit['deleted_test_cases']
    del_rules = audit['deleted_spec_rules']
    case_total = sum(len(cases) for _, cases in del_cases)
    print(
        f'{len(del_files)} deleted test files, {case_total} deleted test cases, '
        f'{len(del_rules)} deleted spec rules'
    )
    if del_files:
        print('Deleted test files (--by-test impact vs base):')
        for path, case_count, rules in del_files:
            cases_note = f'{case_count} base case(s), ' if case_count else ''
            if not rules:
                print(f'  {path} ({cases_note}0 base spec anchors)')
            else:
                print(f'  {path} ({cases_note}{len(rules)} base spec anchor(s)):')
                for rule_id, spec_path, st in rules:
                    print(f'    {rule_id} ({spec_path}) [{st}]')
    if del_cases:
        print('Deleted test cases in modified Dart test files:')
        for path, cases in del_cases:
            print(f'  {path} (-{len(cases)}):')
            for name in cases[:20]:
                print(f'    - "{name}"')
            if len(cases) > 20:
                print(f'    ... +{len(cases) - 20} more')
    if del_rules:
        print('Deleted spec rules:')
        for rule_id, spec_path, title in del_rules:
            print(f'  {rule_id} ({spec_path}) {title}')
    if del_files or del_cases or del_rules:
        print('note: document replacement coverage or removed behaviour for '
              'each deletion (TEST-04 / TEST-13)')
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
         'not declared in test/nav_test.dart'),
        ('a truncated static test prefix is rejected',
         replace('"back goes home"', '"back goes"'),
         'not declared in test/nav_test.dart'),
        ('a comment containing quoted text does not satisfy Check', lambda files: files.update({
            'test/nav_test.dart': "// back goes home\ntest('real case', () {});",
        }), 'not declared in test/nav_test.dart'),
        ('a fake declaration inside a triple-quoted string is rejected', lambda files: files.update({
            'test/nav_test.dart': "const s = '''\ntest('back goes home', () {});\n''';\ntest('real case', () {});",
        }), 'not declared in test/nav_test.dart'),
        ('a fake declaration inside a normal string literal is rejected', lambda files: files.update({
            'test/nav_test.dart': 'const s = "test(\'back goes home\', () {});";\ntest(\'real case\', () {});',
        }), 'not declared in test/nav_test.dart'),
        ('escaped apostrophe in static test name matches', lambda files: files.update({
            'test/nav_test.dart': r"test('user\'s back goes home', () {});",
            nav: files[nav].replace('"back goes home"', '"user\'s back goes home"'),
        }), None),
        ('whitelisted localeLayoutMatrix helper declaration matches', lambda files: files.update({
            'test/nav_test.dart': "localeLayoutMatrix('back goes home', () {});",
        }), None),
        ('interpolated test declaration rejects partial substring', lambda files: files.update({
            'test/nav_test.dart': "test('back goes home ($mode)', () {});",
        }), 'not declared in test/nav_test.dart'),
        ('interpolated test declaration matches exact template string', lambda files: files.update({
            'test/nav_test.dart': "test('back goes home ($mode)', () {});",
            nav: files[nav].replace('"back goes home"', '"back goes home ($mode)"'),
        }), None),
        ('a missing code path', replace('lib/app/nav.dart', 'lib/app/x.dart'),
         'missing path'),
        ('a dead glob', replace('lib/app/**', 'lib/none/**'),
         'matches no file'),
        ('a long example', append('\n```\n' + 'x\n' * 11 + '```\n'),
         'code block'),
        ('a file missing from the index', unlisted, 'does not list other.md'),
        ('a bare MM-DD date', append('\nDecided on 10-21.\n'),
         'bare MM-DD date'),
        ('a removed Material Icons.* ref', append('\nUses `Icons.close`.\n'),
         'Material Icons.*'),
        ('a private Dart symbol', append('\nUses `_PrivateHelper`.\n'),
         'private Dart symbol'),
        ('whole-file Dart test Check', replace('"back goes home"', ''),
         'without a quoted test name'),
        ('multiline Dart test name matches', lambda files: files.update({
            'test/nav_test.dart': "test('back '\n  'goes home', () {});",
        }), None),
        ('unknown cross-rule reference (same prefix)',
         append('\nSee also NAV-99.\n'), 'unknown rule reference: NAV-99'),
        ('unknown cross-rule reference (other known prefix)', lambda files: (
            files.update({
                f'{SPEC_DIR}/frontend/other.md': files[nav].replace(
                    'prefix: NAV', 'prefix: OTH').replace('NAV-01', 'OTH-01'),
                f'{SPEC_DIR}/frontend/index.md':
                    files[f'{SPEC_DIR}/frontend/index.md']
                    + '- [other.md](./other.md) — read when testing other.\n',
                nav: files[nav] + '\nSee also OTH-99.\n',
            })
        ), 'unknown rule reference: OTH-99'),
        ('non-spec uppercase dash token is ignored',
         append('\nEncodes UTF-16 and SHA-256 cleanly.\n'), None),
        ('valid os_e2e_flows.json assertion ID anchor', lambda files: files.update({
            OS_E2E_FLOWS_PATH: json.dumps({
                'flows': [{
                    'id': 'os.demo',
                    'assertions': [{'id': 'os.demo.ok', 'type': 'zero_uncaught_errors'}],
                }]
            }),
            nav: files[nav].replace(
                '`test/nav_test.dart` "back goes home"',
                f'`{OS_E2E_FLOWS_PATH}` "os.demo.ok"',
            ),
        }), None),
        ('os_e2e_flows.json Check without quoted assertion ID fails', lambda files: files.update({
            OS_E2E_FLOWS_PATH: json.dumps({'flows': []}),
            nav: files[nav].replace(
                '`test/nav_test.dart` "back goes home"',
                f'`{OS_E2E_FLOWS_PATH}`',
            ),
        }), 'without a quoted assertion ID'),
        ('os_e2e_flows.json Check with unknown assertion ID fails', lambda files: files.update({
            OS_E2E_FLOWS_PATH: json.dumps({
                'flows': [{
                    'id': 'os.demo',
                    'assertions': [{'id': 'os.demo.ok', 'type': 'zero_uncaught_errors'}],
                }]
            }),
            nav: files[nav].replace(
                '`test/nav_test.dart` "back goes home"',
                f'`{OS_E2E_FLOWS_PATH}` "os.demo.missing"',
            ),
        }), 'assertion ID that is not in'),
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

    # Unit-test --by-test reverse index and --audit-diff deletion logic.
    today = dt.date(2026, 1, 31)
    base_nav = GOOD_RULE_FILE.format(today=today)
    base_spec = parse_spec_from_text(nav, base_nav)
    assert base_spec is not None
    by_test = rules_by_test([base_spec], ['test/nav_test.dart', 'test/none.dart'])
    extra_checks = [
        ('by-test finds anchored rule',
         len(by_test['test/nav_test.dart']) == 1
         and by_test['test/nav_test.dart'][0][0] == 'NAV-01'),
        ('by-test returns empty for unreferenced file',
         by_test['test/none.dart'] == []),
    ]
    migrated_nav = base_nav.replace('test/nav_test.dart', 'test/e2e_test.dart')
    migrated_spec = parse_spec_from_text(nav, migrated_nav)
    assert migrated_spec is not None
    audit_migrated = audit_deletions(
        base_files={
            'test/nav_test.dart': "test('back goes home', () {});\ntest('extra', () {});",
            nav: base_nav,
        },
        current_files={nav: migrated_nav},
        current_specs=[migrated_spec],
        base_specs=[base_spec],
    )
    extra_checks.append((
        'audit detects deleted test file, base case count, and migrated anchor',
        audit_migrated['deleted_test_files'] == [
            ('test/nav_test.dart', 2, [('NAV-01', nav, 'migrated')])
        ],
    ))
    empty_nav = base_nav.split('### NAV-01')[0]
    empty_spec = parse_spec_from_text(nav, empty_nav)
    assert empty_spec is not None
    audit_removed = audit_deletions(
        base_files={
            'test/nav_test.dart': (
                "test('back goes home', () {});\n"
                "testWidgets('keeps tab', (t) async {});\n"
                "testE2e('real shell journey', (t) async {});\n"
            ),
            OS_E2E_FLOWS_PATH: json.dumps({
                'flows': [{
                    'id': 'os.demo',
                    'assertions': [
                        {'id': 'os.demo.keep', 'type': 'zero_uncaught_errors'},
                        {'id': 'os.demo.drop', 'type': 'process_alive'},
                    ],
                }]
            }),
            nav: base_nav,
        },
        current_files={
            'test/nav_test.dart': "test('back goes home', () {});\n",
            OS_E2E_FLOWS_PATH: json.dumps({
                'flows': [{
                    'id': 'os.demo',
                    'assertions': [
                        {'id': 'os.demo.keep', 'type': 'zero_uncaught_errors'},
                    ],
                }]
            }),
            nav: empty_nav,
        },
        current_specs=[empty_spec],
        base_specs=[base_spec],
    )
    extra_checks.extend([
        ('audit detects deleted testWidgets and testE2e cases and OS assertion IDs',
         audit_removed['deleted_test_cases'] == [
             ('test/nav_test.dart', ['keeps tab', 'real shell journey']),
             (OS_E2E_FLOWS_PATH, ['os.demo.drop']),
         ]),
        ('audit detects deleted spec rule',
         audit_removed['deleted_spec_rules'] == [
             ('NAV-01', nav, 'Back goes home')
         ]),
        ('oversized rule emits soft word-count warning',
         any(
             'aim for <= ' in w
             for w in self_test_case(
                 replace(
                     'Back at a branch root returns to the first branch.',
                     ' '.join(['word'] * (SOFT_RULE_WORD_LIMIT + 10)),
                 )
             ).warnings
         )),
    ])
    for name, ok in extra_checks:
        if not ok:
            failures += 1
            print(f'FAIL {name}')

    total = len(cases) + len(extra_checks)
    print(f'{total - failures}/{total} self-test cases passed')
    return 1 if failures else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    group = parser.add_mutually_exclusive_group()
    group.add_argument('--for', dest='paths', nargs='+', metavar='PATH')
    group.add_argument('--by-test', dest='test_paths', nargs='+',
                       metavar='PATH')
    group.add_argument('--diff', nargs='?', const='main', metavar='BASE')
    group.add_argument('--audit-diff', dest='audit_base', nargs='?',
                       const='main', metavar='BASE')
    group.add_argument('--tasks', action='store_true')
    group.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    if args.paths:
        return main_for(args.paths)
    if args.test_paths:
        return main_by_test(args.test_paths)
    if args.diff:
        return main_diff(args.diff)
    if args.audit_base:
        return main_audit_diff(args.audit_base)
    if args.tasks:
        return print_report(check_tasks())
    return main_check()


if __name__ == '__main__':
    sys.exit(main())
