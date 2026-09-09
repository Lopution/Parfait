#!/usr/bin/env python3
"""Generate the dynamic-key lookup over AppLocalizations (child C / C6).

The widget layer has a few genuinely dynamic call sites (widget titleKey
params, enum labelKeys, error-code maps). They resolve through the
generated `l10nLookup` switch; unknown keys fall back to the key itself,
matching the legacy ReplicaStrings table fallback.

Run after `flutter gen-l10n` whenever the ARB keys change:
  python3 tool/gen_l10n_lookup.py
"""
from __future__ import annotations

import json
import re
from pathlib import Path

ARB = Path('lib/l10n/app_zh.arb')
OUT = Path('lib/l10n/lookup.dart')


def main() -> None:
    arb = json.loads(ARB.read_text())
    cases = []
    for key in sorted(arb):
        if key.startswith('@'):
            continue
        if re.findall(r'\{(\w+)\}', arb[key]):
            continue
        cases.append(f"      '{key}' => l10n.{key},")
    body = '\n'.join(cases)
    OUT.write_text(
        "\n"
        "import 'package:flutter/widgets.dart';\n"
        "\n"
        "import '../core/i18n/replica_strings.dart' show ReplicaLanguage;\n"
        "import 'app_localizations.dart';\n"
        "\n"
        "/// Locale access for the legacy language enum (onboarding previews).\n"
        "extension ReplicaLanguageLocale on ReplicaLanguage {\n"
        "  Locale get locale => parseAppLocale(tag);\n"
        "}\n"
        "\n"
        "/// Converts a BCP-47 tag ('zh-CN') into a [Locale].\n"
        "Locale parseAppLocale(String tag) {\n"
        "  final parts = tag.replaceAll('_', '-').split('-');\n"
        "  return Locale(parts.first, parts.length > 1 ? parts[1] : null);\n"
        "}\n"
        "\n"
        "/// Dynamic key lookup for call sites that cannot statically name their\n"
        "/// message (C6). Unknown keys return the key itself.\n"
        "String l10nLookup(AppLocalizations l10n, String key) => switch (key) {\n"
        f"{body}\n"
        "      _ => key,\n"
        "    };\n"
        "\n"
        "/// Lookup against an explicit locale (language picker previews).\n"
        "///\n"
        "/// gen-l10n's delegate completes synchronously for its bundled ARBs\n"
        "/// (SynchronousFuture), so the listener runs before we return.\n"
        "String l10nLookupFor(Locale locale, String key) {\n"
        "  late String result;\n"
        "  AppLocalizations.delegate.load(locale).then((l10n) {\n"
        "    result = l10nLookup(l10n, key);\n"
        "  });\n"
        "  return result;\n"
        "}\n"
    )
    print(f'{OUT}: {len(cases)} keys')


if __name__ == '__main__':
    main()
