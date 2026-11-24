---
prefix: NAV
applies_to:
  - lib/app/navigation/**
  - lib/app/layout/form_factor.dart
  - lib/app/window/**
  - lib/app/startup_gate.dart
  - lib/app/widgets/home_branch_stack.dart
  - lib/app/widgets/shell_rail.dart
  - lib/app/widgets/func_bottom_nav.dart
  - lib/app/widgets/app_tab_bar.dart
  - lib/app/widgets/app_top_bar.dart
  - lib/app/widgets/feed/desktop_gallery_controls.dart
  - lib/app/widgets/tab_swipe_switcher.dart
  - lib/app/widgets/replica_scaffold.dart
  - lib/app/motion/scroll_hide.dart
  - lib/app/touch_exploration_scope.dart
  - lib/features/home/**
  - lib/features/search/docked_search.dart
  - lib/features/search/search_input_engine.dart
  - lib/features/search/search_input_page.dart
  - lib/features/search/search_page.dart
  - lib/features/illust/detail/illust_detail_page.dart
  - lib/features/illust/detail/widgets/detail_overlay_frame.dart
reviewed: 2026-11-23
---

# Navigation, shell and tabs

## Contents

- [Routes and stacks](#routes-and-stacks)
- [Bottom bar](#bottom-bar)
- [Branch switching and re-tap](#branch-switching-and-re-tap)
- [Top bars, tabs and choices](#top-bars-tabs-and-choices)
- [Wide windows](#wide-windows)

## Routes and stacks

### NAV-01 Navigate through the typed route facade
- **Rule:** Pages navigate via typed helpers in `route_facade.dart` / `routes.dart` using durable path/query parameters; `extra` carries only optional first-frame snapshots and pages must render without it.
- **Why:** Untyped `extra` routes broke state restoration and deep links.
- **Check:** `test/navigation_restoration_test.dart` "restores the active search branch and its nested route" "viewer page replacement survives route restoration"
- **Code:** `lib/app/navigation/routes.dart`, `lib/app/navigation/route_facade.dart`

### NAV-02 The router instance never rebuilds
- **Rule:** Settings, account, and provider updates never recreate `GoRouter`; restoration scope IDs, `PageStorageKey`s, and `restorationId`s stay stable.
- **Why:** Recreating the router discards every branch stack and restoration state.
- **Check:** manual — the app creates its router once in state
- **Code:** `lib/app/app.dart`, `lib/app/navigation/routes.dart`

### NAV-03 Back at a branch root returns to the start page, which confirms
- **Rule:** Back at any non-start branch root switches to `homeBackDestination` (live choice, or run-opening destination for "last used"). At the start root on Android, back shows `homeExitHint` and arms `homeExitWindow` (2 s) for a second-back exit (cleared on push, overlay, branch switch, or backgrounding); other platforms defer to the OS.
- **Why:** User decision: keeps double-back exit predictable without stale hints or surprise exits.
- **Check:** `test/navigation_router_test.dart` "a rearranged bar starts, goes back and reaches hidden pages" "a second back at the start exits"; `test/home_destination_test.dart` "back lands on the start page, the one used last where a run opened"
- **Code:** `lib/features/home/home_page.dart`

### NAV-04 Content opens on the current stack
- **Rule:** Content pushes stay on the active branch stack (guarded by a debug assertion rejecting cross-branch pushes); only the bottom bar/rail switches branches. Overlay routes (`/me`, `/reverse-image`, `/downloads`) open anywhere; beside a rail, `/me` and `/downloads` push on the current stack except from the viewer (NAV-20), and "back to work" pops the viewer instead of pushing a duplicate detail page.
- **Why:** Cross-branch pushes switched tabs unexpectedly and stacked duplicate pages.
- **Check:** `test/navigation_router_test.dart` "branch pushes are rejected outside the visible branch" "tag search stays on the stack it was opened from"
- **Code:** `lib/app/navigation/routes.dart`, `lib/app/navigation/route_facade.dart`

### NAV-05 A page that can be alone on the stack has an up location
- **Rule:** Pages reachable via deep link or startup redirect pass `ReplicaScaffold(upLocation:)` so back with an empty stack navigates there instead of exiting.
- **Why:** Deep-linked pages otherwise exited the app on back.
- **Check:** manual
- **Code:** `lib/app/widgets/replica_scaffold.dart`

### NAV-06 Search swaps routes instead of stacking them
- **Rule:** Full search input and results swap via `pushReplacement`; wide docked panels close first before pushing/replacing results (NAV-25); `context.replace` is reserved for in-page query updates (tab/type).
- **Why:** Prevents back from walking through every prior search query.
- **Check:** `test/navigation_router_test.dart` "search input and results stay on the requesting stack"; `test/docked_search_test.dart` "a wide header docks the input under the field" "editing the query on a wide result bar replaces the results"
- **Code:** `lib/app/navigation/routes.dart`, `lib/features/search/search_result_page.dart`, `lib/features/search/docked_search.dart`

### NAV-23 The startup gate rescues only an auth stack
- **Rule:** When signed in, `StartupGate` routes home only when both the top path and base configuration URI (`routerDelegate.currentConfiguration.uri`) are login/welcome/splash. Add-account login pushed over an app page stays and pops on success (including WebView, clipboard import, and external OAuth callback via top-level `/login/callback`, which replaces an active `/login` or `/login/callback` instead of stacking); cold-start shares over splash stay until back returns to splash. The gate listens to `routerDelegate` post-frame as well.
- **Why:** Prevented token refreshes from aborting add-account OAuth or dismissing cold-start shared images, and stopped repeated OAuth callbacks from stacking multiple login pages.
- **Check:** `test/startup_gate_test.dart` "add account survives the gate rebuilding under it" "an image shared into a cold start stays open until back"; `test/login_page_test.dart` "add-account clipboard import pops login and queues clipboard-replaced toast without dropping success toast" "external OAuth callback shows busy spinner, replaces /login without stacking, and pops back on add-account"
- **Code:** `lib/app/startup_gate.dart`, `lib/features/login/login_page.dart`, `lib/app/navigation/routes.dart`

## Bottom bar

### NAV-07 The bottom bar is the Shaft-style bar
- **Rule:** `FuncBottomNav` is a custom 56dp bar (never M3 `NavigationBar`): tint-only selection (`primary` + heavier weight on `effectsFast`), casting `barShadow` with a continuous 1dp top `brandHairline` (`THEME-18`), labels sharing one `LabelFit` capped at 1.3x text scale. From 600dp wide (landscape phones, NAV-20), items sit centered with icon beside label (falling back to stacked cells when labels won't fit at `LabelFit.minScale`).
- **Why:** User decisions: Shaft-style indicator-free bar, clean hairline+shadow separation, and centered side-by-side layout on wide phones.
- **Check:** `test/locale_layout/compact_controls_test.dart` "a turned phone's bottom bar keeps every label whole"; `test/func_bottom_nav_test.dart` "a wide bar puts each icon beside its label, centred"
- **Code:** `lib/app/widgets/func_bottom_nav.dart`

### NAV-08 Bar geometry is published, never measured
- **Rule:** Resting bar height comes from `HomeShellChrome`; live covered height comes from `HomeShellChrome.bottomBarVisibleExtent.value` without rebuilding or post-layout measurement.
- **Why:** Post-layout measurement delayed Hero landing clips and spacers by a frame.
- **Check:** `test/func_bottom_nav_test.dart` "the bar follows a drag and settles at the nearer end"
- **Code:** `lib/app/navigation/home_shell_metrics.dart`

### NAV-09 The bar follows the user's own scrolling
- **Rule:** Both `FuncBottomNav` and `DetailActionBar` move 1:1 with user scrolls on the current root page (settling to the nearer end after drags, or the scroll direction after wheel ticks), ignoring programmatic scrolls, overscroll, and horizontal strips; branch switches restore the bar.
- **Why:** User decision (M3 `exitAlways` feel) without edge-bounce or programmatic-scroll flicker.
- **Check:** `test/func_bottom_nav_test.dart` "edge bounce never toggles the bar" "the bar follows a drag and settles at the nearer end" "a wheel tick settles the way it went; other scrolls do not", `test/illust_detail_actions_test.dart` "the action bar follows a drag and settles at the nearer end"
- **Code:** `lib/app/motion/scroll_hide.dart`

### NAV-10 Pushed pages cover the bar
- **Rule:** While a branch root is covered by a pushed route or an exiting transition (`ExitAwareRouteObserver` tracking popup exits in `didPopNext`), the real bar goes `Offstage` and the root draws an inert copy in place so both overlap seamlessly at push start and pop completion.
- **Why:** Prevented the bottom bar from floating over pushed pages or closing sheets.
- **Check:** `test/navigation_router_test.dart` "a pushed branch route covers the bar and hands it back" "keeps the bar under it until it has left" "a page pushed while a sheet leaves keeps the bar covered"
- **Code:** `lib/app/widgets/func_bottom_nav.dart`, `lib/app/navigation/home_shell_metrics.dart`, `lib/core/navigation/route_observer.dart`

### NAV-11 The bar does not hide under touch exploration
- **Rule:** Scrolling never hides the bar while touch exploration is active (and enabling it restores a hidden bar); widgets read `MediaQuery.accessibleNavigationOf` as rewritten by `TouchExplorationScope`.
- **Why:** Flutter's raw engine flag is true whenever any accessibility service runs, not only TalkBack.
- **Check:** `test/home_branch_stack_test.dart` "a polluted engine flag does not pin the bar" "starting touch exploration brings a hidden bar back"
- **Code:** `lib/app/touch_exploration_scope.dart`, `lib/app/widgets/home_branch_stack.dart`

### NAV-19 The user arranges the bar; branches keep their numbers
- **Rule:** Bar and rail follow `homeArrangementProvider` (Me stays, >= 2 items remain) while branch indices and routes never renumber; off-bar pages open from Me (and Recommended shows a search action when Search is hidden). `/` lands on `homeStartDestination` (persisting "last used" only on app hide).
- **Why:** User request; renumbering broke restoration and per-switch writes rebuilt the app root.
- **Check:** `test/navigation_router_test.dart` "a rearranged bar starts, goes back and reaches hidden pages" "the bar editor hides, keeps two and restores"; `test/home_destination_test.dart` "a saved bar keeps Me and two destinations whatever it says" "back lands on the start page, the one used last where a run opened"
- **Code:** `lib/core/navigation/home_destination.dart`, `lib/app/widgets/home_branch_stack.dart`, `lib/features/settings/pages/bottom_bar_settings_page.dart`

## Branch switching and re-tap

### NAV-12 Branches slide under a tap or a swipe; the shell chrome stays still
- **Rule:** On bottom-bar shells, taps slide branches side-by-side (300 ms `branchSwitchCurve`, freezing the outgoing branch; rail/pointer shells use the 150 ms fade + 12dp short slide of `MOTION-23`, cut under reduced motion). On phones, root-page horizontal swipes drag adjacent bar branches (`SwipePaging`, MOTION-20, non-wrapping; tabs yield only at ends via `SwipePagerScope`; disabled when covered, on rails, or under touch exploration). Never wrap the whole `StatefulNavigationShell` in a transition.
- **Why:** User decisions; wrapping the shell flashed white and swiping under leaving routes hid the bar.
- **Check:** `test/home_branch_stack_test.dart` "a bar tap slides the new branch in from its side" "the incoming branch stays live while the outgoing one freezes" "takes over from the tabs at their last one" "a page without tabs pages at once; the end of the bar bounces" "keeps its destination"
- **Code:** `lib/app/widgets/home_branch_stack.dart`, `lib/app/motion/swipe_paging.dart`

### NAV-13 Re-tapping a destination is an edge event
- **Rule:** Active-destination re-tap pops its stack to root and emits once on `ReTapChannel` (`ChangeNotifier`, never `ValueNotifier`); consumers scroll post-frame via `reTapScrollToTop` or trigger `PullToRefresh.trigger` when already at top.
- **Why:** `ValueNotifier` dropped repeat taps and pre-pop scrolls targeted covered pages.
- **Check:** `test/home_branch_stack_test.dart` "a same-destination tap emits one event per tap" "a re-tap pops the branch stack back to its root"
- **Code:** `lib/app/widgets/home_branch_stack.dart`, `lib/app/pull_to_refresh.dart`

## Top bars, tabs and choices

### NAV-14 Top tabs are AppTabBar and never shrink
- **Rule:** Every tab row uses `AppTabBar` at themed text size (measured in `TabBar`'s painted style, LAYOUT-04): equal shares when all fit (`>= 600dp` caps slots at `maxEqualSlotWidth ?? 120dp`, `76dp` on wide profiles, or the widest label plus padding when wider; start-aligned; `tabsBesideTitle` always caps); otherwise scrollable with 48dp `ScrollEdgeFade(initialAfter: true)`, compact `FuncSpacing.sm` padding under 420dp, and vertical mouse-wheel horizontal scrolling via an owned `TabBarScrollController`.
- **Why:** Shrunk labels broke long locales, uncapped wide shares spread tabs across 1300dp, and desktop users could not wheel-scroll overflowing tab strips.
- **Check:** `test/app_tab_bar_test.dart` "a wide row keeps its tabs together at the start" "labels that do not fit scroll from the start at 14sp" "overflowing AppTabBar scrolls horizontally on vertical mouse wheel"
- **Code:** `lib/app/widgets/app_tab_bar.dart`

### NAV-15 A tab tap never calls animateTo again
- **Rule:** `TabBar` animates taps itself; `onTap` never calls `animateTo` for the tapped index.
- **Why:** Double animation reset indicators and stalled rapid taps.
- **Check:** manual
- **Code:** `lib/app/widgets/tab_swipe_switcher.dart`

### NAV-16 Announce the new tab's scroll position
- **Rule:** Call `announceTabScroll` from body context on tab switch (and in `onAttach` for lazy lists); never nudge scroll position (`didUpdateScrollPositionBy(0)`).
- **Why:** Kept top-bar scroll shadow accurate without triggering spurious load-more requests.
- **Check:** manual
- **Code:** `lib/app/widgets/tab_swipe_switcher.dart`

### NAV-17 No segmented buttons
- **Rule:** Use `AppTabBar` (peer views), `SettingsMenuTile` (2–4 options), `SettingsGroup` of `SettingsChoiceTile` (5+ options), `SettingsControl` (booleans), individual buttons (actions), or `FilterMenuButton` / `DesktopGalleryControls` (list/gallery filters)—never segmented buttons.
- **Why:** User decision: segmented pill bars are removed app-wide.
- **Check:** `test/architecture/ui_conventions_test.dart` "no segmented buttons"
- **Code:** `lib/app/widgets/filter_menu_button.dart`, `lib/app/widgets/feed/desktop_gallery_controls.dart`

### NAV-18 Page top bars are AppTopBar
- **Rule:** All page headers use `AppTopBar` (leading-aligned titles, `ScrollEdgeShadow` on scroll). Under `DesktopCommandBarScope` or `EmbeddedHeaderScope`, non-immersed bars lay out at exact 52dp (`kDesktopPageHeaderHeight`, no extra wrapper inflating height to 56dp) with a 1dp `brandHairline` bottom edge and omit redundant implicit `BackButton`s (keeping explicit `up` paths).
- **Why:** Unifies bar shadows, removes the 4dp gap below flat headers, and avoids duplicate desktop back arrows beside `DesktopCommandBar`.
- **Check:** `test/architecture/ui_conventions_test.dart` "page top bars are AppTopBar"; `test/app_tab_bar_test.dart` "a top bar with tabs casts its shadow once content scrolls under it"; `test/desktop_command_bar_test.dart` "DesktopCommandBar chrome, drag regions, header deduplication, and popovers" "flat AppTopBar occupies exact 52dp, narrow command bar preserves 48dp drag space, and Account settings re-targets wide SettingsPage"
- **Code:** `lib/app/widgets/app_top_bar.dart`, `lib/app/widgets/replica_scaffold.dart`, `lib/app/widgets/master_detail_workspace.dart`

## Wide windows

### NAV-20 Three forms: a phone's bar, a touch rail, a PC rail
- **Rule:** `FormFactorScope` resolves phone (`AppBreakpoints.isPhoneDisplay` -> always `FuncBottomNav` with `AppIcons.newWorks`), `touch` tablet, or `pc` desktop (`>= 600dp` mounts `ShellRail`: 74dp collapsed fitting all four locales, 204dp expanded; primary nav labels and bottom theme label use separate `LabelFit` groups so theme cycling never shifts nav label scale). On `FormFactor.pc`, `ShellRail` stays permanently expanded at 204dp whenever `hasRail` holds (`>= 600dp`) with no collapse toggle (`canToggleRail == false`); large touch screens (`>= 840x480`) keep the manual collapse/expand toggle and auto-collapse to 74dp on Me/Settings. Under `DesktopCommandBarScope`, the rail hosts mutually exclusive `我的` (`/settings`), `收藏` (`/settings/me?tab=bookmarks`), `下载` (`/settings/downloads`), and `设置` (`/settings/all`) navigation (pressing Back from `收藏`/`下载`/`设置` returns to the originating branch when entered from branches 0..3 without pushing a stale `'settings'` forward entry, while explicit branch selection via shortcuts/menus/rail clears the pending return branch atomically through `ForwardHistoryStack.selectHomeDestination`) plus a 3-state theme cycle (`light -> dark -> system -> light`). `HomeBranchStack` paints `HomeRailModalScrim` over `ShellRail` behind bounded `DetailOverlayFrame`s without breaking `HeroController`. Immersive routes hide the rail post-frame.
- **Why:** Keeps desktop navigation predictable without duplicate chrome, rail collapse jumps, theme-cycle label jitter, or Me/Bookmarks/Downloads/Settings loops while preserving compact rail density on tablets.
- **Check:** `test/home_branch_stack_test.dart` "a turned phone keeps the bottom bar" "a short window on a tablet gets a scrolling icon rail" "a PC rail stays expanded across rail widths without a collapse" "a toggleable tablet rail opens and closes by width rather than in one frame" "with reduced motion a toggleable rail changes width at once" "the interface form changes the shell at once and keeps the" "beside the rail, the downloads and the profile open in the" "ShellRail dims behind bounded DetailOverlayFrame and dismisses on tap" "tablet landscape auto-collapses expanded ShellRail on Me and Settings" "desktop rail cycles 3-state theme and keeps Me, Bookmarks, Downloads, and Settings mutually exclusive"; `test/locale_layout/compact_controls_test.dart` "compact ShellRail keeps every label untruncated across locales"; `test/novel_reader_stage_test.dart` "the current reader hides the shell rail, under its panels"; `test/layout_breakpoints_test.dart` "a phone, a touch screen or a PC, by display and platform"
- **Code:** `lib/app/layout/form_factor.dart`, `lib/app/navigation/desktop_rail_route.dart`, `lib/app/widgets/func_bottom_nav.dart`, `lib/app/widgets/shell_rail.dart`, `lib/app/widgets/home_branch_stack.dart`, `lib/app/navigation/home_shell_metrics.dart`, `lib/features/illust/detail/widgets/detail_overlay_frame.dart`

### NAV-24 A wide destination bar: tabs, actions, then search
- **Rule:** When `PageHeader.isWide` holds (rail active), destination roots render one toolbar row: leading `AppTabBar`, page actions, then `HeaderSearch` (360dp `SearchFieldButton` at `>= 840dp` content, icon otherwise; hidden outside `BranchRootScope`; hides Recommended's off-bar search icon; Me keeps title alone). Result bars split type tabs, filter button, and 360dp/240dp query field with active filters below.
- **Why:** Unifies wide destination headers and search placement across tabs.
- **Check:** `test/navigation_router_test.dart` "a destination bar ends in the search field" "ranking and new bars end in the search field" "a page pushed over a destination root has no search entry" "the off-bar search entry still reaches search"; `test/search_catalog_test.dart` "the guide camera opens reverse image search; the novel tab"; `test/search_result_page_test.dart` "wide result bar splits kinds, query, filters"
- **Code:** `lib/app/widgets/page_header.dart`, `lib/features/home/recommended/recommended_home_page.dart`, `lib/features/new/new_page.dart`, `lib/features/ranking/ranking_tabs.dart`, `lib/features/search/search_page.dart`, `lib/features/search/search_result_page.dart`

### NAV-25 A wide shell docks the search input under its trigger
- **Rule:** With a rail active (never on phones), `HeaderSearch` and result query fields open `SearchInputEngine` in a docked `showAppPanel` anchored under `PageHeader.anchorOf` (`>= 360dp`, re-anchoring on resize, closing before opening shortcuts/results, `Esc` leaving focus then closing). Editing a query from search results or the desktop command bar carries active session filters (`initialIllustFilters` / `initialNovelFilters`) into both `DockedSearchPanel` and `SearchInputPage`. Narrowing below the rail closes the panel (and any open filter sheet) and hands raw text + filter drafts to the full input page.
- **Why:** Keeps desktop browsing context visible during search without losing drafts or session filters across edits and resizes.
- **Check:** `test/docked_search_test.dart` "a wide header docks the input under the field" "editing the query on a wide result bar replaces the results" "Esc leaves the field first, a second Esc closes the panel" "the scrim and the system back close the panel" "a resize re-anchors the panel under the entry" "narrowing carries the draft to the full page" "narrowing keeps the typed text and the filter drafts" "narrowing with the filter sheet open closes both layers" "a shortcut closes the panel before the page it names" "the panel and its fade are marked as scenes" "a phone keeps the full input page" "the panel offers history, kinds and filters"; `test/search_result_page_test.dart` "editing search query preserves session filters in both wide docked and narrow flows"
- **Code:** `lib/features/search/docked_search.dart`, `lib/features/search/search_input_engine.dart`, `lib/app/widgets/page_header.dart`, `lib/app/navigation/routes.dart`

### NAV-21 A resize keeps every branch, its stack and its place
- **Rule:** Resizing/folding reparents branch Navigators via stable `GlobalKey`s (preserving stacks and scroll offsets), preserves the on-screen image index across single-column <-> two-pane detail transitions (measured from laid-out pages), and anchors `DetailOverlayFrame` with a persistent `GlobalKey` across the 960x600 threshold.
- **Why:** Prevents losing navigation stacks or reading position when resizing windows or folding devices.
- **Check:** `test/home_branch_stack_test.dart` "a resize keeps every branch, its stack and its scroll"; `test/illust_detail_actions_test.dart` "arrow keys page the image pane; a resize keeps the page" "a switch between the single column and two panes keeps the image, read from the screen"
- **Code:** `lib/app/widgets/home_branch_stack.dart`, `lib/features/illust/detail/illust_detail_page.dart`, `lib/features/illust/detail/illust_detail_scroll.dart`, `lib/features/illust/detail/illust_detail_shells.dart`, `lib/features/illust/detail/widgets/detail_overlay_frame.dart`

### NAV-22 Esc goes back
- **Rule:** `KeyboardBack` maps `Esc` to the router's `popRoute` (unfocusing text fields first; no-op at the start root), using a dedicated intent because page routes disable `DismissIntent`.
- **Why:** Gives keyboard users parity with system back.
- **Check:** `test/home_branch_stack_test.dart` "Esc goes back as the system back does, short of leaving"
- **Code:** `lib/app/navigation/keyboard_back.dart`, `lib/app/app.dart`

### NAV-26 Desktop command bar, macOS menu bar and per-branch forward history
- **Rule:** On desktop `FormFactor.pc` (`InterfaceForm.touch` hides it), `AppChrome` mounts `DesktopCommandBar` inside `Overlay.wrap` (48dp custom titlebar on Windows/macOS with 2px resize borders for Win11 Snap and a 3dp non-corner Windows right resize rim so vertical scrollbars stay unobstructed; compact 40dp toolbar without duplicate brand/drag spacers when `usesSystemTitleBar` is true on Linux), deactivating `DesktopCommandBarScope` on pre-home routes (`/splash`, `/user-agreement`, `/welcome/*`, `/login/*`) so pushed onboarding/login pages retain visible in-page back buttons, progressively hiding shortcut badge (`< 680dp`), wordmark (`< 600dp`), and search pill (`< 500dp`) while reserving `>= 48dp` combined drag space whenever `!usesSystemTitleBar`, routing Account settings to `/settings/account` (and calling `syncSettingsDetail` when already on `/settings/account` so wide `SettingsPage` re-selects Account), isolating route `ModalBarrier` `BlockSemantics` from the bar, and keeping a persistent router `GlobalKey` so hiding the bar on `ImageViewerPage` never remounts `HomePage`. Fallback window chrome omits disabled drag zones and yields to child controls; `DesktopWindowFrame` resets the fullscreen hover-reveal state whenever the fullscreen hover overlay is hidden; Linux `DesktopWindowFrame` keeps `F11` fullscreen toggle active even with `usesSystemTitleBar`; `DesktopWindowSession` ignores minimized/off-screen Win32 sentinel geometry (`<= -30000` or `< 200x100`) on capture/save. On macOS, `DesktopMenuBar` includes standard AppKit menu items (`About`, `Services`, `Hide`, `Hide Others`, `Show All`, `Bring All to Front`, `Quit`, plus `File -> Close` `Cmd+W`), restores the native `MainMenu.xib` `Edit` menu via `MacosDesktopWindowBridge.restoreEditMenu`, omits dead PC rail-toggle controls, maps Navigate `Cmd+1..5` to `homeArrangementProvider.shown`, and guards nav/search/refresh/preferences shortcuts against open modals/root overlays and active text editing. `ForwardHistoryStack` syncs live `homeBackDestination` from `HomePage` so desktop Back stays enabled on non-start branch roots (`NAV-03`), tracks per-branch forward history and open modals by navigator bucket (so offstage branch modals never lock active-branch forward history or shortcuts), and routes `KeyboardBack` `Ctrl/Cmd+1..5` through `selectHomeDestination` on `homeArrangementProvider.shown`; Windows `WM_APPCOMMAND` filters `FAPPCOMMAND_MOUSE` while `KeyboardBack` tracks held mouse side buttons and 120 ms release debounce so held clicks never double-navigate.
- **Why:** Delivers unified desktop navigation, tooltips, accessibility, complete native macOS menus, unobstructed scrollbars, resilient window geometry, and browser-grade history without double chrome.
- **Check:** `test/desktop_command_bar_test.dart` "DesktopCommandBar chrome, drag regions, header deduplication, and popovers" "DesktopCommandBar compacts to 40dp toolbar without duplicate branding when usesSystemTitleBar is true" "AppChrome hides DesktopCommandBar for touch form, provides Tooltip Overlay, and ShellRail keeps shortcuts" "DesktopMenuBar restricts to macOS and wires View, Navigation, Bookmarks, Downloads, and Search" "ForwardHistoryStack replays per-branch forward entries and debounces mouse back/forward" "AppChrome isolates Router BlockSemantics so DesktopCommandBar remains reachable in semantics" "wide AppChrome keeps HomePage element and state mounted across ImageViewerPage push and pop" "context menus open on the root navigator and offstage branch modals do not lock active branch forward history" "flat AppTopBar occupies exact 52dp, narrow command bar preserves 48dp drag space, and Account settings re-targets wide SettingsPage"; `test/desktop_window_test.dart` "saveNow still persists size and maximized when getPosition throws" "macOS reserves traffic lights with zero custom buttons, Linux suppresses duplicate chrome" "DesktopFallbackWindowChrome omits dragZone when disabled and yields to child buttons on macOS" "exiting fullscreen via hover overlay resets _hoverReveal before next fullscreen"; `test/input_modality_shortcuts_test.dart` "KeyboardBack handles Ctrl/Cmd settings, destination digits, rail toggle, and iOS Cmd" "mouse side button held past 120ms suppresses duplicate channel back while held and on release"
- **Code:** `lib/app/app.dart`, `lib/app/window/desktop_command_bar.dart`, `lib/app/window/desktop_menu_bar.dart`, `lib/app/window/desktop_title_bar.dart`, `lib/app/window/desktop_window.dart`, `lib/core/platform/desktop_window_channel.dart`, `lib/app/navigation/forward_history.dart`, `lib/app/navigation/keyboard_back.dart`, `macos/Runner/MainFlutterWindow.swift`, `windows/runner/flutter_window.cpp`
