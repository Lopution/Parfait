#!/usr/bin/env python3
"""One-shot ReplicaStrings -> ARB migrator (child C / C6).

Reads the frozen ReplicaStrings._values table from
lib/core/i18n/replica_strings.dart and emits one ARB file per language into
lib/l10n/. The zh-CN file is the template. `{param}` slots become ARB
placeholders typed as String.

Usage: python3 tool/migrate_i18n.py
"""
from __future__ import annotations

import json
import re
from pathlib import Path

SRC = Path('lib/core/i18n/replica_strings.dart')
OUT = Path('lib/l10n')

LANGS = {'zhCN': 'zh', 'enUS': 'en', 'jaJP': 'ja', 'ruRU': 'ru'}


def parse_values(src: str) -> dict[str, dict[str, str]]:
    """Parse the _values literal into {lang: {key: value}}.

    Values are Dart string literals; the table only contains simple
    single-quoted strings with {param} slots (no escapes in the corpus).
    """
    values: dict[str, dict[str, str]] = {}
    for m in re.finditer(r"ReplicaLanguage\.(\w+): \{(.*?)\n    \}", src, re.S):
        lang, body = m.group(1), m.group(2)
        entries: dict[str, str] = {}
        # Key and value are single-quoted literals; values may contain escaped
        # quotes but the corpus does not. Parse greedily per line.
        for em in re.finditer(r"'([\w]+)': '((?:[^'\\]|\\.)*)'", body):
            entries[em.group(1)] = em.group(2).replace("\\'", "'")
        values[lang] = entries
    return values


def arb_entry(key: str, value: str) -> dict:
    params = re.findall(r'\{(\w+)\}', value)
    entry: dict = value
    if params:
        entry = {
            '@key': {
                'placeholders': {p: {'type': 'String'} for p in params},
            },
        }
        # rebuild: value must be under the key; placeholders under @key
        return None  # handled by caller
    return entry


def main() -> None:
    src = SRC.read_text()
    values = parse_values(src)
    zh = values['zhCN']
    OUT.mkdir(parents=True, exist_ok=True)

    for lang_code, locale in LANGS.items():
        table = values.get(lang_code, {})
        arb: dict = {'@@locale': locale}
        for key, zh_value in zh.items():
            value = table.get(key)
            if value is None:
                # Missing translation falls back to zh (same as ReplicaStrings
                # runtime fallback). Keep the key so gen-l10n stays complete.
                value = zh_value
            params = re.findall(r'\{(\w+)\}', value)
            arb[key] = value
            if params:
                arb[f'@{key}'] = {
                    'placeholders': {
                        p: {'type': 'String'} for p in params
                    },
                }
        path = OUT / f'app_{locale}.arb'
        path.write_text(json.dumps(arb, ensure_ascii=False, indent=2) + '\n')
        print(f'{path}: {len(arb) - 1} entries (placeholders included)')


if __name__ == '__main__':
    main()
