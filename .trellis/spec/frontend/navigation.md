---
prefix: NAV
applies_to:
  - lib/app/navigation/**
  - lib/app/startup_gate.dart
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
- **Check:** manual — the app creates its router once, in its state
- **Code:** `lib/app/app.dart`, `lib/app/navigation/routes.dart`

### NAV-03 Back at a branch root returns to the start page, which confirms
- **Rule:** At any branch root other than the start page, also one the
  user took off the bar, back switches to the start page
  (`homeBackDestination`): the chosen one, read live, or with "last
  used" the one this run opened on, never the one written since. At the
  start page's root on Android, back shows `homeExitHint` and arms
  `homeExitWindow` (2 s); a second back inside it leaves the app. A push,
  an overlay, a branch switch or the app leaving the foreground ends the
  window and takes the hint down. Other platforms hand that back to the
  system.
- **Why:** User decisions: the double back first went so the system
  could preview going home, then came back without a setting, at the cost
  of that preview on the start page. Back landed on the first page on the
  bar even for a user who opens the app elsewhere. A hint left on screen
  after its window, or a window that outlived a covered page, turned a
  later back into an exit or a lie.
- **Check:** `test/navigation_router_test.dart` "a rearranged bar starts, goes back and reaches hidden pages" "a second back at the start exits"; `test/home_destination_test.dart` "back lands on the start page, the one used last where a run opened"
- **Code:** `lib/features/home/home_page.dart`

### NAV-04 Content opens on the current stack
- **Rule:** A page opened from a page stays on that page's stack; only the
  bottom bar and rail switch branches. Route facades push through `_push`,
  whose debug assertion rejects a push into another branch. Overlay routes
  (`/me`, `/reverse-image`, `/downloads`) may open from any stack; beside
  a rail `/me` and `/downloads` open on the current stack instead
  (NAV-20), except from the viewer. The
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

### NAV-23 The startup gate rescues only an auth stack
- **Rule:** Signed in, `StartupGate` sends the user home only when both
  the top path and the stack's base location
  (`routerDelegate.currentConfiguration.uri`, which leaves out pushed
  pages) are a login, welcome or splash route. Login pushed over an app
  page is "add account": it stays, and on success the login page pops
  back to the page that opened it. A page pushed over the splash (an
  image shared into a cold start) stays too, until back lands on the
  splash. The gate judges again after every stack change: it listens to
  the router delegate as well, rebuilding once the frame is done, since
  the delegate also notifies inside the Router's build.
- **Why:** A token refresh or a network-mode toggle rebuilt the gate
  during add account and threw the user home mid-OAuth. Judging the base
  alone dropped a share pushed over the splash, and left a finished add
  account on the login form. A pop does not notify the route information
  provider, so back from that share stayed on the splash.
- **Check:** `test/startup_gate_test.dart` "add account survives the gate rebuilding under it" "an image shared into a cold start stays open until back"
- **Code:** `lib/app/startup_gate.dart`, `lib/features/login/login_page.dart`

## Bottom bar

### NAV-07 The bottom bar is the Shaft-style bar
- **Rule:** `FuncBottomNav` is a custom 56dp bar: no indicator shape,
  selection is a tint (icon and label to `primary`, label weight up) on
  `effectsFast`; nothing moves or resizes. It casts `barShadow` up over
  the content (no hairline), as the comment composer does. Do not swap
  it for the M3 `NavigationBar`; the rail is the same style turned on
  its side (NAV-20). Labels share one `LabelFit` capped at 1.3x text scale.
  From 600dp wide (a turned phone, NAV-20) each destination puts its icon
  beside its label, as wide as both, and the group is centred (Compose's
  `ShortNavigationBar` in a medium window); the ripple is a pill the bar's
  height. Narrower, or when a label would not fit beside its icon at
  `LabelFit.minScale` (Japanese at 1.3x on 600dp), the destinations
  share the width, icon over label.
- **Why:** User decision after comparing with Shaft: no capsule or
  segmented bar; a shadow over a hairline on every bottom bar (10-25).
  On a turned phone five equal cells left 180dp between items; the user
  chose the side-by-side items (11-10).
- **Check:** `test/locale_layout/compact_controls_test.dart` "a turned phone's bottom bar keeps every label whole"; `test/func_bottom_nav_test.dart` "a wide bar puts each icon beside its label, centred"
- **Code:** `lib/app/widgets/func_bottom_nav.dart`

### NAV-08 Bar geometry is published, never measured
- **Rule:** The bar's resting extent comes from `HomeShellChrome`
  (computed from the fixed height plus the bottom inset on the first
  frame). The extent it covers right now is
  `HomeShellChrome.bottomBarVisibleExtent`, read with `.value` without
  rebuilding. No consumer measures or copies the bar geometry.
- **Why:** Post-layout measurement put the Hero landing clip and spacers a
  frame late.
- **Check:** `test/func_bottom_nav_test.dart` "the bar follows a drag and settles at the nearer end"
- **Code:** `lib/app/navigation/home_shell_metrics.dart`

### NAV-09 The bar follows the user's own scrolling
- **Rule:** The bar moves pixel for pixel with the user's own scroll of
  the current branch's root page, out going down and back going up. Once
  the scroll rests, a bar left part way settles at the nearer end after a
  drag, the way the page went after a wheel tick. Programmatic scrolls
  (`animateTo`, `jumpTo`, restored offsets), overscroll and nested
  horizontal strips never move it; a branch switch brings it back. The
  detail action bar follows its page the same way.
- **Why:** Edge bounces and scroll-to-top toggled the bar. Shaft's rule,
  a frame past 8 physical pixels, gated on speed: a slow scroll never
  moved it. The user chose Material 3's `exitAlways` follow (user
  decision 10-24).
- **Check:** `test/func_bottom_nav_test.dart` "edge bounce never toggles the bar" "the bar follows a drag and settles at the nearer end" "a wheel tick settles the way it went; other scrolls do not", `test/illust_detail_actions_test.dart` "the action bar follows a drag and settles at the nearer end"
- **Code:** `lib/app/motion/scroll_hide.dart`

### NAV-10 Pushed pages cover the bar
- **Rule:** While a branch root is covered (a route above it, or a page
  transition over it still running), the real bar is `Offstage` and the
  root page draws an inert copy in place, which leaves and returns with
  the page. The swap happens only where both overlap exactly: as a push
  starts and once a pop has fully revealed the root. A popup (sheet,
  branch dialog) does not drive the root's secondary animation, and the
  root is current again from the pop's first frame, so the branch
  Navigators use `ExitAwareRouteObserver`: in `didPopNext` the root takes
  the popped route's animation and stays covered until it is dismissed.
- **Why:** The bar floated over pushed pages and their action bars; a
  closing sheet slid out under the bar, back on top as the pop began.
- **Check:** `test/navigation_router_test.dart` "a pushed branch route covers the bar and hands it back" "keeps the bar under it until it has left" "a page pushed while a sheet leaves keeps the bar covered"
- **Code:** `lib/app/widgets/func_bottom_nav.dart`, `lib/app/navigation/home_shell_metrics.dart`, `lib/core/navigation/route_observer.dart`

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

### NAV-12 Branches slide under a tap or a swipe; the shell chrome stays still
- **Rule:** A bar tap slides the outgoing and incoming branches side by
  side from the side the destination sits on (300 ms,
  `branchSwitchCurve`, a cut under reduced motion). On a phone a swipe on
  a branch's root page drags it and its neighbour on the bar
  (`SwipePaging`, MOTION-20), in bar order, not wrapping, bouncing at the
  ends; the bar's selection moves on landing and the bar comes back. A
  page's tabs take a swipe first and hand it over only at their first or
  last tab, when the swipe starts (`SwipePagerScope`). No swipe over a
  pushed route or one still leaving (the root stays covered, NAV-10), on
  the rail or under touch exploration. Never wrap the
  whole `StatefulNavigationShell` (content and bar) in a transition. A
  tap's outgoing branch is a frozen snapshot and the incoming one stays
  live; under a swipe both stay live.
- **Why:** User decisions for the slide and for the swipe, the latter
  against Material 3's "Don't swipe between destinations". A transition
  around the shell flashed the scaffold background white. A leaving page
  no longer counts for `canPop`: a swipe under it slid the bar away with
  the branch, and the next one came in without a bar (10-31).
- **Check:** `test/home_branch_stack_test.dart` "a bar tap slides the new branch in from its side" "the incoming branch stays live while the outgoing one freezes" "takes over from the tabs at their last one" "a page without tabs pages at once; the end of the bar bounces" "keeps its destination"
- **Code:** `lib/app/widgets/home_branch_stack.dart`, `lib/app/motion/swipe_paging.dart`

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
  the row divides the width evenly when the widest label fits a share. A
  row 600dp or wider caps each share at 120dp, or the widest label plus
  its padding when that is wider, and keeps to the start edge; a narrower
  one is always split in full. Otherwise the row scrolls from the start
  edge with a 48dp `ScrollEdgeFade`. On a wide window a page's tabs may
  share the title's row (`AppTopBar.tabsBesideTitle`, NAV-24); the shares
  still cap at the widest label and keep to the start edge, however
  narrow the row. Labels are measured in the style
  `TabBar` paints: `titleSmall` merged with the theme's label style, under
  the system's text settings (LAYOUT-04).
- **Why:** Shrunk labels became unreadable in long languages; on wide
  windows even shares left the labels far apart: at 180dp seven profile
  tabs spread over about 1300dp. A flat cap faded a Russian label longer
  than it, and a style without `titleSmall`'s letter spacing measured a
  label 2dp narrower than painted. Capped on a phone, two tabs filled 360
  of 411dp; a 24dp fade was spent on the sliver of a cut label and read
  as a hard cut.
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
  `SliverAppBar` outside it. Titles start at the leading edge on every
  page. A hand-built bar (the reader's) lays out with
  `NavigationToolbar`: a title with `centerMiddle: false`, a readout
  centered on the whole bar. Content scrolled under a top bar is marked
  by `ScrollEdgeShadow`, `barShadow` cast down (`topBarShadow`), never a
  hairline; a self-drawn pinned strip that is the page's top edge (the
  profile tabs) wraps itself in it.
- **Why:** `AppTopBar` owns the scrolled-under shadow; pages with a raw
  bar had no scroll edge at all. The agreement and login pages centered
  their titles alone, and a readout centered between unequal neighbours
  sat off the bar's middle. User decision: top and bottom bars set
  themselves off the content alike (10-25).
- **Check:** `test/architecture/top_bar_test.dart` "page top bars are AppTopBar"; `test/app_tab_bar_test.dart` "a top bar with tabs casts its shadow once content scrolls under it"
- **Code:** `lib/app/widgets/app_top_bar.dart`

## Wide windows

### NAV-20 Three forms: a phone's bar, a touch rail, a PC rail
- **Rule:** User decision: the shell is laid out for a `FormFactor`
  (`lib/app/layout/form_factor.dart`), published by `FormFactorScope` in
  `AppChrome`. A phone, a display whose shortest side is under 600dp
  (`AppBreakpoints.isPhoneDisplay`, read from `View.display`; Android's
  sw600dp line), always shows the bottom bar, turned or not. A larger
  touch screen is `touch`; a desktop (Windows, Linux, macOS) is `pc`
  unless the user picks the touch shell under 「界面形态」, a setting
  only desktops offer. From 600dp wide both swap the bar for `ShellRail`,
  after Shaft's tablet rail: a header, the destinations from the top as
  one tab group, a short rule, then shortcuts to the bookmarks and the
  downloads, which open their pages without taking the selection. The
  selected entry sits on `primary` at 15%; the rail casts `barShadow`
  over the content instead of a divider, and scrolls when the window is
  too short. A touch rail is always the 88dp icon-over-label column under
  the app's icon. A PC rail's header is a menu button that opens the
  256dp labelled panel; it opens by itself from 1600dp until the user
  toggles it, then stays as left (`AppSettings.railExpanded`). Beside a
  rail, `/me` and `/downloads` open on the current branch's stack, so the
  rail stays; from the viewer they stay overlays (NAV-04). Pages size themselves from `HomeShellChrome.contentSizeOf`
  (the window less the rail), not the window. An immersive page hides the
  rail through `shellRailHiddenProvider` while its route is current or
  only popups (sheets, dialogs) cover it (the novel reader); it releases
  the rail after the frame, never in dispose.
- **Why:** On a turned phone five labelled items overflowed 411dp; the
  scrolling rail that fixed it took 80dp of a phone's width, and the user
  wanted phones, touch tablets and desktops told apart rather than one
  width ladder for all. The extended rail took 256dp from content on
  tablets; a desktop user wants to choose. Opening the profile or the
  downloads as overlays covered the rail; the reader showed the rail
  beside the text whenever a sheet opened over it.
- **Check:** `test/home_branch_stack_test.dart` "a turned phone keeps the bottom bar" "a short window on a tablet gets a scrolling icon rail" "a PC rail opens from extra-large widths until the user" "the interface form changes the shell at once and keeps the" "beside the rail, the downloads and the profile open in the"; `test/novel_reader_stage_test.dart` "the current reader hides the shell rail, under its panels"; `test/layout_breakpoints_test.dart` "a phone, a touch screen or a PC, by display and platform"
- **Code:** `lib/app/layout/form_factor.dart`, `lib/app/widgets/shell_rail.dart`, `lib/app/widgets/home_branch_stack.dart`, `lib/app/navigation/home_shell_metrics.dart`

### NAV-24 A wide destination bar: tabs, actions, then search
- **Rule:** Where the shell shows a rail (`PageHeader.isWide`, NAV-20), a
  destination root's top bar is one toolbar row: the page's `AppTabBar`
  takes the title slot at the leading edge, its own actions follow, and a
  search entry ends the row. That entry is `HeaderSearch`: a
  `SearchFieldButton` 360dp wide while the content area
  (`HomeShellChrome.contentSizeOf`, the window less the rail) is at least
  `AppBreakpoints.expanded` (840dp), otherwise a search icon; either
  opens the search input route on the kind shown. Only a destination's
  own root shows one — `HeaderSearch` renders nothing without
  `BranchRootScope`, so a pushed page, including the novel new and novel
  ranking pages that reuse these widgets, has none (R8). The recommended
  page's off-bar search icon (`_OffBarSearchAction`) hides while its bar
  is wide; the header's entry replaces it. 「我的」 keeps its title alone.
  On the result page the type tabs take the title slot, the filter button
  and a query field (`PageHeader.searchFieldWidth`: 360dp, or 240dp under
  an 840dp content area) end the row, and the active-filter summary keeps
  its own row under the bar.
- **Why:** The destination bars differed page by page — one empty, one
  with an off-bar icon — and on a rail each page decided its own width.
  One row puts the tabs where the user looks and gives every destination
  the same single search entry at the same edge; the field falls back to
  its icon when the content area cannot hold it.
- **Check:** `test/navigation_router_test.dart` "a destination bar ends in the search field" "ranking and new end their wide bars in the search field" "a page pushed over a destination root has no search entry" "a search destination off the bar still reaches search from"; `test/search_catalog_test.dart` "the guide camera opens reverse image search; the novel tab"; `test/search_result_page_test.dart` "the wide result bar keeps the kind tabs on its title row, the"
- **Code:** `lib/app/widgets/page_header.dart`, `lib/features/home/recommended/recommended_home_page.dart`, `lib/features/new/new_page.dart`, `lib/features/ranking/ranking_tabs.dart`, `lib/features/search/search_page.dart`, `lib/features/search/search_result_page.dart`

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
