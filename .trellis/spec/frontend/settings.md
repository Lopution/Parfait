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
  `footer`. So is the note of an empty group (what it would list, where
  that comes from): never a card of its own. On one page either every
  group has a title or none does. A leaving `Removable` row stops
  counting from the exit's first frame.
- **Why:** User decision: separate cards on settings pages replaced the 2dp
  segmented list. The Me tab is not a settings page and lists its rows
  plainly (SET-07). Notes set apart from their row and a
  page with one titled group read as unrelated. An empty group's note on
  a card read as a row to press (user report, 10-25).
- **Check:** `test/architecture/settings_rows_test.dart` "SettingsSection is gone from lib/"; `test/muted_items_page_test.dart` "an empty group says where its mutes come from, off the cards"
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
- **Rule:** A row that opens a settings page from the index is
  `SettingsTile.topLevel`, its icon on a circle in its group's
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

### SET-10 A row's end says what a tap does
- **Rule:** A row that opens a page of the app is a `SettingsTile` and
  ends in a chevron. A row that leaves the app (a browser) ends its link
  text in an `open_in_new` glyph in the text's size and colour. A row
  that acts in place names the action and shows no glyph; a value row
  shows its value at its end. Facts about the app (its icon, name and
  attribution) head the About page on the page surface, not in a card.
  The version stays a plain value row, though seven taps on it unlock
  the developer options.
- **Why:** User report (10-25): on the About page the license, the
  source link and the facts were alike cards; what opened a page, what
  left the app and what did nothing could not be told apart. The
  attribution left the settings search: it is not a setting.
- **Check:** manual
- **Code:** `lib/features/settings/pages/about_settings_page.dart`, `lib/app/widgets/settings/settings_tile.dart`

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
- **Rule:** `/settings/motion` holds animation speed,
  reduced motion, press feedback and haptic strength. Credential export
  is in account management. History switches and delete-all are in the
  history page's overflow menu; there is no history settings page.
- **Why:** The same setting on two pages drifted apart.
- **Check:** `test/settings_search_test.dart`
- **Code:** `lib/features/settings/settings_catalog.dart`

## Me tab

### SET-07 The Me tab puts content before settings
- **Rule:** The Me root is laid out as YouTube's: no buttons on its top
  bar, and no card but the account header. First the account header, a
  `PersonCard` (PAGE-07): a 72dp avatar, the name with a neutral
  "Premium" pill for a premium account, and the user ID under it,
  together one button that opens the profile (its screen-reader hint
  says so); account management is its own icon button at the card's
  end, its glyph on the card's padding. Signed out, the header is one
  button to the login, with no manage button. Then the last eight
  history records as a row of covers with
  "see all" (hidden when the history is empty), then the content entries
  as list rows with a neutral icon (bookmarks, following, watchlist,
  watch later, local novels, download tasks with the active-task count
  at the row's end, then each destination the user took off the bottom
  bar), then a divider and two rows: settings (the index) and about. The
  settings groups and the developer group live on the index only. A
  cover is square and shows the top of
  a taller image, the middle of a wider one. An illustration cover opens
  the detail pager over the row's illustrations in their order at the
  tap. A cover whose work is in the illustration store flies to the
  detail page and back (TRANS-09, its own scope per TRANS-07); one whose
  work is not opens with no flight and takes none back. While any page
  covers the row (opened from it or from anywhere, in the branch or on
  the root navigator over the shell) it keeps its order; once that page
  has left (its image landed) it takes the new order at once: each cover slides from
  where it was to its place on `MotionTokens.spatial`, one new to the row
  slides in from the leading edge and fades in, a new order mid-slide
  carries on from where each cover is, and reduced motion moves them at
  once. Hidden (another tab) the row takes the new order when it shows.
  "Covered" is read from the secondary animations of the row's route and
  of the shell's route, never from TickerMode: the Overlay stops tickers
  under any opaque page, so TickerMode cannot tell a page from a tab.
- **Why:** User decision: settings filled two thirds of the page in a
  style of their own, and nothing showed what the user saw last; then
  (10-21) the page read as unpolished next to mature apps, and YouTube's
  layout was chosen: a list over a grid, one settings entry at the end
  over a bar button. The flight needs the work's ratio on its first frame, and a
  history record has none. Each work the pager shows moves to the front
  of the history, so a row reordered mid-flight would land the image on
  another work's cover. Swapped in place at the landing, covers changed
  right where the eye was; waiting for the next visit left the row stale
  (user decision 10-20: catch up at the landing, with the slide). Read
  from TickerMode, a page not opened from the row (the profile, the
  history page) let the row reorder behind it, and the slide was over
  before the user came back. 10-25: the header, plain, did not show it
  opened the profile; it took the person card every author block uses
  (user decision).
- **Check:** `test/settings_test.dart` "the Me header, manage button and end rows open their pages" "signed out, the Me header is one button to the login" "the dashboard badge counts downloads as they start and end" "the recent row follows the history and pages in its own order" "a recent cover flies to its work and back, an unseen one not" "a page over the row holds its order until it has left"
- **Code:** `lib/features/settings/me_dashboard_page.dart`
