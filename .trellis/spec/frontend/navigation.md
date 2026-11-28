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
reviewed: 2026-11-28
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
- **Check:** `test/navigation_router_test.dart` "a rearranged bar starts, goes back and reaches hidden pages" "a second back at the start exits; interruptions reset the hint"; `test/home_destination_test.dart` "back lands on the start page, the one used last where a run opened"
- **Code:** `lib/features/home/home_page.dart`

### NAV-04 Content opens on the current stack
- **Rule:** Content pushes stay on the active branch stack (guarded by a debug assertion rejecting cross-branch pushes); only the bottom bar/rail switches branches. Overlay routes (`/me`, `/reverse-image`, `/downloads`) open anywhere; beside a rail, `/me` and `/downloads` push on the current stack except from the viewer (NAV-20), and "back to work" pops the viewer instead of pushing a duplicate detail page. On desktop `FormFactor.pc`, middle-clicking an unmuted artwork/novel/author/tag or choosing "Open in new tab" opens a detached secondary workspace `Navigator` tab beside the permanent root `StatefulNavigationShell` without recreating `GoRouter` (`NAV-02`) or disturbing feed scroll positions, while `Ctrl/Cmd+Click` remains exclusively reserved for `FEED-24` batch selection.
- **Why:** Cross-branch pushes switched tabs unexpectedly and stacked duplicate pages, while desktop users still need non-disruptive background tabs for multi-item browsing without breaking `GoRouter` or `FEED-24`.
- **Check:** `test/navigation_router_test.dart` "branch pushes are rejected outside the visible branch" "tag search stays on the stack it was opened from"; `test/e2e/desktop_workspace_e2e_test.dart` "Middle-click opens background tabs while preserving muted safety and Ctrl+Click batch selection"
- **Code:** `lib/app/navigation/routes.dart`, `lib/app/navigation/route_facade.dart`, `lib/app/window/desktop_workspace_tabs.dart`, `lib/app/widgets/middle_click_region.dart`

### NAV-05 A page that can be alone on the stack has an up location
- **Rule:** Pages reachable via deep link or startup redirect pass `ReplicaScaffold(upLocation:)` so back with an empty stack navigates there instead of exiting.
- **Why:** Deep-linked pages otherwise exited the app on back.
- **Check:** manual
- **Code:** `lib/app/widgets/replica_scaffold.dart`

### NAV-06 Search swaps routes instead of stacking them
- **Rule:** Full search input and results swap via `pushReplacement`; wide docked panels close first before pushing/replacing results (NAV-25); `context.replace` is reserved for in-page query updates (tab/type).
- **Why:** Prevents back from walking through every prior search query.
- **Check:** `test/navigation_router_test.dart` "search input and results stay on the requesting stack"; `test/search_input_test.dart` "submitting a search replaces input so back returns home"
- **Code:** `lib/app/navigation/routes.dart`, `lib/features/search/search_result_page.dart`, `lib/features/search/docked_search.dart`

### NAV-23 The startup gate rescues only an auth stack
- **Rule:** When signed in, `StartupGate` routes home only when both the top path and base configuration URI (`routerDelegate.currentConfiguration.uri`) are login/welcome/splash. Add-account login pushed over an app page stays and pops on success (including WebView, clipboard import, and external OAuth callback via top-level `/login/callback`, which replaces an active `/login` or `/login/callback` instead of stacking); cold-start shares over splash stay until back returns to splash. The gate listens to `routerDelegate` post-frame as well.
- **Why:** Prevented token refreshes from aborting add-account OAuth or dismissing cold-start shared images, and stopped repeated OAuth callbacks from stacking multiple login pages.
- **Check:** `test/startup_gate_test.dart` "add account survives the gate rebuilding under it" "an image shared into a cold start stays open until back"; `test/login_page_test.dart` "add-account clipboard import pops login and queues clipboard-replaced toast without dropping success toast" "external OAuth callback shows busy spinner, replaces /login without stacking, and pops back on add-account"; `tool/dev_workbench/catalog/os_e2e_flows.json` "os.oauth.callback_recovers_to_home" "os.oauth.callback_zero_errors"
- **Code:** `lib/app/startup_gate.dart`, `lib/features/login/login_page.dart`, `lib/app/navigation/routes.dart`

