---
prefix: SET
applies_to:
  - lib/app/widgets/settings/**
  - lib/features/settings/**
reviewed: 2026-11-28
---

# Settings pages and the Me tab

## Contents

- [Rows and groups](#rows-and-groups)
- [Search and ownership](#search-and-ownership)
- [Me tab](#me-tab)

## Rows and groups

### SET-01 Rows sit in a unified SettingsGroup card, never Divider
- **Rule:** Settings rows go inside `SettingsGroup`, which wraps non-empty
  children inside one unified `SettingsCard` (`surfaceContainer` with
  `FuncShape.card` corners and a `1dp` `brandHairline` border) and separates
  adjacent active rows with an animated `1dp` inset `brandHairline`
  (`EdgeInsetsDirectional.only(start: FuncSpacing.lg)`), never a `Divider` and
  never a hand-built group container (`BottomBarSettingsPage`'s reorderable list
  still draws one `SettingsCard` per draggable item `SettingsGroup.rowGap`
  apart). A note on one row is that row's subtitle; a note on the whole group,
  or on content without a subtitle (a slider, a form), is the group `footer`.
  So is an empty group's line saying it is empty: never a card of its own.
  Notes on how to use a setting are not written (PAGE-20). On one page either
  every group has a title or none does. A leaving `Removable` row stops
  counting from the exit's first frame so its hairline closes smoothly.
  `SettingsChoiceTile` exposes the chosen option through `ListTile.selected`
  so screen readers announce selection without deprecated radios.
- **Why:** One inset grouped card with 1dp hairlines keeps settings and the Me
  dashboard calm across desktop and mobile without stacked thick card slabs.
  Notes set apart from their row and a page with one titled group read as
  unrelated. An empty group's note on a card read as a row to press.
- **Check:** `test/architecture/ui_conventions_test.dart` "SettingsSection is gone from lib/"; `test/muted_items_page_test.dart` "an empty group says it is empty, off the cards"; `test/settings_test.dart` "SettingsChoiceTile exposes ListTile.selected semantics to screen readers"
- **Code:** `lib/app/widgets/settings/settings_group.dart`, `lib/app/widgets/settings/settings_choice_tile.dart`

### SET-08 Page entries use monochrome icons without color discs
- **Rule:** A row that opens a settings page from the index (`SettingsTile.topLevel`)
  or a section from the Me dashboard renders a bare 22dp monochrome `AppIcons`
  leading icon (`selected ? (selectedIcon ?? icon) : icon`, THEME-07, THEME-16)
  with no colored circular backdrop. Library rows carry optional live
  `trailingText` tabular counts ahead of the chevron instead of placeholder
  double-line subtitles; `MeDashboardPage` and `ShellRail` share
  `downloadStatsProvider` to surface muted tonal active/failed download counts
  (no warning red) and failed counts in `MeDashboardPage` `trailingText`. Selected `SettingsTile`s step their overlay alpha
  across default/focused (0.12), hovered (0.16) and pressed (0.20), and
  `AccountSettingsPage` keeps the selected account's ID subtitle on
  `onSurfaceVariant`.
- **Why:** Multi-hue 40dp icon discs made Settings and Me read like noisy rainbow
  lists and clashed with monochrome workspace navigation; bare 22dp glyphs with
  `*Filled` selection states and trailing counts align hierarchy across mobile
  and desktop without decorative color.
- **Check:** `test/architecture/ui_conventions_test.dart` "a filled icon with an outlined twin marks a state", `test/settings_test.dart` "account rows never show the email; each shows its own ID"
- **Code:** `lib/app/widgets/settings/settings_tile.dart`, `lib/features/settings/settings_page.dart`, `lib/features/settings/me_dashboard_page.dart`, `lib/features/settings/pages/account_settings_page.dart`

### SET-09 A form is one card with its save at the end
- **Rule:** A form's fields and its `FilledButton` save sit in one
  `SettingsGroupContent` card, the save at the card's bottom end. Clearing an
  optional override field (such as a custom download album name) saves back to
  default, and reset/clear actions sit as `SettingsActionTile` rows in a group
  under the form. "Optional" is a field's helper text, never part of its label.
- **Why:** User decision: loose fields and buttons on the page surface
  did not read as one form. A long label was cut at narrow widths.
- **Check:** `test/translation_credentials_page_test.dart` "typing while the store reads or writes stays a draft" "a dirty draft asks before leaving, a clean one pops"; `test/download_settings_page_test.dart` "DownloadDestinationPage clears album to default, offers reset row, and exposes copy button & right-click menu"
- **Code:** `lib/features/settings/pages/translation_credentials_page.dart`, `lib/features/settings/pages/download_destination_page.dart`, `lib/features/settings/network_settings_page.dart`

### SET-03 Hand-written ListTiles only for content rows
- **Rule:** A hand-written `ListTile` is allowed only for data entries
  (muted items, accounts, diagnostic results). Adding one extends the
  architecture test's per-file whitelist with a reason.
- **Why:** Hand-built settings rows drifted from the shared look and
  haptics.
- **Check:** `test/architecture/ui_conventions_test.dart` "hand-written ListTile rows match the design whitelist"
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
- **Check:** `test/settings_search_test.dart` "title hits come before option hits, case and spaces ignored" "a result opens its page with the setting revealed and marked; back returns to the search"
- **Code:** `lib/features/settings/settings_catalog.dart`, `lib/app/widgets/settings/settings_anchor.dart`

### SET-06 Each setting has one home page and master-detail layout on wide workspaces
- **Rule:** `/settings/motion` holds animation speed, reduced motion, press
  feedback and haptic strength (shown on Android and on iOS devices where
  `hapticsCapabilityProvider` reports `tier != HapticsTier.none`; `Setting.hapticStrength.available`
  is true on both Android and iOS, while `followSystemColors` and
  `saveLocationSafFolder` are hidden on iOS in both `Setting.available` and
  their respective pages). Credential
  export is in account management. History switches and delete-all are in the
  history page's overflow menu; there is no history settings page. The interface
  form (NAV-20) heads `/settings/navigation` and, like haptic strength, exists
  only where `Setting.available` says so: the row and its search entry alike.
  When `MasterDetailWorkspace.canDisplay` holds (`HomeShellChrome.contentSizeOf`
  `>= 840x480` and `viewport.width >= viewport.height * 0.75`), `/settings/all`
  and leaf settings routes wrapped in `SettingsAdaptiveHost` stay inside
  `MasterDetailWorkspace`: a 280dp `surfaceContainerLow` index pane (`52dp` top
  header with `1dp` `brandHairline`, `showChevron: false` rows, and vertical
  `ScrollEdgeFade(axis: Axis.vertical, fadeExtent: FuncSpacing.lg)` over
  `masterBody`) and a `1dp`
  `brandHairline`-separated nested detail `Navigator` (`SettingsDetailScope`,
  `EmbeddedHeaderScope` flat aligned `52dp` headers,
  `MotionTokens.stateFadeCurve` with leaving `IgnorePointer`, and
  `settingsNarrowBody` left-aligned up to 780dp wrapped in vertical
  `ScrollEdgeFade(axis: Axis.vertical, fadeExtent: FuncSpacing.lg)`); secondary leaf paths
  (`/settings/about/licenses`, `/settings/network/advanced`,
  `/settings/navigation/bottom-bar`, `/settings/translate/credentials`) map to
  their parent category and scroll the active rail entry into view.
  `SettingsDetailScope` carries a `SettingsDraftRegistry` so any embedded
  `guardDraft` form prompts via `confirmDiscardDraft` on both left-rail
  category switches and outer pops (`settingsMasterPopScope`).
- **Why:** The same setting on two pages drifted apart; hardwareless iPads omit
  dead haptic sliders while Taptic iPhones expose them (and iOS omits Android
  Material You system colors and SAF pickers); and unified `280dp`
  master-detail hosting keeps deep-linked settings pages coherent beside the
  collapsed shell rail without double headers, orphaned single-column sheets,
  or silently discarded form drafts on category switch or outer back.
- **Check:** `test/settings_search_test.dart` "every catalog entry is on its page" "Setting.available and ThemeSettingsPage adapt haptics and system colors on iOS"; `test/settings_master_detail_test.dart` "wide desktop uses master-detail with nested navigation; below 840dp stays single column" "wide settings prompts confirmDiscardDraft on category switch and outer pop for dirty root and child forms"
- **Code:** `lib/app/widgets/master_detail_workspace.dart`, `lib/app/navigation/route_branches.dart`, `lib/features/settings/settings_catalog.dart`, `lib/features/settings/settings_page.dart`, `lib/features/settings/settings_helpers.dart`, `lib/features/settings/pages/motion_settings_page.dart`, `lib/features/settings/pages/theme_settings_page.dart`, `lib/features/settings/pages/download_destination_page.dart`

## Me tab

### SET-07 Narrow Me tab puts account, history strip, and monochrome library rows before settings
- **Rule:** On narrow layouts (`!MasterDetailWorkspace.canDisplay`), the Me root
  shows an `AppIcons.settings` shortcut (`settingsTitle` tooltip) in
  `AppTopBar.actions` (omitted when `DesktopCommandBarScope` owns chrome)
  while keeping the bottom `设置` row (`SET-08`). First comes the atmospheric
  account header (a `FuncShape.panel` card on `surfaceContainer` layered with
  an `AmbientWash` backdrop tinted from the user's cover/work image at
  `decodeWidth: 96`, containing `PersonCard` at 52dp avatar, name with neutral
  "Premium" pill, user ID, and trailing manage icon button — or one sign-in
  button when signed out — plus a `brandHairline`-separated 3-column
  interactive `收藏 / 关注 / 好P友` stat row once `userDetail` loads). Next
  comes the last eight history records as a row of square covers (or an
  empty-history `暂无浏览历史` entry card without a `"see all"` button when
  empty), followed by monochrome grouped `SettingsGroup` /
  `SettingsTile.topLevel` sections (`showChevron: true`, 22dp `AppIcons`,
  `SET-08`, live `trailingText` counts when non-zero, `Badge` on downloads,
  subtitle on `设置` / `关于`). Illustration covers open the detail pager in row
  order and fly via Hero (`'me-history'`, TRANS-07) when in `IllustStore`;
  `HistoryVisibility` settled-route gating plus root-to-leaf `Navigator`
  secondary-animation checks hold row order while covered and slide on
  `MotionTokens.spatial` once uncovered (unclipped `FuncSpacing.xs` lift
  headroom, symmetric `Curves.easeInOutCubic`, horizontal `ScrollEdgeFade`).
- **Why:** User decision: settings filled two thirds of the page in a style of
  their own; monochrome grouped rows clarify mobile hierarchy, and holding
  history order while covered keeps Hero return flights aimed at the right
  cover before sliding.
- **Check:** `test/settings_test.dart` "signed out, the Me header is one button to the login" "the dashboard badge counts downloads as they start and end"
- **Code:** `lib/app/widgets/scroll_edge_fade.dart`, `lib/app/widgets/settings/settings_group.dart`, `lib/app/widgets/settings/settings_tile.dart`, `lib/core/history/history_visibility.dart`, `lib/features/settings/me_dashboard_page.dart`

### SET-11 Wide Me tab opens directly into a 280dp MasterDetailWorkspace
- **Rule:** When `MasterDetailWorkspace.canDisplay` holds (`>= 840x480`
  content), the Me tab mounts `MasterDetailWorkspace` (`masterBody` scrolled
  with vertical `ScrollEdgeFade`) wrapping its nested detail `Navigator` in
  `SettingsDetailScope`: a `280dp` left rail (a compact 40dp account header
  card opening the signed-in user's profile or login with an inline
  `AppIcons.accountManage` button, plus grouped `showChevron: false` monochrome
  single-entry destination items with live `trailingText` counts and `*Filled`
  selected states `heartFilled` / `watchLaterFilled`, including `HistoryPage`
  under data and settings/about on touch tablets without
  `DesktopCommandBarScope`) that opens directly onto the bookmarks pane (`收藏`)
  on touch tablets — or onto `关注` under `DesktopCommandBarScope`, omitting
  the `收藏` and `下载` rows already owned by the adjacent desktop `ShellRail` —
  without duplicating profile cards, library metric cards, or history strips in
  a separate overview pane. Bookmarks and following panes defer network-backed
  filters and feeds until the Me tab's network scope is active, and the detail
  `Navigator` reports `NavigationNotification` to an outer
  `PopScope(canPop: !_detailCanHandlePop)` so `Esc`/back exits management modes
  inside detail pages before leaving the Me tab.
- **Why:** Removes the redundant overview studio in wide 2-column workspaces so
  every library section opens in one click inside the shared 280dp
  `MasterDetailWorkspace` / `SettingsDetailScope` pattern and back exits inner
  selection modes before popping Me.
- **Check:** `test/settings_master_detail_test.dart` "wide Me dashboard forwards back to exit WatchLater managing mode before popping Me" "offstage Me dashboard defers profile and bookmark requests until visible"
- **Code:** `lib/app/widgets/master_detail_workspace.dart`, `lib/app/widgets/scroll_edge_fade.dart`, `lib/features/settings/me_dashboard_page.dart`
