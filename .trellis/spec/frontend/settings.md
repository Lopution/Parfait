---
prefix: SET
applies_to:
  - lib/app/widgets/settings/**
  - lib/features/settings/**
reviewed: 2026-10-17
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
  A note on one row is that row's subtitle; a note on the whole group, or
  on content without a subtitle (a slider, a form), is the group
  `footer`. On one page either every group has a title or none does. A
  leaving `Removable` row stops counting from the exit's first frame.
- **Why:** User decision: separate cards on settings pages and the Me page
  replaced the 2dp segmented list. Notes set apart from their row and a
  page with one titled group read as unrelated.
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

### SET-08 Page entries carry a circle in their group's color
- **Rule:** A row that opens a settings page from the index or the Me tab
  is `SettingsTile.topLevel`, its icon on a circle in its group's
  category tone (THEME-07): appearance purple, browse blue, network and
  download green, data orange; account, about and developer neutral.
  Rows inside a settings page show the bare icon.
- **Why:** User decision: the circle marks the top level, and one color
  per group tells the groups apart before their titles are read; on
  sub-pages the circle outweighed the setting rows around it.
- **Check:** manual
- **Code:** `lib/app/widgets/settings/settings_tile.dart`, `lib/features/settings/settings_page.dart`

### SET-09 A form is one card with its save at the end
- **Rule:** A form's fields and its `FilledButton` save sit in one
  `SettingsGroupContent` card, the save at the card's bottom end. Reset
  and clear actions are `SettingsActionTile` rows in a group under it.
  "Optional" is a field's helper text, never part of its label.
- **Why:** User decision: loose fields and buttons on the page surface
  did not read as one form. A long label was cut at narrow widths.
- **Check:** `test/translation_credentials_page_test.dart`
- **Code:** `lib/features/settings/pages/translation_credentials_page.dart`, `lib/features/settings/network_settings_page.dart`

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

### SET-07 The Me tab puts content before settings
- **Rule:** The Me root is the account row (no account ID), then the
  last eight history records as a row of covers with "see all" (hidden
  when the history is empty), then one card of content entries
  (bookmarks, following, watchlist, watch later, local novels, download
  tasks with an active-task badge, then each destination the user took
  off the bottom bar) three or four to a row, whichever leaves fewer
  gaps, two when narrow, then the settings index groups without the
  account group (`settingsIndexGroups(account: false)`), and under them
  `DeveloperSettingsGroup` (frame probe) when unlocked. Settings search
  is the top bar's search button. An illustration cover opens the detail
  pager over the row's illustrations in their order at the tap.
- **Why:** User decision: settings filled two thirds of the page in a
  style of their own, and nothing showed what the user saw last. Left
  only at the bottom of the index and unsearchable, the probe could not
  be found.
- **Check:** `test/settings_test.dart` "the dashboard badge counts downloads as they start and end" "the recent row follows the history and pages in its own order"
- **Code:** `lib/features/settings/me_dashboard_page.dart`