## Bottom bar

### NAV-10 Pushed pages cover the bar
- **Rule:** While a branch root is covered by a pushed route or an exiting transition (`ExitAwareRouteObserver` tracking popup exits in `didPopNext`), the real bar goes `Offstage` and the root draws an inert copy in place so both overlap seamlessly at push start and pop completion.
- **Why:** Prevented the bottom bar from floating over pushed pages or closing sheets.
- **Check:** `test/navigation_router_test.dart` "a pushed branch route covers the bar and hands it back"
- **Code:** `lib/app/widgets/func_bottom_nav.dart`, `lib/app/navigation/home_shell_metrics.dart`, `lib/core/navigation/route_observer.dart`

### NAV-11 The bar does not hide under touch exploration
- **Rule:** Scrolling never hides the bar while touch exploration is active (and enabling it restores a hidden bar); widgets read `MediaQuery.accessibleNavigationOf` as rewritten by `TouchExplorationScope`.
- **Why:** Flutter's raw engine flag is true whenever any accessibility service runs, not only TalkBack.
- **Check:** `test/home_branch_stack_test.dart` "a polluted engine flag does not pin the bar" "starting touch exploration brings a hidden bar back"
- **Code:** `lib/app/touch_exploration_scope.dart`, `lib/app/widgets/home_branch_stack.dart`

### NAV-19 The user arranges the bar; branches keep their numbers
- **Rule:** Bar and rail follow `homeArrangementProvider` (Me stays, >= 2 items remain) while branch indices and routes never renumber; off-bar pages open from Me (and Recommended shows a search action when Search is hidden). `/` lands on `homeStartDestination` (persisting "last used" only on app hide).
- **Why:** User request; renumbering broke restoration and per-switch writes rebuilt the app root.
- **Check:** `test/navigation_router_test.dart` "a rearranged bar starts, goes back and reaches hidden pages"; `test/home_destination_test.dart` "a saved bar keeps Me and two destinations whatever it says" "back lands on the start page, the one used last where a run opened"
- **Code:** `lib/core/navigation/home_destination.dart`, `lib/app/widgets/home_branch_stack.dart`, `lib/features/settings/pages/bottom_bar_settings_page.dart`

## Branch switching and re-tap

### NAV-13 Re-tapping a destination is an edge event
- **Rule:** Active-destination re-tap pops its stack to root and emits once on `ReTapChannel` (`ChangeNotifier`, never `ValueNotifier`); consumers scroll post-frame via `reTapScrollToTop` or trigger `PullToRefresh.trigger` when already at top.
- **Why:** `ValueNotifier` dropped repeat taps and pre-pop scrolls targeted covered pages.
- **Check:** `test/home_branch_stack_test.dart` "a same-destination tap emits one event per tap" "a re-tap pops the branch stack back to its root"
- **Code:** `lib/app/widgets/home_branch_stack.dart`, `lib/app/pull_to_refresh.dart`

## Top bars, tabs and choices

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
- **Check:** `test/architecture/ui_conventions_test.dart` "page top bars are AppTopBar"; `test/desktop_command_bar_test.dart` "DesktopCommandBar chrome, drag regions, header deduplication, and popovers" "flat AppTopBar occupies exact 52dp and narrow command bar preserves 48dp drag space"
- **Code:** `lib/app/widgets/app_top_bar.dart`, `lib/app/widgets/replica_scaffold.dart`, `lib/app/widgets/master_detail_workspace.dart`

## Wide windows

