---
prefix: NAV
applies_to:
  - lib/app/navigation/**
  - lib/app/widgets/home_branch_stack.dart
  - lib/app/widgets/func_bottom_nav.dart
  - lib/app/widgets/app_tab_bar.dart
  - lib/app/widgets/app_top_bar.dart
  - lib/app/widgets/tab_swipe_switcher.dart
  - lib/app/widgets/replica_scaffold.dart
  - lib/app/motion/scroll_hide.dart
  - lib/app/touch_exploration_scope.dart
  - lib/features/home/**
reviewed: 2026-10-17
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
- **Rule:** Pages navigate through the functions in `routes.dart`; route
  data is durable path and query values. `extra` carries only an in-memory
  first-frame snapshot, and the page must render without it.
- **Why:** Untyped `extra` routes lost their state on restoration and deep
  links.
- **Check:** `test/navigation_restoration_test.dart`
- **Code:** `lib/app/navigation/routes.dart`

### NAV-02 The router instance never rebuilds
- **Rule:** Settings, account and provider changes never recreate the
  `GoRouter`. Restoration scope ids, `PageStorageKey`s and
  `restorationId`s stay stable.
- **Why:** A rebuilt router discards every branch stack and the restoration
  state.
- **Check:** `test/navigation_router_test.dart` "shell owns the active tab and preserves branch stacks"
- **Code:** `lib/app/app.dart`, `lib/app/navigation/routes.dart`

### NAV-03 Back at a branch root returns to the first; the first confirms
- **Rule:** At any branch root other than the first destination on the
  bottom bar, also one the user took off the bar, back switches to that
  first destination. At the first destination's root on Android, back
  shows `homeExitHint` and arms `homeExitWindow` (2 s); a second back
  inside it leaves the app. A push, an overlay, a branch switch or the
  app leaving the foreground ends the window and takes the hint down.
  Other platforms hand that back to the system.
- **Why:** User decisions: the double back first went so the system
  could preview going home, then came back without a setting, at the cost
  of that preview on the start page. A hint left on screen after its
  window, or a window that outlived a covered page, turned a later back
  into an exit or a lie.
- **Check:** `test/navigation_router_test.dart` "branch back returns to the recommended root" "a rearranged bar starts, goes back and reaches hidden pages" "a second back at the start exits"
- **Code:** `lib/features/home/home_page.dart`

### NAV-04 Content opens on the current stack
- **Rule:** A page opened from a page stays on that page's stack; only the
  bottom bar and rail switch branches. Route facades push through `_push`,
  whose debug assertion rejects a push into another branch. Overlay routes
  (`/me`, `/reverse-image`, `/downloads`) may open from any stack. The
  viewer opens only overlay destinations, and "back to the work" closes the
  viewer instead of pushing a second detail page.
- **Why:** Pushing into another branch switched tabs under the user and
  stacked duplicate pages.
- **Check:** `test/navigation_router_test.dart` "branch pushes are rejected outside the visible branch" "tag search stays on the stack it was opened from"
- **Code:** `lib/app/navigation/routes.dart`

### NAV-05 A page that can be alone on the stack has an up location
- **Rule:** A page reachable by deep link or gate redirect passes
  `ReplicaScaffold(upLocation:)`, so back with nothing to pop goes there
  instead of leaving the app.
- **Why:** Deep-linked pages exited the app on back.
- **Check:** manual
- **Code:** `lib/app/widgets/replica_scaffold.dart`

### NAV-06 Search swaps routes instead of stacking them
- **Rule:** Submitting search input replaces the input route with the
  results (`pushReplacement`), and editing the query replaces results with
  input. `context.replace` is only for a page updating its own query (tab
  or type), because it keeps the page key and skips the transition.
- **Why:** Stacked search routes made back walk through every query.
- **Check:** `test/navigation_router_test.dart` "search input and results stay on the requesting stack"
- **Code:** `lib/app/navigation/routes.dart`, `lib/features/search/search_result_page.dart`

## Bottom bar

### NAV-07 The bottom bar is the Shaft-style bar
- **Rule:** `FuncBottomNav` is a custom 56dp bar: no indicator shape,
  selection is a tint (icon and label to `primary`, label weight up) on
  `effectsFast`; nothing moves or resizes. Do not swap it for the M3
  `NavigationBar`. The wide layout's `NavigationRail` keeps the M3 rail.
  Labels share one `LabelFit` capped at 1.3x text scale.
- **Why:** User decision after comparing with Shaft. No capsule or
  segmented bar.
- **Check:** `test/locale_layout/compact_controls_test.dart`
- **Code:** `lib/app/widgets/func_bottom_nav.dart`

### NAV-08 Bar geometry is published, never measured
- **Rule:** The bar's resting extent comes from `HomeShellChrome`
  (computed from the fixed height plus the bottom inset on the first
  frame). The extent it covers right now is
  `HomeShellChrome.bottomBarVisibleExtent`, read with `.value` without
  rebuilding. No consumer measures or copies the bar geometry.
- **Why:** Post-layout measurement put the Hero landing clip and spacers a
  frame late.
- **Check:** `test/func_bottom_nav_test.dart` "the shell bar publishes its live visible extent"
- **Code:** `lib/app/navigation/home_shell_metrics.dart`

### NAV-09 Only the user's own scrolling hides the bar
- **Rule:** The bar hides when one frame's user scroll exceeds 8 physical
  pixels down and shows on the same going up. Programmatic scrolls
  (`animateTo`, `jumpTo`, restored offsets), overscroll, bounces and
  nested horizontal strips never move it. Only the current branch's root
  page drives it; a branch switch brings it back. The detail action bar
  uses the same tracker.
- **Why:** Edge bounces and scroll-to-top toggled the bar.
- **Check:** `test/func_bottom_nav_test.dart` "edge bounce never toggles the bar" "slow frames and scrolls the user did not make keep the bar"
- **Code:** `lib/app/motion/scroll_hide.dart`

### NAV-10 Pushed pages cover the bar
- **Rule:** While a branch root is covered (a route above it, or a page
  transition over it still running), the real bar is `Offstage` and the
  root page draws an inert copy in place, which leaves and returns with
  the page. The swap happens only where both overlap exactly: as a push
  starts and once a pop has fully revealed the root.
- **Why:** The bar floated over pushed pages and their own action bars.
- **Check:** `test/navigation_router_test.dart` "a pushed branch route covers the bar and hands it back"
- **Code:** `lib/app/widgets/func_bottom_nav.dart`, `lib/app/navigation/home_shell_metrics.dart`

### NAV-11 The bar does not hide under touch exploration
- **Rule:** While touch exploration is on, scrolling never hides the bar,
  and a hidden bar comes back when it starts. Widgets read
  `MediaQuery.accessibleNavigationOf`, which `TouchExplorationScope`
  rewrites from the native touch-exploration flag; they never read the
  provider.
- **Why:** The engine flag is true whenever any accessibility service reads
  the tree (the user runs one permanently), so it cannot mean TalkBack.
- **Check:** `test/home_branch_stack_test.dart` "a polluted engine flag does not pin the bar" "starting touch exploration brings a hidden bar back"
- **Code:** `lib/app/touch_exploration_scope.dart`, `lib/app/widgets/home_branch_stack.dart`

### NAV-19 The user arranges the bar; branches keep their numbers
- **Rule:** The bar and the rail show the destinations of
  `homeArrangementProvider` in its order; Me always stays and at least
  two remain. Only the display maps through `HomeDestination`: branch
  indices, routes and stacks never change, and a branch off the bar
  leaves nothing selected. A branch slide comes from the side its
  destination sits on in shown-then-hidden order. Off-bar destinations
  open from the Me page, and Recommended's top bar gains a search button
  while search is off the bar. Every way in to `/` (cold start, sign-in,
  a link to `/`) lands on `homeStartDestination`, which falls back to the
  first on the bar; the last-used destination is written only in that
  mode, when the app is hidden.
- **Why:** User request. Renumbering branches would break restoration,
  deep links and every `goBranch` caller; writing the last-used page on
  each switch would rebuild the app root through settings.
- **Check:** `test/navigation_router_test.dart` "a rearranged bar starts, goes back and reaches hidden pages" "the bar editor hides, keeps two and restores"; `test/home_destination_test.dart`
- **Code:** `lib/core/navigation/home_destination.dart`, `lib/app/widgets/home_branch_stack.dart`, `lib/features/settings/pages/bottom_bar_settings_page.dart`

## Branch switching and re-tap

### NAV-12 Branches slide; the shell chrome stays still
- **Rule:** A bar tap slides the outgoing and incoming branches side by
  side from the side the destination sits on (300 ms,
  `branchSwitchCurve`, a cut under reduced motion). No swipe between
  branches. Never wrap the whole `StatefulNavigationShell` (content and
  bar) in a transition. The outgoing branch is a frozen snapshot; the
  incoming one stays live.
- **Why:** User decision for the slide. A transition around the shell
  flashed the scaffold background white.
- **Check:** `test/home_branch_stack_test.dart` "a bar tap slides the new branch in from its side" "the incoming branch stays live while the outgoing one freezes"
- **Code:** `lib/app/widgets/home_branch_stack.dart`

### NAV-13 Re-tapping a destination is an edge event
- **Rule:** A tap on the active destination pops its stack to the root and
  emits once on `ReTapChannel` (a `ChangeNotifier`, never a
  `ValueNotifier`). Consumers check their branch, scroll post-frame
  through `reTapScrollToTop` with `mounted`/`hasClients` guards, and a list
  already at the top refreshes through `PullToRefresh.trigger`, which needs
  the list's `scrollController`. In-page tab re-taps do the same on their
  own controller.
- **Why:** A `ValueNotifier` swallowed repeated taps; scrolling before the
  pop committed hit a covered page.
- **Check:** `test/home_branch_stack_test.dart` "a same-destination tap emits one event per tap" "a re-tap pops the branch stack back to its root"
- **Code:** `lib/app/widgets/home_branch_stack.dart`, `lib/app/pull_to_refresh.dart`

## Top bars, tabs and choices

### NAV-14 Top tabs are AppTabBar and never shrink
- **Rule:** Every tab row is `AppTabBar`. Labels stay at the themed size;
  the row divides the width evenly when the widest label fits a share,
  each share at most 180dp with the row kept at the start edge; otherwise
  it scrolls from the start edge with `ScrollEdgeFade`.
- **Why:** Shrunk labels became unreadable in long languages; on wide
  windows even shares left the labels far apart.
- **Check:** `test/app_tab_bar_test.dart` "a wide row keeps its tabs together at the start"
- **Code:** `lib/app/widgets/app_tab_bar.dart`

### NAV-15 A tab tap never calls animateTo again
- **Rule:** `TabBar` animates its own tap. An `onTap` callback may update
  state but must not call `animateTo` for the same index; only selection
  that did not come from a tap animates programmatically.
- **Why:** A second animation reset the indicator and stalled fast taps.
- **Check:** manual
- **Code:** `lib/app/widgets/tab_swipe_switcher.dart`

### NAV-16 Announce the new tab's scroll position
- **Rule:** After a tab switch, call `announceTabScroll` from a body-level
  context, and register the tab controller's `onAttach` to announce a list
  that mounts later. Never nudge the list position
  (`didUpdateScrollPositionBy(0)`) to do it.
- **Why:** The top bar kept the previous tab's scrolled-under state; a
  position nudge made load-more fire an extra request.
- **Check:** manual
- **Code:** `lib/app/widgets/tab_swipe_switcher.dart`

### NAV-17 No segmented buttons
- **Rule:** Choices use the control their use case calls for:

  | Use case | Control |
  |---|---|
  | Peer views | `AppTabBar` |
  | Setting with 2–4 values | `SettingsMenuTile` |
  | Setting with more values | `SettingsGroup` of `SettingsChoiceTile`s |
  | Two-way property | `SettingsControl` switch |
  | Choice of action | One button per action |
  | List filter | `FilterMenuButton` ("current value ▾" + menu) |

- **Why:** User decision: pill-shaped segmented buttons are removed from the
  whole app.
- **Check:** `test/architecture/no_segmented_test.dart`
- **Code:** `lib/app/widgets/filter_menu_button.dart`

### NAV-18 Page top bars are AppTopBar
- **Rule:** Every page's top bar is `AppTopBar`; no raw `AppBar` or
  `SliverAppBar` outside it.
- **Why:** `AppTopBar` owns the scrolled-under edge line; pages with a raw
  bar had no scroll edge at all.
- **Check:** `test/architecture/top_bar_test.dart` "page top bars are AppTopBar"
- **Code:** `lib/app/widgets/app_top_bar.dart`

## Wide windows

### NAV-20 Wide windows get a scrolling icon rail
- **Rule:** From 600dp wide the shell swaps the bar for a
  `NavigationRail`: an 80dp icon rail with labels below 1600dp, the 256dp
  extended rail from 1600dp. The rail scrolls when the window is too short
  for its items. Pages size themselves from `HomeShellChrome.contentSizeOf`
  (the window less the rail), not the window. An immersive page hides the
  rail through `shellRailHiddenProvider` while its route is current (the
  novel reader); it releases the rail after the frame, never in dispose.
- **Why:** On a turned phone five labelled items overflowed 411dp; the
  extended rail took 256dp from content on tablets; the reader showed the
  rail beside the text.
- **Check:** `test/home_branch_stack_test.dart` "a turned phone gets a scrolling icon rail"; `test/novel_reader_stage_test.dart` "the current reader hides the shell rail"; `test/layout_breakpoints_test.dart` "extended rail waits for the extra-large boundary"
- **Code:** `lib/app/layout/app_breakpoints.dart`, `lib/app/widgets/home_branch_stack.dart`, `lib/app/navigation/home_shell_metrics.dart`

### NAV-21 A resize keeps every branch, its stack and its place
- **Rule:** Turning, folding or dragging the window keeps the shell's
  branches, their pushed pages and scroll offsets: switching between the
  bar and the rail reparents the branch Navigators (their GlobalKeys)
  instead of rebuilding them. A two-pane detail keeps its page.
- **Why:** Desktop-class windows resize all the time; losing the open page
  or the scroll on each resize would make the rail unusable.
- **Check:** `test/home_branch_stack_test.dart` "a resize keeps every branch, its stack and its scroll"; `test/illust_detail_actions_test.dart` "arrow keys page the image pane; a resize keeps the page"
- **Code:** `lib/app/widgets/home_branch_stack.dart`

### NAV-22 Esc goes back
- **Rule:** `KeyboardBack` maps Esc to the router's `popRoute`, the path
  the system back takes, so dialogs, PopScope and the shell's return to
  the first destination behave the same. In a text field Esc only leaves
  the field; at the first destination's root it does nothing. Esc gets
  its own intent: every page route answers `DismissIntent` with a
  disabled action, which stops the lookup there.
- **Why:** With a keyboard there was no way back but the on-screen
  arrow.
- **Check:** `test/home_branch_stack_test.dart` "Esc goes back as the system back does, short of leaving"
- **Code:** `lib/app/navigation/keyboard_back.dart`, `lib/app/app.dart`
