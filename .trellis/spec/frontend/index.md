---
reviewed: 2026-10-12
---

# Frontend

UI code: `lib/app`, `lib/features`, `lib/l10n`. Format and admission rules
for every spec file are in the [spec root](../index.md).

## Pre-Development Checklist

1. Run `python3 tool/check_spec.py --for <paths you will change>` and read
   the files it lists. Without paths yet, pick from the table below.
2. Read [guides](../guides/index.md).
3. Rules marked "User decision" are not yours to change; ask first.

## Files

| File | Read when |
|---|---|
| [theme.md](./theme.md) | Touching colours, type, spacing, text fields, chrome over artwork. |
| [navigation.md](./navigation.md) | Adding routes, pushing pages, the bottom bar, branch switching, top tabs, choice controls. |
| [system-ui.md](./system-ui.md) | Changing status or navigation bar style, immersive pages, edge-to-edge chrome. |
| [transitions.md](./transitions.md) | Page transitions, back gesture, Hero flights, image quality hand-off. |
| [artwork-detail.md](./artwork-detail.md) | The work detail page, its sections and the viewer. |
| [feedback.md](./feedback.md) | Menus, dialogs, sheets, prompts, Undo, haptics, clipboard. |
| [motion.md](./motion.md) | Any animation, press feedback, removal animations, per-card rebuild cost. |
| [feeds.md](./feeds.md) | Feed grids, empty and error states, pull to refresh, scroll physics, skeletons. |
| [layout.md](./layout.md) | New or changed UI text, rows of controls, headers, keyboards, semantics. |
| [pages.md](./pages.md) | Profile, ranking, search results, comments, translation, library and management lists. |
| [settings.md](./settings.md) | Settings rows, settings search, the Me tab, adding a setting. |
| [novel-reader.md](./novel-reader.md) | Novel markup parsing, reader layout, bilingual reading, reader chrome. |

## Quality Check

- `python3 tool/check_spec.py --diff` lists the spec files for your
  changes; confirm each rule there still holds.
- `dart format --output=none --set-exit-if-changed lib test` and
  `flutter analyze` are clean.
- Run the tests named in the **Check** fields of the rules you touched,
  plus `test/architecture/`.
- UI text changes: run `test/locale_layout/`.
- Any new animation has a reduced-motion test.