### NAV-20 Three forms: a phone's bar, a touch rail, a PC rail
- **Rule:** `FormFactorScope` resolves phone (`AppBreakpoints.isPhoneDisplay` -> always `FuncBottomNav` with `AppIcons.newWorks`), `touch` tablet, or `pc` desktop (`>= 600dp` mounts `ShellRail`: 74dp collapsed fitting all four locales, 204dp expanded; primary nav labels and bottom theme label use separate `LabelFit` groups so theme cycling never shifts nav label scale). On `FormFactor.pc`, `ShellRail` stays permanently expanded at 204dp whenever `hasRail` holds (`>= 600dp`) with no collapse toggle (`canToggleRail == false`); large touch screens (`>= 840x480`) keep the manual collapse/expand toggle and auto-collapse to 74dp on Me/Settings. Under `DesktopCommandBarScope`, the rail hosts mutually exclusive `我的` (`/settings`), `收藏` (`/settings/me?tab=bookmarks`), `下载` (`/settings/downloads`), and `设置` (`/settings/all`) navigation (pressing Back from `收藏`/`下载`/`设置` returns to the originating branch when entered from branches 0..3 without pushing a stale `'settings'` forward entry, while explicit branch selection via shortcuts/menus/rail clears the pending return branch atomically through `ForwardHistoryStack.selectHomeDestination`) plus a 3-state theme cycle (`light -> dark -> system -> light`). `HomeBranchStack` paints `HomeRailModalScrim` over `ShellRail` behind bounded `DetailOverlayFrame`s without breaking `HeroController`. Immersive routes hide the rail post-frame.
- **Why:** Keeps desktop navigation predictable without duplicate chrome, rail collapse jumps, theme-cycle label jitter, or Me/Bookmarks/Downloads/Settings loops while preserving compact rail density on tablets.
- **Check:** `test/home_branch_stack_test.dart` "a turned phone keeps the bottom bar" "the interface form changes the shell at once and keeps the open page" "ShellRail dims behind bounded DetailOverlayFrame and dismisses on tap" "desktop rail cycles 3-state theme and keeps Me, Bookmarks, Downloads, and Settings mutually exclusive"; `test/locale_layout/compact_controls_test.dart` "compact ShellRail keeps every label untruncated across locales"; `test/novel_reader_stage_test.dart` "the current reader hides the shell rail, under its panels too"; `test/layout_breakpoints_test.dart` "a phone, a touch screen or a PC, by display and platform"
- **Code:** `lib/app/layout/form_factor.dart`, `lib/app/navigation/desktop_rail_route.dart`, `lib/app/widgets/func_bottom_nav.dart`, `lib/app/widgets/shell_rail.dart`, `lib/app/widgets/home_branch_stack.dart`, `lib/app/navigation/home_shell_metrics.dart`, `lib/features/illust/detail/widgets/detail_overlay_frame.dart`

### NAV-25 A wide shell docks the search input under its trigger
- **Rule:** With a rail active (never on phones), `HeaderSearch` and result query fields open `SearchInputEngine` in a docked `showAppPanel` anchored under `PageHeader.anchorOf` (`>= 360dp`, re-anchoring on resize, closing before opening shortcuts/results, `Esc` leaving focus then closing). Editing a query from search results or the desktop command bar carries active session filters (`initialIllustFilters` / `initialNovelFilters`) into both `DockedSearchPanel` and `SearchInputPage`. Narrowing below the rail closes the panel (and any open filter sheet) and hands raw text + filter drafts to the full input page.
- **Why:** Keeps desktop browsing context visible during search without losing drafts or session filters across edits and resizes.
- **Check:** `test/docked_search_test.dart` "Esc leaves the field first, a second Esc closes the panel" "the scrim and the system back close the panel" "narrowing keeps the typed text and the filter drafts" "narrowing with the filter sheet open closes both layers"; `test/search_result_page_test.dart` "editing search query preserves session filters in both wide docked and narrow flows"
- **Code:** `lib/features/search/docked_search.dart`, `lib/features/search/search_input_engine.dart`, `lib/app/widgets/page_header.dart`, `lib/app/navigation/routes.dart`

