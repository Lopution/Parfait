---
prefix: SET
applies_to:
  - lib/app/widgets/settings/**
  - lib/features/settings/**
reviewed: 2026-10-14
---

# Settings pages and the Me tab

## Contents

- [Rows and groups](#rows-and-groups)
- [Search and ownership](#search-and-ownership)
- [Me tab](#me-tab)

## Rows and groups

### SET-01 Rows sit in SettingsGroup cards, never Divider
- **Rule:** Settings rows go inside `SettingsGroup`, which draws each child
  as its own `surfaceContainer` card 8dp apart, the gap being the only
  separator; never a `Divider`, never a hand-built group container.
  Explanations go in the group `footer`, after the rows. A leaving
  `Removable` row stops counting from the exit's first frame.
- **Why:** User decision: separate cards on settings pages and the Me page
  replaced the 2dp segmented list.
- **Check:** `test/architecture/settings_rows_test.dart` "SettingsSection is gone from lib/"
- **Code:** `lib/app/widgets/settings/settings_group.dart`

### SET-02 Choose the row by the number of values
- **Rule:** A setting with two to four values is a `SettingsMenuTile`
  (current value at the row's end, menu anchored below it on the end
  edge, never over the title). A longer list is a `SettingsGroup` of
  `SettingsChoiceTile`s, which mark the chosen row with a check and
  `ListTile.selected`, not a radio. A two-way property is a
  `SettingsControl` switch.
- **Why:** `RadioListTile` is deprecated in the pinned Flutter, and
  `selected` is what screen readers announce; segmented buttons were
  removed (NAV-17).
- **Check:** `test/selection_controls_haptics_test.dart`
- **Code:** `lib/app/widgets/settings/settings_menu_tile.dart`, `lib/app/widgets/settings/settings_choice_tile.dart`

### SET-03 Hand-written ListTiles only for content rows
- **Rule:** A hand-written `ListTile` is allowed only for data entries
  (muted items, accounts, diagnostic results). Adding one extends the
  architecture test's per-file whitelist with a reason.
- **Why:** Hand-built settings rows drifted from the shared look and
  haptics.
- **Check:** `test/architecture/settings_rows_test.dart` "hand-written ListTile rows match the design whitelist"
- **Code:** `lib/app/widgets/settings`

### SET-04 A setting needs a real consumer
- **Rule:** Every setting names the product behaviour it changes, and that
  consumer is code outside the settings pages (a feed filter, a request
  header, a download path). A setting without one is removed. A persisted
  field whose UI waits for a concrete future data source may stay as a
  field but is not shown.
- **Why:** Settings shipped that changed nothing (a content filter and a
  file-naming option).
- **Check:** manual
- **Code:** `lib/core/settings`

## Search and ownership

### SET-05 settings_catalog.dart is the whole search index
- **Rule:** A new setting is added to `Setting` in `settings_catalog.dart`
  and nowhere else; its row passes `setting:` so it takes its title from
  the catalog and is anchored. Conditional rows' titles go in
  `extraKeys`.
- **Why:** Rows missing from the index were unreachable from search.
- **Check:** `test/settings_search_test.dart` "title hits come before option hits, case and spaces ignored" "a result opens its page with the setting revealed and marked"
- **Code:** `lib/features/settings/settings_catalog.dart`, `lib/app/widgets/settings/settings_anchor.dart`

### SET-06 Each setting has one home page
- **Rule:** `/settings/motion` holds transition style, animation speed,
  reduced motion, press feedback and haptic strength. Credential export
  is in account management. History switches and delete-all are in the
  history page's overflow menu; there is no history settings page.
- **Why:** The same setting on two pages drifted apart.
- **Check:** `test/settings_search_test.dart`
- **Code:** `lib/features/settings/settings_catalog.dart`

## Me tab

### SET-07 The Me tab follows Shaft's me page
- **Rule:** The Me root is the account row, then three equal cards
  (bookmarks, following, download tasks with an active-task badge), rows
  of four plain entries (watchlist, history, watch later, local novels,
  then each destination the user took off the bottom bar) that go two to
  a row when narrow, then every settings page as a
  `SettingsTile` in one always-listed group headed by a search button.
- **Why:** User decision after comparing with Shaft: three cards, no
  fold.
- **Check:** `test/settings_test.dart` "the dashboard badge counts downloads as they start and end"
- **Code:** `lib/features/settings/me_dashboard_page.dart`