### NAV-21 A resize keeps every branch, its stack and its place
- **Rule:** Resizing/folding reparents branch Navigators via stable `GlobalKey`s (preserving stacks and scroll offsets), preserves the on-screen image index across single-column <-> two-pane detail transitions (measured from laid-out pages, guarding narrow reveal against visibility overwrite and keeping `DetailImagePager` synced via `didUpdateWidget`), aligns skeleton/stand-in/stage two-pane split ratios via `detailTwoPaneMetrics`, and anchors `DetailOverlayFrame` with a persistent `GlobalKey` across the 960x600 threshold without wrapping it in `LayoutBuilder`.
- **Why:** Prevents losing navigation stacks or reading position, avoids `GlobalKey` build/layout reparenting assertions, and eliminates skeleton-to-stage column jumps when resizing windows or folding devices.
- **Check:** `test/home_branch_stack_test.dart` "a resize keeps every branch, its stack and its scroll"
- **Code:** `lib/app/widgets/home_branch_stack.dart`, `lib/features/illust/detail/illust_detail_page.dart`, `lib/features/illust/detail/illust_detail_scroll.dart`, `lib/features/illust/detail/illust_detail_shells.dart`, `lib/features/illust/detail/widgets/detail_overlay_frame.dart`, `lib/features/illust/detail/widgets/detail_image_pager.dart`, `lib/features/illust/detail/widgets/illust_detail_skeleton.dart`

### NAV-22 Esc goes back
- **Rule:** `KeyboardBack` maps `Esc` to the router's `popRoute` (unfocusing text fields first; no-op at the start root), using a dedicated intent because page routes disable `DismissIntent`.
- **Why:** Gives keyboard users parity with system back.
- **Check:** `test/home_branch_stack_test.dart` "Esc goes back as the system back does, short of leaving"
- **Code:** `lib/app/navigation/keyboard_back.dart`, `lib/app/app.dart`

### NAV-26 Desktop command bar, window chrome, and per-branch forward history
- **Rule:** On desktop `FormFactor.pc` (`InterfaceForm.touch` hides it while `DesktopWindowFrame` still publishes `'buttons'` and `titleBarHeight` for caption hit-testing), `AppChrome` mounts `DesktopCommandBar` inside `Overlay.wrap` (48dp custom titlebar on Windows/macOS with Win32 `GetDpiForWindow` hit-testing prioritizing caption buttons (`HTMAXBUTTON`/`HTCLIENT`) ahead of resize rims, skipping resize rims on Aero-Snapped work-area edges while keeping unsnapped edges and the 3dp non-corner Windows right resize rim unobstructed, macOS 11+ `.unified` `NSToolbar` centering native traffic lights, and `DesktopDragRegion` starting macOS drags after 3dp movement with `MainFlutterWindow` caching the primary mouse event while preserving double-click zoom; compact 40dp toolbar without duplicate brand/drag spacers when `usesSystemTitleBar` is true on Linux). `DesktopCommandBarScope` deactivates on pre-home routes (`/splash`, `/user-agreement`, `/welcome/*`, `/login/*`), scrims and disables controls while `ForwardHistoryStack.hasBlockingModal` is true (ignoring transparent popovers while keeping drag spacers and caption buttons live), progressively hides shortcut badge (`< 680dp`), wordmark (`< 600dp`), and search pill (`< 500dp`) while reserving `>= 48dp` drag space whenever `!usesSystemTitleBar`, routes Account settings to `/settings/account` (calling `syncSettingsDetail` when already there), isolates route `ModalBarrier` `BlockSemantics` from the bar, and keeps a persistent router `GlobalKey` so hiding the bar on `ImageViewerPage` never remounts `HomePage`. Fallback chrome omits disabled drag zones and yields to child controls; `DesktopWindowFrame` resets fullscreen hover-reveal on hide and keeps Linux `F11` fullscreen active even with `usesSystemTitleBar`. `ForwardHistoryStack` syncs live `homeBackDestination` (`NAV-03`), tracks per-branch forward history and modals by navigator bucket, and routes `KeyboardBack` `Ctrl/Cmd+1..5` through `selectHomeDestination` (`Ctrl/Cmd+B` opens bookmarks when `onToggleRail == null`), with Windows `WM_APPCOMMAND` filtering `FAPPCOMMAND_MOUSE` and 120 ms mouse side-button release debounce.
- **Why:** Unifies desktop navigation chrome, Win32/macOS caption hit-testing, modal-safe toolbar scrims, and browser-grade per-branch forward history without duplicate bars or double-navigating mouse clicks.
- **Check:** `test/desktop_command_bar_test.dart` "DesktopCommandBar chrome, drag regions, header deduplication, and popovers" "DesktopCommandBar compacts to 40dp toolbar without duplicate branding when usesSystemTitleBar is true" "AppChrome hides DesktopCommandBar for touch form, provides Tooltip Overlay, and ShellRail keeps shortcuts" "ForwardHistoryStack replays per-branch forward entries and debounces mouse back/forward" "AppChrome isolates Router BlockSemantics so DesktopCommandBar remains reachable in semantics" "wide AppChrome keeps HomePage element and state mounted across ImageViewerPage push and pop" "context menus open on the root navigator and offstage branch modals do not lock active branch forward history" "open root modals and text-editing focus suppress macOS menu actions" "pre-home routes deactivate DesktopCommandBarScope so pushed pages keep BackButton" "isDesktopPreHomePath classifies pre-home routes and buildDesktopPlatformMenus honors custom destination order" "flat AppTopBar occupies exact 52dp and narrow command bar preserves 48dp drag space" "Account settings menu entry opens AccountSettingsPage and re-targets wide SettingsPage" "DesktopCommandBar scrims and disables controls behind blocking modals while layered Cmd+W pops overlays first"; `test/desktop_window_test.dart` "macOS reserves traffic lights with zero custom buttons, Linux suppresses duplicate chrome" "DesktopFallbackWindowChrome omits dragZone when disabled and yields to child buttons on macOS" "exiting fullscreen via hover overlay resets _hoverReveal before next fullscreen" "DesktopDragRegion starts macOS drag after 3dp move and preserves double-click" "DesktopWindowFrame publishes caption, maximize, and buttons regions with height"; `test/input_modality_shortcuts_test.dart` "KeyboardBack handles Ctrl/Cmd settings, destination digits, rail toggle, and iOS Cmd" "KeyboardBack Ctrl/Cmd+B opens bookmarks when rail cannot toggle" "KeyboardBack opens keyboard shortcuts dialog on ? and Ctrl/Cmd+/" "mouse side button held past 120ms suppresses duplicate channel back while held and on release"; `tool/dev_workbench/catalog/os_e2e_flows.json` "os.desktop.window_resize_viewport_live" "os.desktop.window_zero_errors" "os.desktop.window_process_alive"
- **Code:** `lib/app/app.dart`, `lib/app/window/desktop_command_bar.dart`, `lib/app/window/desktop_drag_region.dart`, `lib/app/window/desktop_title_bar.dart`, `lib/app/navigation/forward_history.dart`, `lib/app/navigation/keyboard_back.dart`, `lib/app/navigation/keyboard_shortcuts_sheet.dart`, `macos/Runner/MainFlutterWindow.swift`, `windows/runner/flutter_window.cpp`

### NAV-27 Desktop workspace tabs and layered Cmd/Ctrl+W close
- **Rule:** Directly beneath `DesktopCommandBar`, `DesktopWorkspaceTabStrip` auto-hides at `0dp` when only the permanent root workspace tab exists and expands to `36dp` once secondary tabs open (wheel-scrollable, middle-click closes secondary tabs, `Ctrl+Tab` / `Ctrl+Shift+Tab` cycle tabs), rendered inside a `Material` surface and passing the explicit `GoRouter` down to secondary tabs. `DesktopWorkspaceTabHost` freezes inactive tabs via `Offstage` + `TickerMode` + `HeroMode` and wraps each secondary tab's `Navigator` in `HeroControllerScope.none` (intentional UX tradeoff: secondary tabs are leaf detail/profile/search views, so disabling cross-route Hero flights inside secondary tabs prevents Flutter's shared `HeroController` assertion crash across sibling Navigators without disturbing root-tab `TRANS-07` flights). Layered `Cmd+W` (macOS) / `Ctrl+W` (Windows/Linux) scopes dismissal to the active workspace tab: active modals/overlays first, then active `DesktopInspectableGallery` side inspectors (`DesktopInspectorDismissRegistry`), then the active secondary tab (never popping offstage root overlays), and on the root tab hides/closes the window on macOS only (no-op on Windows/Linux).
- **Why:** Prevents `GoRouter`/`Material`/`HeroController` crashes in real desktop shells and stops `Cmd/Ctrl+W` on a secondary tab from silently popping hidden overlays on the root tab.
- **Check:** `test/e2e/desktop_workspace_e2e_test.dart` "DesktopWorkspaceTabStrip auto-hides at 1 tab, preserves scroll, cycles, inherits GoRouter, and closes on middle-click" "Middle-click opens background tabs while preserving muted safety and Ctrl+Click batch selection" "Layered Cmd+W and Ctrl+W dismiss overlays, inspector, secondary tab, then macOS window only" "Secondary tab switches unfocus root editor, isolate mouse back, skip hidden inspector, dedupe search filters, and focus root on GoRouter navigation"
- **Code:** `lib/app/app.dart`, `lib/app/window/desktop_workspace_tabs.dart`, `lib/app/window/desktop_close_dispatcher.dart`

### NAV-28 Desktop window geometry, macOS Dock residency, and native menu bar
- **Rule:** `DesktopWindowSession` ignores minimized/off-screen Win32 sentinel geometry (`<= -30000` or `< 200x100`) on capture/save, keeps macOS Dock residency on non-forced close (exiting fullscreen before hiding while `applicationShouldTerminateAfterLastWindowClosed` returns `false`, and invoking native `terminate` on explicit quit), and handles macOS `applicationShouldTerminate` via `prepareForApplicationTerminate` (flushing `saveNow` and `onBeforeDestroy` with bounded timeouts while bypassing `closeToTray`, paired with AppKit's `.terminateLater` watchdog). On macOS, `DesktopMenuBar` includes standard AppKit menu items (`About`, `Services`, `Hide`, `Hide Others`, `Show All`, `Bring All to Front`, `Quit`, plus layered `File -> Close Tab` / `Close` `Cmd+W` switching dynamically with active secondary tabs), restores the native `MainMenu.xib` `Edit` menu via `MacosDesktopWindowBridge.restoreEditMenu`, omits dead PC rail-toggle controls, maps Navigate `Cmd+1..5` to `homeArrangementProvider.shown`, and guards nav/search/refresh/preferences shortcuts against open modals/root overlays and active text editing.
- **Why:** Preserves valid window bounds across minimized/multi-monitor exits, delivers native macOS Dock residency and clean `Cmd+Q` termination, and avoids broken AppKit menu items or shortcut leaks during text input.
- **Check:** `test/desktop_command_bar_test.dart` "DesktopMenuBar gates PlatformMenuBar to macOS and restores Edit menu" "buildDesktopPlatformMenus wires macOS menus, provided items, and shortcuts"; `test/desktop_window_test.dart` "saveNow still persists size and maximized when getPosition throws" "captureOrdinary and saveNow ignore Windows minimized sentinel bounds" "applicationShouldTerminate flushes saveNow and onBeforeDestroy bypassing closeToTray" "macOS close exits fullscreen and hides to Dock; forceQuit destroys" "DesktopWindowFrame publishes caption, maximize, and buttons regions with height"
- **Code:** `lib/app/window/desktop_menu_bar.dart`, `lib/app/window/desktop_window.dart`, `lib/app/window/desktop_window_adapter.dart`, `lib/core/platform/desktop_window_channel.dart`, `macos/Runner/AppDelegate.swift`
