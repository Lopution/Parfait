# Component Guidelines

> How components are built in this project.

---

## Overview

Shared UI belongs under `lib/app/widgets/` or `lib/app/motion/`; feature-specific
composition belongs under `lib/features/`. A shared widget owns one interaction
contract and exposes the smallest typed input needed by its callers. Feature
pages compose those widgets and keep repositories, controllers, and route
facades as their existing owners.

The app builder is the composition boundary for app-wide bridges. A feature
must not create a second global theme, router, compatibility bridge, or intent
listener.

---

## Component Structure

Use a public widget with a `const` constructor where possible, immutable typed
fields, and a private state/widget for implementation details. Keep the build
tree close to the owner of the behavior: shared feed states stay in
`lib/app/widgets/feed/`, image quality and Hero hand-offs stay in `PixivImage`,
and route transitions stay in `lib/app/navigation/` and `lib/app/motion/`.

Prefer composition over a second variant of an existing shared widget. A
component may accept a `Widget child` or a typed callback when that is the
actual composition seam; it should not accept an untyped map of UI options.

---

## Props Conventions

Constructor inputs are immutable and use domain types or enums rather than
`Object`/`dynamic` pairs. Required inputs identify the content or action the
widget renders; optional inputs express a real visual or route variant and
have a stable default. Keep callbacks narrow and synchronous unless the
component owns an asynchronous operation.

Route data goes through the typed facade in `lib/app/navigation/routes.dart`.
Use route `extra` only for an in-memory snapshot or an input that is not part
of the durable URL; the page must still render from its durable scalar route
data.

---

## Styling Patterns

Read semantic colors and typography from `Theme.of(context)` and keep stable
brand values in `FuncTokens`. Shared component shapes, surfaces, and states
belong in `lib/app/theme/replica_theme.dart`; a feature should not recreate a
second light/dark palette or copy a component theme locally.

Use `MotionTokens` / `MotionSpring` through `resolve` / `spring` for every
UI animation (see the Motion Contract). A visible image keeps
the `PixivImage` quality/cache hand-off, and a feed keeps the shared
`PullToRefresh` wrapper rather than adding a parallel loading or gesture
implementation.

---

## Accessibility

Icon-only actions provide a localized `tooltip` or an equivalent semantic
label. Interactive images expose the artwork/user meaning through their
existing semantic label, and controls use their typed Material component so
focus, keyboard, touch, and screen-reader states remain available.
`PixivImage` keeps its decoded pixels out of semantics (only its failure
view and retry stay): the surface around it names the work. A work card is
one stop — its label carries rank, title and author, and the lines under
the image are excluded rather than read a second time (H2).

Text fields take the theme's one look (ST6): outlined with the control
radius and a floating label; call sites do not set `border`. A filter over
loaded content is a search, so it uses `SearchBar` like the search page.
A form's save is a `FilledButton` at the end of its group.

Navigation destinations and visible action labels come from generated l10n.
Do not use color or an unlabeled icon as the only indication of the selected
state or action.

---

## Common Mistakes

- A feature creates a second refresh wrapper, scroll state machine, theme, or
  global listener instead of composing the shared owner.
- A `TabBar` tap callback calls `animateTo` again, resetting the animation that
  `TabBar` already owns.
- A page pushes a route directly or passes route data as an untyped widget;
  use the typed route facade and durable path/query values.
- Two mounted artwork surfaces use the same unscoped Hero tag, or a card
  waits for image preload before navigating.
- A router is rebuilt from settings/account changes, discarding branch stacks
  and restoration state.
- A route facade hard-codes a branch path for a page that can be opened from
  another stack; use the current stack root and the `_push` integrity assertion.
- An error state with a retry button that is not `FeedError`, `FeedTail` or
  wrapped in `RetryOnNetworkRestore`. Those retry once by themselves when the
  network comes back (HCI 9, `networkRestoreSignalProvider` counts the
  no-network → network transitions); only network and timeout failures, or
  an unknown error, retry — a 404 or a parse error would fail the same way.
- A status view (empty, error, restricted) draws its own button.
  `StateActionButton` (tonal, leading icon) is the one button of
  `FeedEmpty` and `FeedError` and of any custom status (H1). An empty view
  offers `refresh` only where content can still arrive (a live feed);
  content that is simply not there — a user without works, an empty
  history, no search results — offers no refresh and no retry (U4), at most
  another action (modify the search, import). `retry` belongs to failures.
- A shared state widget (`FeedEmpty`/`FeedError`/`FeedTail` family) carries an
  English fallback label. User-visible strings are `required` parameters so a
  call site that forgets `context.l10n.*` fails to compile instead of shipping
  untranslated UI.
- A branch-level transition wraps the whole `StatefulNavigationShell` (content
  + bottom chrome). IndexedStack swaps branches atomically, so the fade-in
  reveals the scaffold background as a white flash — keep chrome static and let
  the destination indicator animate instead.
- A `Scaffold` holding an autofocus field relies on the default
  `resizeToAvoidBottomInset: true`; the keyboard then compresses page geometry.
  Set it `false` and pad the scrollable by `viewInsets.bottom` instead.
- Edge-to-edge chrome (reader bars, bottom nav) must paint its `Material`
  through the system-bar inset: `SafeArea` goes *inside* the bar's surface
  to lift the controls, never wrapped around it — an outer `SafeArea` moves
  the whole background off the screen edge and leaves a bare strip (seen
  2026-09-19 in `novel_page.dart`'s reader chrome; `FuncBottomNav` and
  `card_action_sheet` are the correct precedent).
- A shared chip/action surface that sits on a `surfaceContainer`-equal
  background needs a hairline border to stay legible — same-value fills
  blend in both themes (`TagChip`'s brand-tinted outline, `_ActionPill` in
  `comment_item.dart` with the `divider` token).
- Entry animations keyed by list index replay whenever a refresh re-seats
  positions; identity-based state (played sets, element keys via
  `findChildIndexCallback`, `ValueKey(entity.id)`) must use the entity id.
- A control painted over artwork uses `ImageOverlayButton` (icon actions) or
  the `FuncTokens.imageControl`/`onImageControl` pair (pill counters and
  other non-button chrome). A `filledTonal` button or a plain glyph sits on
  an unpredictable image background — on a white artwork both wash out.
- Never hard-code `SliverPersistentHeaderDelegate.maxExtent` for a header
  whose content contains text. A fixed extent overflows at large text
  scales or under longer translations — measure the laid-out content after
  the frame and feed it back (the profile header's `_ReportSize` →
  `expandedExtent` loop is the reference), and keep the first estimate
  frame transparent so the correction is invisible.
- A `Stack` does not rescue a child that lays out past its bounds:
  non-`Positioned` children receive the stack's constraints only, so a
  block taller than the header still overflows (`RenderFlex`) instead of
  being clipped, and a positioned `OverflowBox` child paints past the
  stack unless clipped. Content that must stay under a boundary needs an
  explicit `ClipRect` — the profile identity block is clipped to the
  `top: minExtent, bottom: 0` region for exactly this reason.
- A long document page (the user agreement is the reference) wraps its
  one `ListView` in a single `SelectionArea` and renders paragraphs as
  plain `Text` — never a `SelectableText` per paragraph. Each
  `SelectableText` owns a `Scrollable`; `FuncScrollBehavior`'s
  always-scrollable bouncing physics leaks into it, so every paragraph
  drags and bounces on its own, and selection cannot span paragraphs.
  `onboarding_pages_test.dart` drags a paragraph under
  `FuncScrollBehavior` and expects the page itself to scroll.
- A date or count is formatted by hand (`'${d.year}-${d.month}'`,
  `NumberFormat` at the call site, `'${n}k'`). User-facing dates go through
  `AppFormat.date`/`relative` and counts through `AppFormat.count`, so every
  locale gets its own form (zh「1.2万」, en "12K"); a number that changes in
  place (progress, page index, counters) also takes `.tabular` so its
  neighbours do not shift. Data formats (route query dates, file names)
  stay out of `AppFormat` and are allow-listed with a reason in
  `test/architecture/format_and_font_test.dart`.

## Material 3 Theme Contract

`replicaTheme(Brightness, {systemColors})` is the single source of
light/dark `ThemeData`. `ColorScheme.fromSeed` uses `FuncTokens.primary`,
while semantic background, surface, text, subdued, and error values are
mapped from `FuncTokens` for the current brightness. AppBar, NavigationBar,
NavigationRail, TabBar, Card, Chip, Dialog, BottomSheet,
SnackBar, and Switch styles are defined there.

**Platform font.** No font family is bundled: text renders in the platform
font (Roboto on AOSP, the vendor font on OEM ROMs) with the engine's system
fallback chain for CJK. `fontFamilyFallback` exists only for the layout test
harness. `test/architecture/format_and_font_test.dart` fails on any
Montserrat mention in `lib/` or `pubspec.yaml`.

**System colors.** With `AppSettings.followSystemColors` on (default off),
`app.dart` watches `systemColorSchemesProvider` (`dynamic_color` core
palette on Android 12+, else the desktop accent, else null) and passes
`systemColors:` per brightness. Only the accent roles come from it —
`primary`, `onPrimary`, `primaryContainer`, `onPrimaryContainer`,
`inversePrimary`, `surfaceTint`; neutrals and the surface ladder stay on
`FuncTokens`. The settings row is disabled while the palette loads and
shows an "unavailable" subtitle when the platform has none. Everything
that paints the accent reads `Theme.of(context).colorScheme.primary` (or
`FuncSemanticTokens.brand`, which mirrors it) — `FuncTokens.primary` is
named only in `func_tokens.dart` and `replica_theme.dart`, enforced by the
same architecture test.

**Surface ladder.** Six monotonic M3 container tiers carry the whole
elevation story. `surface` equals `surfaceContainerLowest` and is the page
color; `surfaceContainerLow`, `surfaceContainer` (cards, chips, bottom
sheets — also `cardColor`), `surfaceContainerHigh` (dialogs,
`FuncSemanticTokens.surfaceRaised`), and `surfaceContainerHighest` step
darker in the light theme and lighter in the dark theme. Adjacent tiers must
stay distinguishable — `test/replica_theme_test.dart` pins the ordering, the
`FuncSemanticTokens` mapping (`canvas`/`surface`/`surfaceRaised` =
page/Container/High), and a 4.5:1 minimum for `onSurface`/`onSurfaceVariant`
on every tier. Image placeholders resolve the ambient `surfaceContainer` at
build time (`PixivImage.placeholderColor` defaults to null); the immersive
viewer passes `FuncTokens.transparent` instead.

**Pink discipline.** `primary` is reserved for primary actions, selected
states, and indicators. `secondary`/`secondaryContainer` are neutral grays —
tonal buttons and progress tracks are deliberately not pink. Selected
control states (`NavigationRail`, `NavigationBar`,
`EntityRow`) use `primaryContainer`/`onPrimaryContainer`. On a selected
`EntityRow` the title and the check icon resolve to opaque
`onPrimaryContainer`; subtitle and meta text keep the hierarchy with
`onPrimaryContainer` at alpha 0.8, which still composites to ≥4.5:1 on
`primaryContainer` in both themes (the old caption gray measured ~3.94 in
the dark theme). `EntityMetaText` takes an optional `color` for this;
unselected rows keep the default caption color.

**Component text styles.** Component themes (`appBarTheme.titleTextStyle`,
`snackBarTheme.contentTextStyle`, `chipTheme` label styles,
`dialogTheme` title/content, `navigationRailTheme` label styles) derive from
the *resolved* `theme.textTheme` in the trailing `copyWith` block of
`replicaTheme` — never from a raw `TextStyle` inside `ThemeData(...)`. Raw
styles drop the text theme's letter spacing, line height and fallback
chain (AppBar/SnackBar/Chip/Dialog install the style wholesale via
`DefaultTextStyle`, no merge). Explicit sizes/weights stay; only family,
letter spacing, and line height come from the text theme.

**Type scale.** One scale lives in `replicaTheme`'s `textTheme.copyWith`
block; nothing else may carry its own ramp. Roles: `titleLarge` 20/w600,
`titleMedium` 16/w600, `titleSmall` 14/w500, `bodyLarge` 14/w500,
`bodyMedium` 14/w400 (the default body), `bodySmall` 12/w400,
`labelLarge` 14/w500, `labelSmall` 11/w500, `headlineSmall` 18/w500.
`FuncSemanticTokens.fromBrightness(brightness, textTheme, primary:)` derives its
type ramp from these roles — `display`/`title`/`body`/`label`/`caption`/
`numeric` = `titleLarge`/`titleMedium`/`bodyMedium`/`labelLarge`/
`bodySmall`(secondary color)/`labelLarge`(+tabular figures) — so the
semantic layer adds meaning, never a second size table. Widgets pick a
role from `Theme.of(context).textTheme` or a semantic token; explicit
`fontSize:` literals are allowed only for deliberately fixed sizes
(e.g. the bottom-nav 12sp label base) and do not track the ramp.
`test/replica_theme_test.dart` pins every role's size/weight and each
token's equality with its role.

**Spacing and shape tokens.** Feature code never writes a numeric
`EdgeInsets.(all|symmetric|only|fromLTRB)` or `Radius.circular` — spacing
resolves to `FuncSpacing` (xxs 2, xs 4 … xxxl 48) and component radii to
`FuncShape` (`segment` 4, `control` 8, `card` 12, `dialog` 28, `sheet` top
corners, `pill`). All-zero insets are `EdgeInsets.zero`; `SizedBox(width/height)`
used as a `Row`/`Column` gap takes the same tokens (fixed image/control
dimensions are not spacing and stay literal). Absorption: pick the nearest
token in density order (6 → `sm` when unsure, 10 → `md` for card-text
indent else `sm`, 20 → `xl` for page margins else `lg`, 28 → `xxl`);
deviations go in the commit message. A grid and the skeleton standing in
for it share one constant — `IllustFeedGrid.defaultPadding`/
`defaultMainAxisSpacing`/`defaultCrossAxisSpacing` are the defaults,
`IllustGridSkeleton` references them, and a page that overrides the grid
passes the same file-local constant to both. `test/architecture/
spacing_tokens_test.dart` scans `lib/app/**` and `lib/features/**` (minus
`lib/app/theme/**`) for literals inside those calls; legitimate cases are
rephrased or allow-listed per file with a reason and a site count, never
per line number.

**SnackBar.** Transient feedback uses `inverseSurface`/`onInverseSurface`
with `inversePrimary` actions, so a SnackBar reads as inverted chrome on
both themes. Do not restyle it to a container tier.

**AppBar scrolled-under.** Page top bars are `AppTopBar`
(`lib/app/widgets/app_top_bar.dart`); a raw `AppBar(`/`SliverAppBar(` in
`lib/` fails `test/architecture/top_bar_test.dart`. The bar never changes
colour or lifts: `appBarTheme.backgroundColor` is the page surface in both
states and `scrolledUnderElevation` is 0 (an elevation shadow does not show
on the dark page). Content scrolled beneath the bar is marked by a
`ScrollEdgeLine` along its bottom edge — a 1dp hairline in
`FuncSemanticTokens.divider`, faded on the `effectsFast` spring (at once
under reduced motion). `AppTopBar` tracks "scrolled under" with the
`AppBar` rule (a `ScrollUpdateNotification` passing `notificationPredicate`
from a vertical scrollable past its leading edge) in a notifier, so only
the line rebuilds. Feature bars never set a background except the
selection bar. A self-drawn pinned bar that is the page's top edge puts a
`ScrollEdgeLine` at its own bottom (the profile tab strip, on the
`NestedScrollView`'s `innerBoxIsScrolled`). For a page whose tabs each own a
scrollable, pick the rule by the tab body, not by hand:

| Tab body | Scroll-notification depth | Rule |
|---|---|---|
| `TabSlideStack` (no Scrollable ancestor; list depth 0) | 0 | Default judgement is already the visible list — call `announceTabScroll` after each switch |
| `TabBarView`/`PageView` wrapping the list | 1 | `AppTopBar(notificationPredicate: (n) => n.depth == 1)` |

The bar only reacts to `ScrollUpdateNotification`, so after a tab switch
it would keep the previous tab's state: call `announceTabScroll` on the new
tab's `ScrollController` (see the Tab Navigation Animation Contract).

Feature code reads `ColorScheme`, `TextTheme`, and component defaults from the
ambient theme. `MaterialUiCompatibilityBridge` is installed once in the app
builder for legacy plugin subtrees; feature pages do not add another bridge.

## System UI Contract

`lib/app/system_ui.dart` is the only file that may mention `SystemChrome.`,
`SystemUiOverlayStyle(`, or `AnnotatedRegion<SystemUiOverlayStyle>` —
`test/architecture/feedback_channels_test.dart` scans `lib/` for exactly
one owner. Feature code uses the three seams below.

- `funcSystemBarsStyle(Brightness background)` builds the style: transparent
  status and navigation bars, icon brightness inverted from the brightness
  painted *under* the bars, `statusBarBrightness` (iOS) equal to the
  background brightness, transparent nav divider.
- **Root default.** `ParfaitApp`'s `MaterialApp.router` builder wraps the
  whole app in `FuncSystemBars(background: Theme.of(context).brightness)` —
  inside `AnimatedTheme`, so theme switches re-resolve it. Pages without an
  AppBar still get correct bar icons because the root region covers both
  edges. `appBarTheme.systemOverlayStyle` is pinned to the same function so
  the top region never disagrees with the root.
- **Scoped override.** `FuncSystemBars({required Brightness background,
  required Widget child})` wraps a page needing a different style (the image
  viewer's black stage uses `Brightness.dark` → light icons). It is built on
  `AnnotatedRegion`, so unmounting the page restores the root style on the
  next frame — no imperative reset.
- **Immersive mode.** `setSystemUiMode(SystemUiMode)` is the only caller of
  `SystemChrome.setEnabledSystemUIMode`; a platform `Exception` is logged,
  never thrown or silently dropped. `ParfaitApp.initState` enters
  `edgeToEdge` once at startup; the image viewer and the novel reader
  toggle `immersiveSticky`/`edgeToEdge` with chrome visibility through the
  same helper.
- **Page-level immersion lifecycle.** A page that goes immersive enters
  `immersiveSticky` in `initState`, flips to `edgeToEdge` while its chrome
  is shown, flips back when it hides, and restores `edgeToEdge` the moment
  the pop starts (`PopScope.onPopInvokedWithResult` with `didPop == true`)
  plus once more in `dispose` as the path that cannot miss. Every call is
  `unawaited` and goes through `setSystemUiMode`.
- **Stable insets while the bars hide.** A page that hides the system bars
  must not lay out from live `MediaQuery` padding/viewPadding — hiding
  reports zero insets and would regrow the body (the novel reader would
  repaginate). Capture the with-bars `viewPadding` once, keep each edge's
  maximum, and reseed only when the screen size changes. Known edge case:
  rotating while immersive reports a zero inset on the new size, so the
  first chrome reveal after rotation adjusts the body once (the reader's
  commit gate keeps the anchor); it is stable again afterwards.
- **Novel progress hint band.** The reader's always-on progress hint sits
  `4dp` above the stable bottom inset. The body's bottom padding is that
  inset plus the part of the hint band (`4 + one hint line`, measured with
  the hint's own style and `TextScaler`) not already covered by the layout's
  22dp `verticalPadding`. Every input is stable while reading, so chrome
  show/hide still never repaginates; the cost is about one line per page.
- **Sheets over an overriding page.** A page that overrides the bar style
  (a night palette reading surface) and opens an app-themed sheet lets the
  sheet own the covered edge: the sheet wraps itself in `FuncSystemBars`
  with its own surface brightness, so a light sheet over a dark reader
  flips the navigation-bar icons dark for as long as it covers them.

Widget tests read `SystemChrome.latestStyle` only after a `pump` (the
`RenderView` applies annotated regions at frame time) and mock
`SystemChannels.platform` to observe `setEnabledSystemUIMode` calls —
`test/system_ui_test.dart` covers both directions plus startup edgeToEdge.

## NavigationBar Contract

`HomeBranchStack` owns the bottom bar and the navigation rail — shell chrome
laid over the branch strip, not part of any page's content. Both read the
shared `homeDestinations(context)` list (five `FuncBottomNavDestination`s —
icon + localized label; the fifth is `homeMe`), so the bar and the rail
never disagree on order, icons, or labels. Destination selection goes
through `HomeBranchStack._select`, which calls `goBranch`; there is no
second tab controller or per-destination animation.

`FuncBottomNav` is a custom bar (`destinations`, `selectedIndex`,
`onSelected`) — not a `NavigationBar`, whose M3 indicator this app does
not draw. It follows Shaft's `BottomNavigationView` (user decision
2026-10-09, option C): a 56dp row on the page background
(`navigationBarTheme.backgroundColor`, else `surface`) under a
`ScrollEdgeLine.thickness` hairline in the `divider` token, the app's own
icons, and no indicator shape. The selected item is tinted: icon and label
go from `onSurfaceVariant` to `primary` and the label from w500 to w600.
A per-item controller drives the tint on `MotionSpring.effectsFast` both
ways (reduced motion sets it at once); nothing moves or changes size. The
ink is an `InkResponse` of radius 28 around the item centre. Item
semantics mirror `NavigationBar`'s: the destination exposes its localized
`tabLabel` plus the selected flag, so screen readers announce "selected,
<label>, tab, N of 5". Labels are laid out through `LabelFit` with a hard
1.3 scale cap — above `textScaler` 1.3 the label stays at 1.3 so the row
cannot outgrow the 56dp bar. The wide layout's `NavigationRail` keeps the
M3 rail and its indicator.

The shell publishes the bar's resting extent through `HomeShellChrome`, an
InheritedWidget `HomeBranchStack` wraps around the strip and the bar —
computed synchronously, not measured post-layout:
`rail ? 0 : FuncBottomNav.restingExtent(MediaQuery.paddingOf(context).bottom)`.
`restingExtent` is the fixed `_height` row plus the bottom safe-area inset
the bar's own `SafeArea` adds, and nothing between the stack and that
`SafeArea` strips the inset, so the computed value equals the rendered bar
height on the very first frame. `FuncNavBarSpacer` and the Hero landing
clip read the same extent — no consumer measures or copies the bar
geometry.

The bar hides on scroll (below), so
`HomeShellChrome.bottomBarVisibleExtent` publishes the height it covers *right
now*: `FuncShellBottomNav` computes it from the scroll visibility through
`ScrollHiddenChrome.shownOf`, the same curve that drives the slide. The Hero
landing clip caps the home-side edge with it per frame, so a returning image
is not cut at a bar that is not there yet. The bar writes it from its own
`build`, so consumers read `.value` and never rebuild on it; the only
listener is the prompt layout, which relayouts — the bar registers it as its
`PromptAnchor` (see the Prompt Feedback Contract). Everything else keeps the
resting extent. On NavigationRail layouts the extent is 0 and no
`FuncShellBottomNav` exists.

Scroll hide follows Shaft's capsule (`ScrollHideTracker`,
`lib/app/motion/scroll_hide.dart`): a frame whose scroll adds up to more
than 8 physical px (`framePhysicalPixels`, divided by the device pixel
ratio) down hides, up shows. Only the user's own scrolling counts — the
position reports a `UserScrollNotification` direction from a drag's first
move or a wheel tick until it rests, through the fling a drag releases
into; `animateTo`/`jumpTo` (scroll-to-top, restored offsets) never move the
bar. Only depth-0 vertical updates count and overscroll is clamped, so
bounces, stretches and nested horizontal strips are not reading direction.
The bar slides down by its height and fades together
(`ScrollHiddenChrome`, `MotionTokens.chromeScrollHide` 200 ms on
`chromeScrollCurve`, `Curves.easeInOutSine` — Android's default
AccelerateDecelerate) both ways; `slideChrome` is idempotent, so a drag
asking every frame does not restart it. A branch switch brings a hidden bar
back.

Only the current branch's root page drives it: `BranchRootScaffold` hands
its page's scroll notifications to `HomeShellChrome.onBranchRootScroll`;
routes pushed inside the branch are its siblings, so their scrolling never
reaches the bar.

Pushed pages cover the bar. `BranchRootScaffold` reports its route as
covered — `!route.isCurrent` (a page, sheet or menu on it) or its
`secondaryAnimation` not dismissed (a page transition over it still
running) — into `branchStackCoveredProvider`; RouteObserver callbacks and
secondary-animation status changes re-evaluate it, and those arriving while
the tree builds (`Navigator._updatePages`, synthetic replays) wait for the
frame's end. While the current branch is covered, `FuncShellBottomNav` is
`Offstage` and its anchor reports 0, and the root page draws an inert copy
(`IgnorePointer` + `ExcludeSemantics`, same scroll visibility, its own
`PromptAnchor` on the root route) at the same place in a stable `Stack`.
The routes above cover the copy like any other part of the page, and it
leaves and returns with the page under every transition and the predictive
back gesture. The swap happens where both overlap exactly: as a push
starts and once a pop has fully revealed the root. The provider tracks
owners, so a root page being replaced cannot clear its successor's report.

Scroll auto-hide yields to touch exploration: while
`MediaQuery.accessibleNavigationOf(context)` is true,
`HomeBranchStack._onBranchRootScroll` returns early — a TalkBack user
cannot find a bar that scrolled away. If the flag flips while the bar is
hidden, `_navVisibility` is driven back to 1. The engine sets
`accessibleNavigation` whenever any assistive service queries a node (GKD
pins it true for the session), so `TouchExplorationScope`
(`lib/app/touch_exploration_scope.dart`, at the app root) rewrites it to
the native touch-exploration flag from `touchExplorationProvider`; the
engine value passes through until Android reports. Below the scope the
flag means TalkBack-style exploration only: services that merely open the
semantics tree or read nodes do not set it, and the bar keeps hiding on
scroll for them. Widgets read the MediaQuery flag, never the provider.

The five labels share one `LabelFit` (see the Multi-Locale Layout
Contract): the widest translation sets one scale for all of them against
the slot `itemWidth − 2 × 6`, floor 0.8, and past the floor every label
ellipsizes with a tooltip. The labels are measured in the selected
style — the ambient `DefaultTextStyle` merged with the bar's 12sp w600
label style, the wider of the two weights — so one shared scale holds
for every destination in either state.
`compact_controls_test.dart` ('bottom bar') checks the labels whole in
every locale and size profile; `func_bottom_nav_test.dart` pins scroll
hide and the published extent.

## Top Tab Contract

`AppTabBar` is the single entry point for top-of-page tab rows; feature
pages do not instantiate a raw `TabBar`. It measures the widest label in
both label styles at the ambient text scale: when that label plus its
horizontal padding fits an equal share of the row width, the tabs divide
the width evenly (`TabAlignment.fill`); otherwise the row switches to
`isScrollable` and aligns from the start edge. Labels render at the themed
14sp (`replicaTheme` sets the `TabBarTheme` label styles) and are never
shrunk to fit — overflow always resolves through scrolling, not smaller
text. A scrolling row sits in `ScrollEdgeFade`, which masks out
`FuncSpacing.xl` at each end that has tabs past it (H3); it listens to the
row's own scroll and metrics notifications, so it needs no controller.
`onTap` is passed through to `TabBar.onTap` unchanged; per the Tab
Navigation Animation Contract a re-tap handler must not `animateTo` the
already-selected index.

## Choice Controls Contract (D3)

The app has no pill-shaped segmented buttons. A choice takes the control
its use case calls for:

| Use case | Control | Examples |
|---|---|---|
| Peer views | Top tabs (`AppTabBar`, Tab Navigation Animation Contract) | search guide types, Spotlight categories, bookmark tags public/private |
| A setting with one value from a short list (2–4) | `SettingsMenuTile` (current value at the row's end + menu) | image qualities, animation speed, haptic strength |
| A setting with one value from a longer list | A `SettingsGroup` of `SettingsChoiceTile`s | language, theme, page transition |
| A two-way property | A switch (`SettingsControl`) | the bookmark sheet's "private" |
| A choice of action | Buttons, one per action | the follow sheet |
| A list filter | `FilterMenuButton`: a "current value ▾" button opening a menu | own bookmarks and follows (Profile Header Contract) |

`test/architecture/no_segmented_test.dart` keeps the segmented family —
`SegmentedButton`, `segmentedButtonTheme` and the removed wrappers
`AppSegmentedButton`, `AppSegment`, `AppTypeSwitch`, `SliverAppTypeSwitch`,
`ProfileWorkTypeSwitch` — out of `lib/` entirely.

**`FilterMenuButton<T>`** (`lib/app/widgets/filter_menu_button.dart`):
`label` is the button text (the current value, with the filter's name
when the value alone is unclear: "Tag: All"); `options` are
`AppMenuEntry`s, the one matching `value` checked; a different pick plays
`select` and calls `onChanged`, the current one changes nothing. An
optional last entry (`moreLabel` / `onMore`) leaves the menu for a fuller
picker. Owning test: `selection_controls_haptics_test.dart`.

**New works.** The new-works page does not switch type in place: its
illustration page carries a book action in the AppBar (`newNovels`
tooltip) that pushes the common `new-novels` route — the same `NewPage`
with `type: NewFeedType.novel` and no book action — mirroring how the
novel ranking opens. Each page keeps its own scope in the URL
(`/new?scope=` and `.../new-novels?scope=`); an old `type=novel` link
lands on illustrations.

**Follow sheet.** `showFollowActionsSheet` (long press on
`FollowSwitchButton`, the profile header's follow-privately entry) shows
the user and one full-width button per action, at least 48dp tall: not
followed — "follow publicly" (filled) and "follow privately"; followed —
switch the visibility (both switches when the visibility is unknown) and
unfollow, which goes through `toggleFollowWithUndo`. There is no confirm
step. Owning test: `follow_switch_button_test.dart`.

**Bookmark sheet.** Visibility is one `SettingsControl` row,
`restrictPrivate`, with `contentPadding: EdgeInsets.zero` and its own
transparent `Material` (the sheet colour sits on a `DecoratedBox`). It
locks with the rest of the form while an existing bookmark's detail loads.

## Search Guide Contract

`SearchHomePage` (`lib/features/search/search_page.dart`):

- App bar: the title is a search-field-shaped button (stadium,
  `surfaceContainerHigh`, at least 48dp, `searchBarHint`) that opens the
  input page on the visible tab's type; the action is a camera
  `IconButton` (tooltip `searchReverseImage`) for reverse image search;
  `bottom` is an `AppTabBar` with illust & manga and novel.
- Tabs are a `TabSlideStack` in a `TabSwipeSwitcher`, built on first
  visit, each with its own scroll controller, `PageStorageKey`
  (`search-home-<type>`) and `announceTabScroll` after a switch. Tab and
  branch re-taps scroll the visible tab to the top.
  `trendingKindProvider` remembers the tab for the session;
  `trendingTagsProvider` is a family per type, kept alive.
- The illust tab starts with the Spotlight section: a header row (title,
  `spotlightSeeAll`, chevron; one 48dp target, header + button semantics)
  opening the full list, then the first five articles of the list's "all"
  feed as 200dp `SpotlightArticleCard`s in a horizontal strip
  (`IntrinsicHeight`, equal heights).
- Trending tags: `labelMedium` w600 single-line labels; a 0–60% black
  gradient over the bottom 40% of the image only; the count is cut to
  whole rows (`n >= columns ? n - n % columns : n`, columns as before).
  A tap searches the tag; there is no long-press gesture.

`SpotlightArticleCard` (`lib/app/widgets/feed/`) is the one article card:
16:9 image (placeholder icon without a thumbnail), title in two lines at
most, `AppFormat.date` in `bodySmall`/`onSurfaceVariant`, no chevron, the
whole card one target. The Spotlight list (`SpotlightFeedPage`) has
category tabs over independent feeds and full-width cards capped at 640dp.
Owning tests: `search_catalog_test.dart`, `spotlight_feed_test.dart`, the
`content: search home with Spotlight` and `content: Spotlight list`
matrices.

## Multi-Locale Layout Contract

### 1. Scope / Trigger

Every screen ships in zh, en, ja and ru on phones down to 320dp with large
system text. Russian and English labels run up to twice as wide as Chinese,
so a layout that fits in the template language can still cut, clip or
overflow. This contract applies to any change that adds or edits l10n copy,
a row of controls, or a page.

### 2. What must hold

- **UI text** is a paragraph whose text equals one of the current locale's
  l10n messages (messages with placeholders match by pattern). UI text is
  never cut by `maxLines`, clipped in height, wider than its box on a
  single line, or shrunk below `LabelFit.minScale` (0.8) by a transform
  such as `FittedBox`.
- The one exception: in the compact profile (below), a `FitLabel` that
  reached the 0.8 floor may ellipsize; it then carries the full text in a
  tooltip.
- **User content** — titles, user names, tags, captions, comments — may
  ellipsize as before.
- A label followed by its value goes through `l10n.labelValue(label,
  value)` (an error through `errorWithReason`), never `'$label: $value'`:
  Chinese and Japanese take a full-width colon with no space. Chinese copy
  uses full-width punctuation throughout and a space between Chinese and
  Latin words ("感谢使用 Parfait").
- No layout errors (overflow) in any locale or profile.
- A widget that measures its own text (the bottom bar, `AppTabBar`)
  measures with the exact style and text scaler it paints with, so the
  measured width equals the painted width.

### 3. Fix order

When a cell fails, fix it in this order, never with a per-language branch:

1. **Wrap**: body copy, explanations, settings titles and subtitles,
   dialog text, status lines, rows of buttons (`Wrap`, `OverflowBar`).
   Remove `maxLines`/`ellipsis` from UI text; give text-field helpers
   `helperMaxLines`.
2. **Scroll**: tab rows (`AppTabBar`), per its contract.
3. **Uniform scale**: groups of compact labels share one `LabelFit`
   (bottom bar), floor 0.8.
4. **Shorten the translation**, keeping its meaning; review all four
   languages together. Chinese is the template and changes only when its
   own layout needs it. Every change is listed in the PR as key, language,
   old → new.
5. Only when 1–4 cannot work: ellipsize in the compact profile through
   `FitLabel`.

Single-line slots that cannot wrap — `AppBar` titles, `SearchBar` hints,
chip labels — go straight to step 4, or carry less text: the search bars
use the short `searchBarHint` and keep the descriptive `searchHint` in the
input page body; the selection bar title is the bare count
(`selectionAppBar`).

### 4. Signatures

```dart
// lib/app/widgets/fit_label.dart
final class LabelFit {
  static const none;                 // scale 1, no truncation
  static const double minScale = 0.8;
  static LabelFit group({required Iterable<String> labels,
      required TextStyle style, required TextScaler textScaler,
      required TextDirection textDirection, required double slotWidth});
  static double measureLabel(String label, TextStyle style,
      TextScaler textScaler, TextDirection textDirection);
  final double scale;
  final bool truncates;              // the widest label ellipsizes at the floor
  TextScaler scaler(TextScaler base); // base × scale, what FitLabel draws with
}
class FitLabel extends StatelessWidget {
  const FitLabel(String text, {required LabelFit fit, TextStyle? style,
      TextAlign textAlign = TextAlign.center});
}

// lib/app/widgets/selection_app_bar.dart
AppTopBar selectionAppBar(BuildContext context, {required int count,
    required VoidCallback onClose, required List<Widget> actions});
```

- `LabelFit.group` fits the widest label in `slotWidth`; an unbounded slot
  never scales. One pixel of slack keeps rounding at the scaled size from
  ellipsizing the widest label. `FitLabel` never measures (it works under
  intrinsic-size queries); the host computes the fit from the slot it lays
  out.
- `selectionAppBar` is the top bar of every list in selection mode
  (history, download tasks): close, the count, batch actions on
  `primaryContainer`. Its title is the bare number with
  `selectedCount(n)` as the semantics label — next to three actions a
  sentence does not fit 320dp at large text in every language, and an
  ellipsis would cut the number off the Russian copy.

### 5. The matrix

- `test/locale_layout/` runs every covered page in each supported locale ×
  `LayoutProfile`: `regular` (360×780, text 1.0) and `compact` (320×568,
  text 1.3). Its `flutter_test_config.dart` loads real glyph widths:
  Roboto (the SDK's material fonts, standing in for the platform font) for
  Latin and Cyrillic, and a generated CJK box font (full-width 1em, half-width 0.5em, Noto
  Sans CJK line metrics). A missing font fails the run; other test
  directories keep the default test font.
- Register a page with `localeLayoutMatrix(name, body)`, build it with
  `localeLayoutApp(locale:, home:, overrides: | container:)`, settle with
  `settleLayout` (not `pumpAndSettle` — skeleton shimmer never settles),
  then check with `expectPageLayoutIntact`, which steps the first vertical
  scrollable down by 0.8 viewport and runs `expectLocaleLayoutIntact` at
  every stop. Open sheets and dialogs the way the app does, then check.
- Page setups (fakes, provider overrides, worlds) live in `test/helpers/`
  and are shared with the page's own tests — move them there, never copy
  them into the matrix.
- Detector exemptions are structural, never per language: a `FitLabel` in
  the compact profile; the scale check inside an `InputDecorator` (the
  floating label shrinks to 0.75 by the Material spec — truncation is still
  checked). A layout error's report lists every `Row`/`Column` whose
  children run past their box, with its ancestors.
- The matrix cannot see misalignment or unbalanced spacing. After fixing a
  page family, render temporary goldens of it and look at them; do not
  commit them.

### 6. Tests required

- `harness_test.dart`: glyph widths per script; the detector catches cut,
  clipped, overflowing and over-shrunk UI text and ignores user content.
- `fit_label_test.dart`, `func_bottom_nav_test.dart`: measured width equals painted width; the
  scale never drops below 0.8; truncation brings the tooltip.
- `compact_controls_test.dart`, `settings_layout_test.dart`,
  `entry_layout_test.dart`, `content_layout_test.dart`,
  `lists_layout_test.dart`, `sheets_layout_test.dart`: every cell green, no
  skipped cells.

### 7. Wrong vs Correct

#### Wrong

```dart
Row(children: [
  Expanded(child: Text(l10n.searchTrending)),
  OutlinedButton(...),                // unbounded in a Row: overflows in ru
]);
FittedBox(child: Text(l10n.follow));  // shrinks to 0.5 in long locales
Text(l10n.illustDetailCreateDate(date), overflow: TextOverflow.ellipsis);
```

#### Correct

```dart
Wrap(                                 // the button drops under the title
  alignment: WrapAlignment.spaceBetween,
  crossAxisAlignment: WrapCrossAlignment.center,
  children: [Text(l10n.searchTrending), OutlinedButton(...)],
);
FitLabel(l10n.follow, fit: fit);      // one shared scale, floor 0.8
Text(l10n.illustDetailCreateDate(date)); // wraps
```

## Profile Header Contract

`ReplicaProfileHeaderDelegate`
(`lib/features/profile/profile_header_delegate.dart`) owns the profile
page's flexible header.

**Measured extent.** `maxExtent` is never hard-coded for text-bearing
content. The identity block (banner spacer, name row, statistics line)
lays out at natural height inside an
`OverflowBox`, and the `_ReportSize` render object reports its height in
a post-frame callback; the host stores the value as `expandedExtent`, so
width, locale, and text-scale changes re-size the header without code
changes. Until the first report arrives the delegate renders one
transparent frame at `initialExtentEstimate` (360dp) — the correction is
never a visible jump. The identity subtree stays mounted (`Offstage`)
through collapse so measurement keeps reporting.

**Geometry.** The banner band is `topInset + kToolbarHeight + 80dp`; the
80dp avatar is left-aligned (`FuncSpacing.lg` inset) and centred on the
banner's bottom edge. Banner and identity translate by `-shrinkOffset`
one-to-one. The toolbar surface fades in over `toolbarFadeDistance`
(`FuncSpacing.xl`) as the banner's bottom edge leaves the toolbar, and
the centred toolbar title mounts only at full collapse. Identity content
is laid out inside `ClipRect` bounded to `top: minExtent, bottom: 0`, so
it never enters the toolbar band.

**Persistent controls.** Back and overflow live on a topmost layer at
`topInset + 4` and stay mounted — and tappable — through the whole
collapse interval, including the fade hand-off between expanded and
collapsed chrome. While real cover artwork still sits behind the toolbar
(`hasCover && geometry.bannerBehindToolbar`), the back button is an
`ImageOverlayButton` and the overflow `AppMenuButton` applies
`ImageOverlayButton.buttonStyle()`; collapsed or cover-less, both are
plain surface icons with no fill. The whole header is wrapped in
`FuncSystemBars(background: overArtwork ? Brightness.dark :
theme.brightness)`, so the status bar paints light icons over artwork
only and restores the root default otherwise.

**Name row.** Below the avatar's lower half: the name (`titleLarge` w700,
one line, ellipsized) over `@account`, then on the same row the share
`IconButton` and the main action — `FollowSwitchButton` on another user's
page, a tonal "edit profile" button on your own. The main action is
capped at 45% of the row, so at 320dp and 1.3x text the name ellipsizes
before anything wraps.

**Statistics line.** `ProfileStatLine` (`profile_statistics.dart`) under
the name row: "N following · N My Pixiv" (`profileFollowingCount`,
`profileMyPixivCount`, counts through `AppFormat.count`). Each stat is
its own text link, at least 48dp tall, one semantics node labelled with
its text; following opens the following tab, My Pixiv opens its tab on
your own page and is plain text elsewhere (another user's My Pixiv list
has no tab). A preview snapshot without detail counters shows no line
rather than zeros. On a narrow screen the line wraps. Work totals sit
above their lists (see Tabs); the about tab lists every count
(`ProfileStatistic` rows).

**Tabs.** `UserPage` builds one tab per work type the user has — illust,
manga, novel, series, each only when its count is above zero — labelled
with the name alone. A count would widen the labels past an equal share
of the row (five zh tabs fit 360dp only without them) and flip the row
to scrolling once the detail loads; each work list instead starts with
its total ("共 N 件", `profileWorksTotal`, `AppFormat.count`), fixed
above the list in the slot your own bookmarks and follows use for their
filters, and absent from a preview snapshot. In ja, en and ru the labels
are wider than an equal share at 360dp, so the row scrolls there (the
`AppTabBar` rule). Series counts illust series only: the series tab lists
`/v1/user/illust-series`, and no endpoint lists a user's novel series.
Another user's page puts the work tabs first, then bookmarks, following,
about; your own keeps bookmarks, following, fans, My Pixiv first and the
work tabs last. A preview snapshot without counters keeps all four work
tabs. The tab controller is rebuilt when the set of tabs
changes on refresh; the selected tab stays selected if it survives,
otherwise the first tab is selected. `ReplicaProfileTabsDelegate` takes
the labels and is a constant 56dp `AppTabBar`.

**Filters.** On your own page the bookmarks and following lists carry
`ProfileFilterBar` fixed above the list: a visibility `FilterMenuButton`
(public/private, shared by both lists) and, for bookmarks, a tag filter
("Tag: All ▾") listing all bookmarks plus your first ten illust bookmark
tags; when there are more (or the list has not loaded) a last "More
tags…" entry opens the bookmark tag page. The tag filters the profile
feed in place (`ProfileFeedKey.bookmarkTag`); a visibility change clears
it. The overflow menu no longer carries visibility or bookmark tags —
only share, edit, bulk download and copy link.

**Tests Required** (`test/user_profile_test.dart`):

- R1, both conditions — 360×640 / `textScaler` 2.0 / `ru` and 411×891 /
  1.0 / `zh`: no layout exceptions; every action and statistic rect ends
  at or above the tab bar's top edge; the measured extent tracks
  refreshed identity content; a drag collapse/expand changes the header
  height monotonically with no jumps.
- Name row at 320dp / 1.3x for both pages: the long name ellipsizes, share
  and the main action stay on its row, the statistics line sits below.
- Tabs: only types with works, labelled without counts, each work list
  showing its total and the other lists none; five zh tabs (yours and
  another user's) share 360dp evenly; no works opens on the first other
  tab; a tab that disappears on refresh falls back to the first.
- Stats: following opens its tab with a 48dp target; another user's My
  Pixiv is no button. `profile_statistics_test.dart` covers the line on
  its own (one line, semantics, wrapping).
- Filters: visible on your own bookmarks and follows only, menus filter
  the feed, a visibility change clears the tag, more than ten tags add the
  tag-page entry; the overflow menu lists no filters.
- R6: `SystemChrome.latestStyle` reads `statusBarIconBrightness ==
  Brightness.light` while a cover is expanded, and the root default
  (`dark` under the light theme) once collapsed or without a cover.

## Menus and Modal Barriers Contract

Overflow and choice menus use `AppMenuButton` /
`AppMenuEntry` (`lib/app/widgets/app_menu_button.dart`), never
`PopupMenuButton`. It is a `MenuAnchor` with `consumeOutsideTap: true`:
a pointer going down anywhere outside closes the menu and that touch is
consumed — the page below neither scrolls nor taps. A `PopScope` with
`canPop: !open` makes back close the menu before the page. Entries carry
an optional icon, `enabled`, `checked` (non-null renders a trailing
check and checked semantics) and `destructive` (label and icon in the
`danger` color — delete and other irreversible actions, which still
confirm before acting); `onSelected` receives the anchor's context;
`style` forwards to the default `IconButton` (over-artwork palette);
`anchorBuilder` replaces the anchor (the reverse-image engine chip).
The menu opens below its anchor, lined up with the anchor's end edge
(`edge: AppMenuEdge.end`, the default — M3 for ⋮ buttons and values at
the end of a row); a dropdown at the start of a row (`FilterMenuButton`)
passes `AppMenuEdge.start`. `MenuAnchor` itself only lines up start
edges and the menu's width is known only at layout, so the end edge is
the start edge of a `MenuAnchor` laid out in the mirrored direction; the
anchor and the items are wrapped back in the ambient direction. The
panel is width-capped at `kAppMenuMaxWidth` with
`crossAxisUnconstrained: false` — the default lets the panel grow past
the cap and clip long labels instead of truncating them. Menu items have
no `isButton` flag off the web (framework behaviour); tests assert the
tap action and checked state instead. Reduced motion turns off the
open animation.

Dialogs and bottom sheets go through `showAppDialog` /
`showAppBottomSheet`, which push `DialogRoute` / `ModalBottomSheetRoute`
subclasses mirroring `showDialog` / `showModalBottomSheet`'s own
construction and override only `buildModalBarrier()`. The barrier closes
the route when a touch that started on the scrim is released on the
scrim — a tap or a drag alike, like a native Android dialog. It decides
"released on the scrim" by hit-testing the release position: over the
route's content the barrier is not in the hit path. It replaces the stock
barrier instead of wrapping it, because the stock tap recognizer would
pop on the same release and a second pop would close the page below; the
route only pops itself while `isCurrent`. A non-dismissible barrier stays
opaque and silent. Semantics match `ModalBarrier` (label, tap and dismiss
actions where the platform supports dismissing a barrier, `BlockSemantics`).

A row's secondary actions open from an `AppMenuButton` on the row, not a
bottom sheet with one entry (the local novels row: Delete, still
confirmed). The card long-press sheet (`showCardActionSheet`) names its
subject: a header with a 48dp thumbnail, the title and the author, read
as one heading, and the whole sheet labelled with the title. A work the
card shows blurred keeps its thumbnail hidden in the header. The sheet is
`isScrollControlled` so every action fits without the default 9/16 cap.

**Each action appears once at a time.** A menu or sheet lists only what is
not already on screen; when a visible control and a menu entry would do
the same thing, the visible one stays and the entry goes.

- The profile header's ⋮ adds share and the main action (edit profile or
  follow) only once the name row starts sliding under the toolbar
  (`ReplicaProfileHeaderGeometry.nameRowUnderToolbar`). Until then they
  are only the inline buttons.
- The card long-press sheet has no bookmark entry: every `IllustCard`
  carries its heart.
- A download row opens its work on tap and has no View button. A group
  header offers View only when every item is a page of one work.

Owning tests: `app_menu_button_test.dart` (outside press closes, no
scroll or tap passes through, back closes the menu first, checked and
disabled rows, reduced motion, 320-wide ru truncation, end and start
edge alignment in LTR and RTL with the anchor and items unmirrored) and
`app_overlays_test.dart` (drag-release closes one layer, release over the
content keeps it open, non-dismissible stays, scrim dismiss action).

## Prompt Feedback Contract

Transient messages have one surface: `PromptHost`
(`lib/app/widgets/prompt_host.dart`), installed once in `MaterialApp.builder`
above every navigator, below `MotionScope` and `TouchExplorationScope`.
Callers use `showAppSnackBar(context, message, {duration, action,
replaceCurrent})` with an optional `PromptAction(label:, onPressed:)`.
material_ui's `SnackBar`, `SnackBarAction`, `showSnackBar` and
`ScaffoldMessenger` do not appear in `lib/` — that path reads the polluted
engine flag and anchors to Scaffold geometry the floating shell bar does
not have. Direct host access (`PromptHost.of`, `PromptHostState`) is pinned
to `app_snack_bar.dart`, `undo_snack_bar.dart` and `app.dart` (the update
prompt, through `_promptHostKey`); `feedback_channels_test.dart` enforces
both.

- **Queue.** An ordinary new message drops queued ones, lets the current
  one play its exit, then shows. Ordered steps pass `replaceCurrent:
  false`; for example, the account-transfer clipboard warning follows its
  copy confirmation.
- **Lifetime.** A prompt belongs to the host, not the page: it survives
  push, pop and branch switches, like a Snackbar belongs to the Activity.
- **Dwell.** The timer starts when the entrance completes. The base
  duration (4s, the update prompt 8s) goes through
  `AppAccessibility.recommendedTimeoutMillis` (`getRecommendedTimeoutMillis`
  with TEXT, plus CONTROLS for an action); a longer answer extends the
  dwell. An action pins the prompt only under touch exploration (the
  rewritten `accessibleNavigation`) — the MDC rule. Every other prompt,
  action or not, times out.
- **Placement.** Centered, at most 600 wide, 16 from the sides, resting 16
  above the tallest of: the anchored chrome, the bottom safe area, the
  keyboard. Chrome registers itself with `PromptAnchor(extent:)`; the
  extent is read live, and its contribution follows the enclosing route —
  it rises with the route's entrance and sinks while a page route covers
  it (sheets and dialogs do not drive `secondaryAnimation`). The shell bar
  anchors with its live visible extent, so prompts ride along as it
  slides.
- **Motion.** Compose M3 entrance: 150ms linear fade plus 0.8→1
  fast-out-slow-in scale (`MotionTokens.promptEnter`); the exit reverses
  both over `MotionTokens.fast`. Instant under touch exploration or a
  closed motion gate.
- **Modals.** The host paints above the navigators, so the app's sheet and
  dialog routes wrap their barrier in `PromptCover`: the prompt fades out
  with the modal's entrance, takes no pointer while covered, and returns as
  the modal leaves.
- **Dismissal.** Swipe down, the semantics dismiss action, the action
  button (fires once), timeout, or replacement. The card is a live region.

Widget tests install the host with `promptHostBuilder`
(`test/helpers/prompt_host.dart`); `PromptHost.of` throws without one, so a
missing host fails the test instead of dropping the prompt. Find the card
with `shownPrompt` / `promptCard(message)` and the button with
`promptAction(label)`. The platform timeout channel is the external
boundary to fake (`prompt_host_test.dart`).

A reversible action reports through `showUndoSnackBar` (see the Undo
Contract), never through a plain message plus a hand-built
`SnackBarAction`.

## Undo Contract

Reversible actions run immediately and offer Undo; only irreversible ones
(deleting an imported file, clearing history) ask for confirmation first.
Unfollow, unbookmark, unmute and watch-later removal have no confirmation
dialog. Unbookmark offers no Undo prompt either (user decision 2026-10-08,
as in Shaft): the heart is the feedback, and tapping it again is the undo.

- `showUndoSnackBar(context, message, onUndo:)`
  (`lib/app/widgets/undo_snack_bar.dart`) captures the
  `ProviderContainer`, the prompt host and the localizations when it
  shows. Undo plays `AppHaptics.select()` and runs `onUndo(container)`, so
  it still works after the page that offered it is gone. A failed undo is
  recorded in `CrashLog` and reported on the captured host.
- Bookmarks and follows go through `toggleBookmark(context, key)` and
  `toggleFollowWithUndo(context, userId)` — the only UI entry points to
  `bookmarkActionsProvider.toggle` / `followActionsProvider.toggle`.
  The follow action returns what a delete removed (`RemovedFollow` with
  restrict); Undo re-adds through `addWithRestrict`. The bookmark action
  keeps what a delete removed (`RemovedBookmark` with restrict and tags)
  per work, for the account that removed it (session memory, 100 works),
  and the next add of that work restores it; a sheet add drops it.
- The snapshot is exact or absent. A bookmark entry is trusted only right
  after an add confirmed in this session (`status == confirmed`): remote
  observations carry visibility but never tags. Otherwise the action reads
  `fetchDetail` (registered tags only) before the delete; a follow with an
  unknown restrict reads `FollowRepository.fetchRestrict`
  (`/v1/user/follow/detail`). When the lookup fails, the delete still
  goes ahead and no Undo is offered (a bookmark re-add is then public) —
  never guess "public" for a restore: restoring a private bookmark or
  follow as public would expose it. A queued (offline) or failed delete
  offers no Undo either.
- Unmute offers Undo through `showUnmuteUndo(context, MuteKey, user:)`.
  The mute store only toggles, so Undo skips an entry that is muted again
  by then.

Owning tests: `bookmark_actions_test.dart`, `follow_actions_test.dart`
(local snapshot, lookup, failed lookup), `undo_flows_test.dart` (private
and tagged restores, a bookmark through the heart, Undo after the page
closed, no Undo without the original visibility), `muted_items_page_test.dart` and
`card_action_test.dart` (unmute Undo).

## Route Restoration Contract

`MaterialApp.router`, `GoRouter`, the shell, and each branch use stable
restoration scope IDs. Feed scrollables use their stable `PageStorageKey` and
`restorationId`; the key preserves in-process tab/mode switching and the
restoration ID covers the Flutter restoration bucket.

Ranking mode and date, search input/filter/result type, and viewer page are
durable path/query values and are updated through the route facade. An entity or input passed as
route `extra` accelerates the first frame but is not the restoration source.
The router instance stays stable while settings, account, or providers update.

## Stack Integrity Contract

The router has five branch roots (`/recommended`, `/ranking`, `/new`,
`/search`, `/settings`) and app-level overlay roots (`/me`, `/reverse-image`,
`/downloads`). Content opened from a page stays under that page's current
stack; switching branches is reserved for the shell's bottom bar or side
navigation. Route facades use `_push` with a debug assertion that a branch
push remains in the current branch, while overlay routes may be opened from
any stack.

The image viewer may open only overlay destinations. A viewer action that
returns to the work detail closes the viewer rather than pushing a second
detail page. Feedback actions that outlive their page bind the router while
the message is shown, instead of reading a disposed page context later.

A page that can be the only route on the stack (a direct link, a gate
redirect) passes `ReplicaScaffold(upLocation:)`: with nothing to pop it
still shows the back button, and back — button or system — goes there
instead of leaving the app. The user agreement leads to `/login`.

## Predictive Back Contract

The Android application enables `android:enableOnBackInvokedCallback`. Pages
use `PopScope.onPopInvokedWithResult`; `WillPopScope` is not part of the app
route model. go_router first pops the current branch stack. At a branch
root, `HomePage`'s `PopScope` decides from the active branch: the
Recommended root (`currentIndex == 0` and the shell URI at `/recommended`)
reports `canPop: true` and hands the back event to the system — on Android
that leaves the app. Every other branch root claims the back event and
returns to Recommended via `goBranch(0)`. There is no double-tap exit
window.

`FuncPage<T>` (`lib/app/navigation/func_page.dart`) is the page behind every
`_page` route. It is a hand-rolled `Page` because the predictive-back builder's
`buildTransitions` needs the `PageRoute` itself — a `CustomTransitionPage`
`transitionsBuilder` closure never receives it. `_page` passes the scoped
`MotionScope.transitionStyleOf(context)` into `FuncPage.transitionStyle`
(Me → Motion & haptics → Page transition, persisted as
`pageTransitionStyle`),
and `_FuncPageRoute.buildTransitions` switches on it:

| Style | Android | Other platforms |
|---|---|---|
| `system` (default) | `PredictiveBackPageTransitionsBuilder` (FadeForwards for button pops, the shared-element predictive transition while `popGestureInProgress`) | `FuncRouteTransition` trailing-edge slide |
| `slide` | `CupertinoPageTransition` (`linearTransition: popGestureInProgress`) + back-gesture driver | same, no driver |

Every style uses an official transition; none is hand-written. The slide
uses the `CupertinoPageTransition` widget, never
`CupertinoPageTransitionsBuilder`: the builder adds an iOS edge-swipe back
detector that steals horizontal drags from in-page pagers (the detail
pager). Under the slide the route's `barrierColor` is `CupertinoPageRoute`'s
`0x18000000`, dimming the page below; other styles keep the page's own
(null). Only these two are offered (user decision 2026-10-08): shared axis
and zoom were dropped, and a stored `sharedAxis`/`zoom` reads as unknown
and falls back to `system`. Fade-through is not offered: it is the
transition between unrelated destinations, not for pushing a page.

The back-gesture driver (`_BackGestureDriver`) is a
`WidgetsBindingObserver` that forwards the Android predictive back events
to the route's `handleStartBackGesture(progress: 1 - event.progress)` /
update / cancel / commit, so the slide follows the finger. It
claims the gesture only for a non-button event while `route.isCurrent &&
route.popGestureEnabled`; the binding then sends the rest of that gesture
to it alone. It mirrors Material's private predictive-back detector
without its visuals — a framework change there shows up in
`func_page_test.dart`'s gesture tests.

The route's commit path is guarded: if a pop throws after the route has
already reported `didPop`, the guard ends any lingering user gesture before
rethrowing. This keeps the Navigator from absorbing later pointers while
leaving the original error observable.
`transitionDuration` is each style's own spec duration,
`MotionTokens.pageTransitionOf(style, android:)`: FadeForwards' 450 ms
(`FadeForwardsPageTransitionsBuilder.kTransitionMilliseconds`) for the
Android system style, `CupertinoPageRoute`'s 500 ms for the slide, and
`MotionTokens.pageTransition` (300 ms) for `FuncRouteTransition` elsewhere —
all through `MotionTokens.resolve`, so the animation speed setting scales
them and reduced motion collapses them to zero (see the Motion Contract).
Each style brings its own curve, and Hero flights follow the route
duration. Every path is wrapped by
`FuncTransitionGuard` — the shared `RoutePopSnapshot` mount that snapshots
by transition role: entering and covered pages paint live (their tickers
are never paused by the transition; a fully covered route is offstaged by
the Overlay instead), while a popping page and a settled reveal blit one
texture each;
`FuncRouteTransition` already carries the guard internally, so the other
paths add it around the official transition. `_modalPage` stays on
`CustomTransitionPage`; `maintainState`/`opaque`/`barrierColor` keep
`CustomTransitionPage`'s defaults.

Only the visible route may take the gesture. Each home-shell branch Navigator
keeps an `isCurrent` route alive while parked a page-width offstage, and
Flutter hands the gesture to the last-registered `popGestureEnabled` route —
without a gate a hidden branch pops a page the user cannot see.
`HomeBranchStack` wraps every branch in `BranchActivityScope` (`active` =
the branch is settled as the current index AND the enclosing route — a
root-level page above the shell — is current or absent).
`_FuncPageRoute.popGestureEnabled` returns `super.popGestureEnabled &&
BranchActivityScope.maybeOf(navigator.context)?.active ?? true`; it reads the
scope non-dependently because the getter runs outside build. Routes outside
the shell (root Navigator, any inner Navigator) see no scope and fall through
to `?? true`.

During a gesture back, Heroes do not fly back (`transitionOnUserGestures`
stays false): the predictive transition shrinks the whole page but the Hero
flight start rect is measured at gesture start, so the flight cannot track
the shrinking page — the detail page fades out and the card is simply there.
Button pops and `DragToDismiss` still fly Heroes as before.

Pages with local edit state, such as `ProfileEditPage`, keep their
`canPop`/confirmation behavior in their own `PopScope`. A dirty page reports
`popDisposition != pop`, so `popGestureEnabled` is false and the gesture
never starts; the back *button* still routes through `PopScope` and shows the
discard confirmation. Navigation changes must not bypass that confirmation or
reset the branch stack.

An immersive page restores the system bars on the *successful* pop path:
`onPopInvokedWithResult` fires with `didPop == true`, so the novel reader
calls `setSystemUiMode(SystemUiMode.edgeToEdge)` there — the previous route
needs its status bar while the pop animation is still on screen — and again
in `dispose` as the fallback for pop paths that never notify.

## Hero Drag Contract

`DragToDismiss` is shared by the still image viewer and Ugoira surface. It
accepts a downward drag while the still viewer is at 1x, translates/scales/
fades the surface with the drag, and returns on the spatialFast spring,
starting at the release velocity, when the drag is canceled or below
threshold. A qualifying drag pops the current typed
route so the existing `FuncPage`, scoped Hero tag, and
`HeroRectClip` perform the reverse flight.

Only the page the viewer opened on (`ImageViewerRouteExtra.entryPage`)
carries the Hero. After a page turn the viewer has no Hero, and any pop
(back button, system back, drag) slides the stage down from wherever the pop
begins instead of shrinking an image into a spot that shows a different
page.

The detail page builds its image pages as one `SliverList` whatever the page
count. A sliver whose type depends on the snapshot's page count rebuilds the
landing Hero when the detail payload disagrees with the snapshot (a restored
feed), and the orphaned endpoint then paints under the flight.

Chrome over artwork stays readable over a white page: the viewer's bars sit on
an `imageControl` → transparent gradient that takes no taps, and the page
position is one `PageCountPill` on both the detail page and the viewer. The
detail pill fades in and out and never hard-cuts.

Horizontal page changes and zoomed `InteractiveViewer` pan remain with the
viewer. The card does not await image preload before route navigation, and
Hero scopes remain stable per mounted feed surface. Ugoira playback, tap,
long-press, and lifecycle ownership stay with the Ugoira page.

For the full artwork URL, Hero scope, global clip, and preload contract, see
[Artwork Detail Transition Contract](#artwork-detail-transition-contract).

The release artifact and APK size gate live in
[backend/release-artifacts.md](../backend/release-artifacts.md).

## Artwork Detail Transition Contract

### 1. Scope / Trigger

This contract applies whenever an illustration card opens
`IllustDetailPage`. It prevents a work with the same Pixiv ID in two mounted
surfaces from being treated as the same Hero transition.

### 2. Signatures

```dart
const IllustCard({
  required IllustEntity entity,
  String heroScope = 'feed',
});

const IllustDetailPage({
  required int illustId,
  IllustEntity? initialEntity,
  String heroScope = 'feed',
});

String illustHeroTag(String scope, int illustId);

Future<ImagePreloadResult> PixivImage.preload(
  BuildContext context,
  String url, {
  String? tierKey,
  IllustImageTier? tier,
  int? memCacheWidth,
  ImageFetchPriority priority = ImageFetchPriority.background,
});
```

### 3. Contracts

- A list chooses one stable, code-defined scope for its surface. The card and
  the detail route it opens use the same scope and integer work ID.
- Independent mounted surfaces use different scopes (`recommended`,
  `ranking`, `new`, `search`, and a profile feed key).
- `initialEntity` is the card snapshot used to build the first detail frame;
  the detail request may refresh the shared store after navigation.
- A detail route without a matching source Hero uses the normal page route; it
  must not create a synthetic source or wait for the request before navigating.
- The source card passes its selected preview URL to the detail route. Both
  sides load it through the same image worker, including the first page of
  a multi-page work.
- All artwork URL/quality hand-offs go through `PixivImage`; callers must not
  add a second per-page "ready" flag or replace the old image with a blank
  loading state. `PixivImage` keeps OctoImage's `gaplessPlayback` enabled and
  uses a bounded `transitionKey` URL history for Hero endpoints that are rebuilt
  while flying. The previous decoded frame remains visible while the new
  quality resolves, including preview/detail/original changes, every page of
  a multi-page work, and Ugoira covers.
- The load transition is Glide's default crossfade as Shaft uses it:
  300 ms, linear (`MotionTokens.imageFade` / `imageFadeCurve`). OctoImage
  stacks the placeholder over the image, so the image paints at once
  (`fadeInDuration: zero`) and the placeholder dissolves off it — over an
  opaque image the same composite as Glide's placeholder kept under an
  incoming image. Fading both layers at once let the page show through
  mid-fade (the grey dip).
- The normal loading fade is still required for a cold URL. It is disabled
  only when the target provider is already decoded; a cached Hero target must
  appear immediately rather than fading a translucent frame over the route
  background. This is the distinction between a useful first-load transition
  and the white flash regression.
- A feed slot being reused for a different work is a **slot hand-off**, not a
  cold load: `PixivImage` tracks the URL each element last committed to, and
  a changed URL on a live element drops the fade to zero — OctoImage's
  `gaplessPlayback` retains the old frame and the new one replaces it
  instantly (Glide semantics). Fading work B in over retained work A reads as
  a cross-work dissolve across the whole refreshed grid. Feed cards therefore
  carry a `ValueKey` scoped by feed + work id (`illust-<scope>-<id>`,
  `novel-<id>`) so the element follows the work on refresh rather than being
  recycled by index.
- Pixiv Premium gates `sort=popular_desc` server-side: the app API silently
  ignores it for free accounts. `SearchFilters` therefore resolves `duration`
  presets client-side into `start_date`/`end_date` (never sends
  `within_last_*`), the sheet keeps duration and custom dates mutually
  exclusive with a `start > end` guard, and the search repository reroutes
  non-premium popular sorts to the `/v1/search/popular-preview/*` endpoints
  (which reject a `sort` parameter). `Account.isPremium` comes from the OAuth
  `user.is_premium` field and persists in account metadata JSON.
- Search filters are typed: sealed `SearchFilters` splits into
  `IllustSearchFilters` (ratio/content-type/pixel bounds) and
  `NovelSearchFilters` (`text_length_*`, `is_original_only`, `text`/`keyword`
  targets); each type only offers, sends and displays its own dimensions —
  decode clamps a foreign `target` into the type's options rather than
  letting it reach the wire or a label. Persisted defaults are two sets
  (`searchIllustFilters`/`searchNovelFilters` in `AppSettings`, read through
  `searchIllustFiltersProvider`/`searchNovelFiltersProvider`; a pre-split
  `searchFilters` blob seeds both once), edited explicitly via the result
  page's "设为默认". The input and result pages keep per-type session
  drafts seeded from those defaults — the URL describes only the current
  tab's set, and a user query carries none.
- A min/max bound pair is checked where the user sees it, never fixed
  behind their back. The sheet's number fields take digits only (at most
  9), so the text shown is the bound applied; a reversed pair shows
  `searchInvalidBoundRange` under its row and disables Apply and "设为默认",
  as `start > end` does for dates. `toQuery` throws `FormatException` on a
  reversed pair instead of swapping it — the client-side bookmark predicate
  reads the same pair, so a wire-only swap would filter every result out.
  Stored settings and result URLs decode through
  `SearchFilters.decodeBounds`: negatives are dropped and a reversed pair
  (earlier sheets saved them) is put in order. Owning tests:
  `search_models_test.dart`, `search_catalog_test.dart`.
- Search chrome: the input page, the result page and the guide put the
  field in one place (back, field, `SearchFilterButton`), so the field reads
  as the same one across pushes; `SearchFieldButton` draws its icon and text
  where `SearchBar` does. The filter button's badge counts
  `searchFilterLabels` — the same list the result page shows as chips under
  the tabs, a row that exists only while a filter is active. The filter
  sheet opens below the status bar, scrolls its groups (match, time, work,
  counts) between a fixed header (title, reset) and a fixed action bar that
  rides above the IME; "设为默认" sits beside Apply and stacks above it when
  its label does not fit half the bar. Owning tests:
  `search_result_page_test.dart`, `search_catalog_test.dart`.
- The input page starts empty-field users on recent searches
  (`searchHistoryProvider`, 20, newest first; removal is undoable, clearing
  all confirms) and the type's trending tags. A suggestion, recent search or
  trending tag searches on tap and fills the field on long press. A bare id
  or a pixiv link (`searchShortcutFor`) opens the work or user directly —
  `openSearchResults` checks it, so every submit path agrees — and is never
  recorded. Owning test: `search_input_test.dart`.
- Detail pages size multi-page images by each decoded frame's intrinsic
  ratio — never by a fixed `AspectRatio` on the container. The app API's
  `meta_pages[]` carries only `image_urls` (no per-page width/height), so
  `pageAspectRatioAt` falls back to the work-level (= first page) ratio and
  letterboxes every non-matching page. Estimated-ratio boxes are placeholder
  real estate only: the slot must hold an estimated box until the decode
  lands, then let the real dimensions take over.
- The decoded image cache must survive backgrounding: Android posts
  TRIM_MEMORY_UI_HIDDEN on every hide and the stock binding answers it with
  `imageCache.clear()`, which re-fades every artwork on resume. The app's
  `WidgetsFlutterBinding` subclass keeps decoded frames and only clears live
  streams + `rootBundle`.
- A card may call `PixivImage.preload` on pointer down, but must not await it
  before pushing the detail route. The detail frame creates a fixed-size
  avatar provider immediately; a cold avatar may fill after the transition.
- Hero shuttles keep their rounded image child through the whole flight. Both
  push and pop directions use a **progress-aware global clip** interpolated
  between the source and destination viewport/chrome boundaries. This makes
  artwork progressively leave or enter behind AppBars, pinned headers,
  refresh chrome, and bottom navigation instead of suddenly covering them or
  being hard-cut at the landing frame. Ignore horizontal route-slide
  transforms when building the boundary; otherwise the two viewports can
  intersect to an empty rectangle. If an endpoint is temporarily offstage,
  use a conservative Scaffold/chrome fallback rather than returning an empty
  clip.
- Feed cards draw no outline. `IllustHeroCardFrame` wraps the card's Hero
  child as a `ClipRRect` at `FuncShape.card` only; the shuttle interpolates
  that radius towards the detail side's. The frame must live **inside** the
  Hero child: a clip outside the Hero only applies after the flight lands,
  so the image snaps from square to rounded on pop.
- Feed card layout (`illustCardPreview` in `illust_card_layout.dart`): the
  preview follows the work's aspect ratio up to 1:2 (`fitWidth`, the
  user's preview tier). A taller work keeps a 1:2 card and shows the top of
  `large` (`cover`, top-aligned) while `large`'s pixel width is at least
  80% of the card's physical width; a narrower one shows a square card from
  the square thumbnail (the 540 px resize, or the uncropped `square1200`
  for wider cards) and opens without a Hero, since that image is not the
  detail page's. A top-cropped card hands `cropAspect` (the work's
  width/height) to its frame, and the shuttle lerps the child from the
  card's cover-top rect to the whole contained image, both directions.
  There is no feed prefetch: the grid's cache extent builds cards ahead and
  each card's image loads as it mounts. Cards have no entrance of their
  own: they land in place, as in Shaft (its lists run without an item
  animator), and only the image fades in.
- Detail page page numbers use only `DetailPageCounter`. Narrow and wide
  layouts both place it at the top-right of the artwork region; single-page
  and ugoira works never show it; selection mode hides it because each
  page's selection badge takes the same corner; it appears only after the
  entry transition completes; it is wrapped in `IgnorePointer`; and its
  screen-reader label uses `viewerPageLabel`. The detail page keeps no
  persistent information strip.
- Download-all, comments and the bookmark heart sit in the floating
  `DetailActionBar` (see the Artwork Detail Layout Contract); the detail
  AppBar carries only the ⋮ menu. Share, page selection, and artwork-info
  navigation live in that ⋮ overflow menu with text labels; no action may depend solely on a long
  press. Artwork-info navigation must reach the lazily built InfoBlock in
  long works.
- Related works load on demand. Opening a detail page sends no
  `/v2/illust/related` request. `RelatedIllustsSlivers` asks for the first
  page only once its section is on screen (`VisibilityDetector`) **and**
  the page is current (`DetailPageActivity`). The detail pager prebuilds
  its neighbours and sets that scope to inactive on every page except the
  one the user is reading: the committed page once it has stayed settled
  for `IllustDetailPagerPage.activeDwell` (300 ms), tracked by work id —
  a page swiped through sends nothing. `HeroMode` still follows the
  committed page at once. A route outside the pager has no scope and
  counts as active. Before the request, the section shows a **static** box the size
  of the loading spinner: a spinner below the fold keeps producing frames.
  A related list whose provider already exists (`ref.exists`) renders
  straight away. The detail page's scroll-to-bottom paging check may call
  `loadMore` only on an existing, loaded provider. It must never send the
  first request.
- A pager page outside the build window paints the work's image where the
  detail draws it (full width, top) from a decode the feed already made
  (`PixivImage.decodedStandIn`), never a load; a bare surface when none
  exists and in the two-pane layout. `findChildIndexCallback` maps pages by
  work id, so a list shift moves built pages instead of rebuilding them as
  other works.

### 4. Validation & Error Matrix

| Condition | Required behavior |
| --- | --- |
| Card and detail scopes match | Image Hero may participate in the transition. |
| Same work ID appears in another surface | Different tag, so no cross-surface flight. |
| No source card or no snapshot | Normal route/loading state remains observable. |
| API refresh fails with a snapshot | Snapshot content remains renderable and retry stays available. |
| Current profile is rendered | No settings icon or `onSettings` navigation hook is present. |
| Initial preview URL differs between card and detail | Correct the route input; do not let the Hero start with a placeholder or a different first-frame URL. Later detail-quality upgrades use the gapless hand-off contract above. |
| Avatar cache misses during navigation | Keep the same 48px slot and placeholder; never delay the route push. |

### 5. Good / Base / Bad Cases

- Good: `IllustCard(heroScope: 'profile:42:bookmarks:illust:public')` opens a
  detail route with the same scope and `initialEntity`.
- Base: history/deep-link routes keep the default scope and no initial entity;
  Flutter performs the ordinary slide transition.
- Bad: every list uses `IllustHero-<id>`, allowing a newly bookmarked work in
  a profile list to match a mounted feed card.

### 6. Tests Required

- A first-frame detail widget test passes an entity snapshot and asserts the
  title, author, and scoped Hero exist before the request settles.
- Profile header tests assert `Icons.settings_outlined` is absent in expanded
  and collapsed states.
- Settings account-card tests assert exactly one profile push and no settings
  icon on the resulting `MePage`.
- Caption tests assert non-empty captions are visible without a `简介`
  control and preserve rich-link behavior (the collapse rules are in the
  Artwork Detail Layout Contract).
- Hero flight tests cover a partially visible card, a nested pinned header, and
  a push from a profile-like feed; both directions must move the global clip
  continuously between endpoint chrome boundaries. Tests must inspect the
  actual render-time clip rather than only a widget property.
- Preview tests assert the source URL and detail index-0 Hero URL are equal;
  first-frame tests assert the avatar slot and provider exist before the detail
  request settles.
- Detail counter tests assert a single-page work shows no page number, the
  multi-page counter follows scrolling (a manga work, so every page is
  shown) and hides once scrolling reaches the InfoBlock, and a six-page
  long work reaches the InfoBlock through the ⋮ menu.

### 7. Wrong vs Correct

Wrong:

```dart
Hero(tag: 'IllustHero-${entity.id}', child: image);
IllustDetailPage(illustId: entity.id);
```

Correct:

```dart
final tag = illustHeroTag(heroScope, entity.id);
Hero(tag: tag, child: image);
IllustDetailPage(
  illustId: entity.id,
  initialEntity: entity,
  heroScope: heroScope,
);
```

For image timing, keep the shared boundary small:

```dart
onTapDown: (_) => unawaited(
  PixivImage.preload(context, previewUrl, cacheManager: cacheManager),
);
onTap: () => Navigator.push(detailRoute); // do not await the preload
```

## Artwork Detail Layout Contract

### 1. Info block

`InfoBlock` (`lib/features/illust/detail/widgets/info_block.dart`) runs
top to bottom:

1. Title: selectable `titleLarge`, no line cap.
2. Posting date (`illust-detail-date`), `AppFormat.date` in the metadata
   style; absent when the payload has no date.
3. Stats block (`illust-detail-stats`): views and bookmarks, as
   `headlineSmall` w600 tabular figures (scaled down, never wrapped, in a
   narrow column) over `labelMedium` / `onSurfaceVariant` labels. Screen
   readers hear one sentence: `detailMetaCountsSemantics`. Every list
   payload carries both, so a neighbour page's row is complete before it
   is swiped in. The comment count is not here: only the detail API and
   the comments response carry it (see the comment preview below). An
   unknown comment count is null on `IllustEntity.totalComments`, never 0,
   and a payload without it does not erase a known one in `IllustStore`
   merges.
4. Author block: `AuthorRow` (`illust-author-row`, 24 avatar radius) with
   a compact `FollowSwitchButton` as `trailing`. Your own work
   (`usableCurrent.userId` is the author) has no follow button.
5. Titled sections (`detailSectionCaption`, `detailSectionTags`), each a
   `titleMedium` heading marked `header` for screen readers: the caption
   (`CaptionRichText(maxLines: InfoBlock.captionLines)`, 4, collapsing
   through `ExpandableText`; skipped when empty), then the tags.
6. Footer (`illust-detail-footer`): `W×H · ID n` as one `SelectableText`
   in the metadata style, so the ID can still be copied.

The stats and author blocks stand on `surfaceContainerLow` with
`FuncShape.card` corners — neutral surfaces, no tinted cards. Comments are
reached from the floating action bar; the info area has no comments
button. The block uses the theme's text roles only.

Below the info block, before related works, come two more sections, each
under a `DetailSectionHeader` (header semantics, "See all" as
`detailViewAll`):

- **Comment preview** (`CommentsPreviewSlivers`): the first
  `CommentsPreviewSlivers.shown` (3) root comments — avatar, name, two
  lines of `CommentText` or the stamp — on one `surfaceContainerLow`
  surface that opens the comments page. Its header reads
  `commentTitle (n)` once the count is known — from the comments
  response's `total_comments` (`commentTotalsProvider`) or a detail
  payload — and plain `commentTitle` before. It reads
  `commentFeedProvider(CommentFeedQuery.root(...))`, the comments page's
  own feed, so that page opens on them. No comments: `commentNoResults`
  with a `commentInput` action; a failure: `commentLoadFailed` with retry.
- **Author's other works** (`AuthorWorksSlivers`): a horizontal strip of
  up to 12 square tiles from the author page's works feed
  (`profileIllustFeedProvider`, kind `work`), this work left out; each
  tile is one button node named by the work's title. "See all" opens the
  author. No other work: `detailAuthorNoOtherWorks`.

Both, like related works, go through `OnDemandSliver`: nothing is
requested until the section is on screen on the current pager page, and
until then it holds a static placeholder (header plus a blank of the
body's usual height, no spinner). The loading skeleton, the states and
the content replace each other in place, without `StateFade`: a section
fading in around images that fade in on their own stacks two fades.
Related works use the same `DetailSectionHeader` in every state, and its
grid and skeleton take the `FuncSpacing.xl` inset of the blocks above, so
headers, cards and the author's strip share one edge. All
three sections wrap their body
in `AutoRetry`: a network, timeout, rate-limit or 5xx failure of the
first page retries by itself twice (1.5 s, then 3 s; at least the
server's Retry-After) before the error row waits for the user. `CommentText` lives in
`lib/app/widgets/` so the detail feature can use it without importing the
comments feature.

### 2. Multi-image works

On the narrow (single scroll) layout, an illustration (`IllustType.illust`)
with more than one page shows only page 1, followed by a full-width
`TextButton` (`illust-expand-pages`, at least 48dp tall):
`detailExpandPages(n)` with a trailing `Icons.expand_more`, merged with
`expanded: false` semantics. Expanded, the same slot after the last page
becomes `illust-collapse-pages` (`detailCollapsePages`, `expand_less`,
`expanded: true`), and the page count gets a fold pill under it
(`illust-collapse-pages-floating`: a 32dp `imageControl` pill with a 48dp
touch target) that comes and goes with the count, so folding never needs
a scroll to the end. Folding from past page 1 jumps to page 1's end under
the top bar (the expand button and info right below) — as far as the
shorter list allows — rather than wherever the list clamps. Manga shows
every page; ugoira and single-page works are unchanged. Entering page
selection expands the set first, since every page has to be on screen to
be picked, and hides the fold button while selecting. The state lives in
the page's `State` and is not persisted. Page 1 stays the Hero endpoint.

The new pages appear without an `AnimatedSize`: the page list is a lazy
sliver, and wrapping it in a box to animate the height would build every
full-size page at once. The two-pane layout pages one image at a time and
is not collapsed.

### 3. Page selection

Page selection replaces the detail AppBar with `selectionAppBar`: the
count as the title, then select all and download selected
(`downloadSelectedPages`, disabled while nothing is picked). Close and
system back (`PopScope(canPop: false)` while selecting) leave the mode.
The ⋮ menu is not reachable while selecting, so its page-selection entry
needs no in-mode guard. A submitted selection shows
`showDownloadSubmittedSnackBar` and leaves the mode.

### 4. Image viewer

- One page counter: `n / total` in the top bar, a `TextButton`
  (`viewer-page-counter`) with tabular figures that opens the jump sheet.
  Its `Tooltip` (`viewerJumpToPage`) sits inside the button, so the
  button's single node carries both the count and the tooltip.
- No fullscreen button. A single tap on the artwork and the desktop `F`
  key toggle the chrome.
- The jump sheet is a thumbnail grid: cells of about 96dp, at least three
  columns, at most 60% of the screen tall, and it opens scrolled to the
  current page's row (one row of context above). Each cell is the page's
  square tier (`squareUrlAt`; a cold deep link without an entity falls
  back to the viewer URL, decoded at the cell size) with an `EntityBadge`
  page number at the bottom-start. The current page has a 2dp `primary`
  outline. Each cell is one button node (`viewer-jump-page-<i>`) read as
  `viewerPageLabel`, with `selected` on the current page.
- A pick pops the sheet with the page, waits for the sheet route's
  `completed`, then calls `jumpToPage`. A long jump does not animate the
  pages in between.

### 5. Action bar and immersive top

On the narrow layout, once content renders:

- **Action bar.** `DetailActionBar`
  (`lib/features/illust/detail/widgets/detail_action_bar.dart`) floats
  centred at the bottom, `DetailActionBar.margin` above the safe area: one
  `surfaceContainerHigh` stadium (outline, elevation 3) holding download,
  comments and the bookmark heart as separate icon buttons — no dividers,
  no segments. The heart sits on a tonal `secondaryContainer` circle as the
  page's main action. The page ends its scroll with a
  `DetailActionBar.restingExtent` spacer so the last content clears it.
  Page selection hides the bar (the selection bar carries its own
  download).
- **Download state.** The download button shows the whole work through
  `IllustDownloadController.workStateFor`: a determinate ring (mean of the
  pages' progress; indeterminate while nothing is measured), a `primary`
  check once every page is saved (tooltip `detailDownloaded`), an `error`
  alert after a failure. It listens to `DownloadManager.changes` itself —
  `events` carries terminal events only — so progress ticks rebuild the
  button, not the page.
- **Scroll hide.** The bar slides below the screen edge and fades reading
  down and returns reading up, through the same `ScrollHideTracker` +
  `slideChrome` (`lib/app/motion/scroll_hide.dart`) on the same 200 ms
  `chromeScrollHide` as the shell bar (see the NavigationBar Contract:
  user scrolling only, more than 8 physical px in a frame decides,
  depth-0 vertical, overscroll clamped). Under touch exploration it does
  not hide, and is driven back if hidden. Hidden, it is excluded from
  semantics and ignores pointers.
- **Prompts.** The bar is the page's `PromptAnchor` with its live visible
  extent, so prompts rest above it and ride its slide. `PromptAnchors`
  notifications raised during build or layout are deferred to one
  post-frame notify; an anchor under a `LayoutBuilder` would otherwise
  mutate the prompt layout mid-`performLayout`.
- **Immersive top.** The `Scaffold` extends its body behind the AppBar and
  page 1 starts at y = 0, under the status bar. `AppTopBar(immersion:)` is
  0 there: a transparent bar over an `imageControl` gradient scrim, light
  controls with a soft shadow, light status-bar icons, no title. Over the
  last `kToolbarHeight` before page 1 leaves the top the value runs to 1:
  surface alpha, control colour and the work's title fade in together.
  The `ScrollEdgeLine` stays off until the bar is fully drawn — while it
  fades, the surface itself is the edge, so two edges never stack. Overlays
  on page 1 (selection badge, page pill) are inset by the status bar plus
  toolbar height. A page whose only visible strip sits behind the status
  bar and toolbar does not count as on screen, so the page count fades out
  instead of hanging over the info. The two-pane layout and loading/error
  states keep the opaque bar.
- **Hero landing.** The flight lands under the see-through bar
  (`occludesContent` false), not clipped below it. The flight paints over
  the bar, so a detail opened from a card (`heroImageUrl` set) holds the
  bar at `entrance` 0 and fades it in over `MotionTokens.fast` once the
  route animation completes. The action bar likewise starts hidden and
  rises on `slideChrome` at the landing, and slides away as soon as the
  route reverses, so neither flight covers it. The route status is read
  after the first frame: before the push starts, the route's proxy
  animation reports a placeholder `completed`.

### 6. Tests required

- `illust_detail_page_test.dart`: info block order with header-marked
  section titles and no comments button; the author row follows in place
  and your own work has no follow button; the local date, the stats'
  compact figures and spoken sentence, including an unknown date and
  comment count; a long caption collapses and expands and a short one has no
  toggle; an illustration set opens on page 1, expands and folds back
  from the end button and from the pill, landing at page 1's end; manga
  shows every page, and page selection expands without a fold button; the
  count leaves once page 1's last strip is behind the top bar; the comment
  preview and author strip request nothing until on screen, show three
  comments under a header and open the comments page, offer to write the
  first comment, leave this work out of the strip and open the others,
  and say when the author has no other work; selection uses the shared bar
  and back leaves the mode first; the viewer has one counter, no
  fullscreen button, a thumbnail jump grid with the current page selected,
  and a long work's sheet opens on the current page; the action bar holds
  download, comments and bookmark while the top bar keeps only the menu;
  the ring follows half-downloaded pages, then the saved state, with the
  prompt above the bar; the bar hides and returns and stays under
  touch exploration; page 1 runs under a see-through bar that draws in.
- `hero_transition_test.dart`: mid-flight the top bar's `entrance` and
  the action bar are 0, after landing 1; the action bar leaves as the pop
  starts.
- `priority_surface_semantics_test.dart`: the viewer counter and fit are
  named buttons.
- The `content: illust detail` locale matrix covers the info block in four
  languages at 320dp and 1.3x.

### 7. Wrong vs Correct

#### Wrong

```dart
onSelected: (page) {
  Navigator.of(sheetContext).pop();
  _pageController.jumpToPage(page); // the sheet is still closing
},
```

While the modal sheet is on screen it blocks the viewer's semantics. The
counter's label changing under it trips the semantics flush
(`'node.built': is not true`).

#### Correct

```dart
TransitionRoute<int>? sheetRoute;
final page = await showAppBottomSheet<int>(
  context: context,
  builder: (sheetContext) {
    sheetRoute ??= ModalRoute.of(sheetContext) as TransitionRoute<int>?;
    return _PageJumpGrid(
      onSelected: (page) => Navigator.of(sheetContext).pop(page),
    );
  },
);
if (page == null) return;
await sheetRoute?.completed;
if (mounted) _pageController.jumpToPage(page);
```

## Tab Navigation Animation Contract

Between home-shell branches there is no swipe: on a destination tap
`HomeBranchStack` slides the outgoing and incoming branch side by side
(user decision 2026-10-08), the incoming one in from the side its
destination sits on the bar — right for a higher index, mirrored for
right-to-left, along the rail on wide layouts — over
`MotionTokens.branchSwitch` (300 ms, `branchSwitchCurve` =
`Curves.easeInOutCubicEmphasized`, whose gentle start keeps the frame that
builds a first-visited branch nearly still; a straight swap at zero
duration under reduced motion). The bar stays put above the strip. Only
the current branch is hit-testable, semantic, and
`BranchActivityScope.active` during the flight; `Offstage` keeps unvisited
branches unbuilt.

During the flight the two sides play different roles. The incoming branch
stays live: `TickerMode` keeps its tickers running so entrances, image
fades and press feedback animate through the switch instead of jumping at
the end. The outgoing branch's `TickerMode` is off and it alone hands its
subtree to an armed `SnapshotController` (`SnapshotMode.permissive`, so a
branch showing a platform view paints live): the slide moves one texture
instead of re-rendering that page each frame. Every branch sits in a
`SnapshotWidget`; branches that are not sliding out share a second controller that is never armed, so the widget
stays in the tree and starting a switch never remounts a branch. The
snapshot is released when the switch lands; a per-switch generation number
keeps an interrupted switch's completion from releasing the newer one, and
an interruption promotes the previously incoming branch to outgoing — its
first armed paint captures its live state.

In-page tab strips keep the gesture. `TabSwipeSwitcher` requires a
`tabController`, follows a horizontal drag, and commits or cancels at the
edge — the drag never crosses into a branch switch. `TabBar` owns the
`TabController.animateTo` call for a tap. A tab's `onTap` callback may
update selected state, lazy-build bookkeeping, or an auxiliary selector, but
must not call `animateTo` for the same index. Starting a second animation
from the callback resets the indicator/body flight and produces a visible
stall on fast taps. Programmatic selection may call `animateTo` only when it
did not originate from the `TabBar` tap callback.

After a tab switch the page calls `announceTabScroll(context, controller)`
(`tab_swipe_switcher.dart`): it dispatches one synthetic
`ScrollUpdateNotification` from a body-level context — above the page's
scrollables but below the Scaffold — so the top bar's scrolled-under state
re-reads the new tab's position. Dispatching through the list's own
position (`position.didUpdateScrollPositionBy(0)`) would make the feed's
load-more listener see a zero-delta scroll and fire an extra request.
Tab scroll controllers also register `ScrollController.onAttach` to issue
the same announcement for a tab whose list mounts after the switch — the
first visit through a skeleton otherwise leaves the bar stuck on the
previous tab's state.

## Branch Re-tap Contract

A tap on the bottom-bar destination that is already active is the re-tap
gesture. `HomeBranchStack._select`
(`lib/app/widgets/home_branch_stack.dart`) detects it, calls
`goBranch` (a no-op on the live branch), pops the branch Navigator to its
root — a `PopScope`-vetoed route (`doNotPop`) cuts the pop short — and
fires the `ReTapChannel`. Consumers read it through
`HomeBranchStack.reTapOf(context)` — null outside the home shell.

- `ReTapChannel` (`ChangeNotifier`) is an edge, not a state. Every
  same-destination tap emits, including consecutive taps on the same
  index — a `ValueNotifier<int>` carrying the branch index would swallow
  repeats. Only a same-index tap emits; `goBranch` moves never emit.
- Consumers read `channel.branch`, compare it against
  `BranchRootScope.maybeOf(context)?.branchIndex`, and schedule the
  scroll post-frame so it lands after the pop commits. A vetoed pop
  leaves a pushed route covering the root — the scroll must tolerate
  landing on a covered page (`isCurrent`/`hasClients`/`mounted` guards).
- The scroll itself goes through the shared `reTapScrollToTop(context,
  controller)` helper: `MotionTokens`-gated `animateTo(0)`, `jumpTo(0)`
  under reduced motion. A list already at the top refreshes instead
  (HCI 10): the helper calls `PullToRefresh.trigger(controller)`, which
  runs the same indicator and `onRefresh` a released pull would. That
  needs the feed's `PullToRefresh` to be given the list's
  `scrollController`; without one the re-tap at the top does nothing.
  Re-tap is never a selector toggle or a selection change.
- In-page re-taps follow the same rule locally, calling
  `reTapScrollToTop` on that slot's own `ScrollController`: a `TabBar`
  `onTap` on the selected index while `!controller.indexIsChanging`.

Owning tests: the re-tap group in `test/home_branch_stack_test.dart`
(emit-once-per-tap, pop-to-root, programmatic silence), plus per-page
re-tap cases in `test/new_content_feed_test.dart` and
`test/search_catalog_test.dart`.

## Shared Pull-to-Refresh Contract

### 1. Scope / Trigger

This contract applies to every feed that offers pull-to-refresh. It is
deliberately separate from the artwork detail transition contract: refresh
behavior has nothing to do with Hero flights, and burying it there hid the
rules from the people who needed them.

### 2. Signatures

```dart
const PullToRefresh({
  required RefreshCallback onRefresh,
  required Widget child,
  bool isNested = false,
  ScrollController? scrollController,
});

/// Refreshes the list [controller] scrolls as a released pull would;
/// false when no mounted wrapper was given [controller].
static bool PullToRefresh.trigger(ScrollController controller);
```

### 3. Contracts

- `PullToRefresh` is the single shared refresh wrapper. Feeds must not add a
  second per-page refresh implementation.
- The shared wrapper uses `EasyRefresh` with a `MaterialHeader` configured as
  `position: IndicatorPosition.above`, `safeArea: true`, and `clamping: false`
  for ordinary lists. `clamping: false` is required so a reversed pull is
  represented as real overscroll and retracts the indicator before the list
  starts scrolling; clamping would pin the indicator while content moves.
  For a tab body inside a `NestedScrollView`, pass
  `isNested: true`; that path uses `IndicatorPosition.locator`,
  `safeArea: false`, and exactly one `HeaderLocator` as the first list item or
  sliver. Theme colors are passed through; pages do not create a second header
  or refresh controller for the same scrollable.
- A `NestedScrollView` is kept as the outer scroll coordinator and each active
  tab body owns one nested `PullToRefresh` wrapper (the `EasyRefresh`
  locator pattern). Do not add another wrapper around the whole
  `NestedScrollView`. Ordinary lists use the default `isNested: false` path.
- Only the selected tab of a `NestedScrollView` sits on its inner
  controller (`_SelectedTabScroll` in `user_page.dart`). Kept-alive tabs
  otherwise all attach to it, and the coordinator drives every attached
  position as one: it picks an arbitrary one for a fling's metrics (a
  fling on About died at the header) and drags the hidden tabs along. An
  unselected tab parks on a controller whose positions the inner controller
  still makes — Scrollable attaches its old position to a new controller
  before replacing it, and the nested controller accepts only its own kind.
  Its `PrimaryScrollController` is never `.none`: a feed that does not
  inherit registers no dependency and misses the hand-back.
- Touch scroll physics are unified app-wide through `FuncScrollBehavior`:
  `BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics())` plus no
  platform overscroll indicator — the same scheme `_ERScrollPhysics` installs
  inside `PullToRefresh` subtrees, so non-feed pages (detail, settings,
  search) share the feed's feel. Do not reintroduce a
  `ClampingScrollPhysics` region.
- A `NestedScrollView` does **not** inherit that behavior: its outer position
  is `widget.physics?.applyTo(Clamping) ?? ClampingScrollPhysics()`. Pass
  `physics: ScrollConfiguration.of(context).getScrollPhysics(context)`
  explicitly. On release the coordinator runs one ballistic per position
  over the same combined metrics, and the nested feeds' `_ERScrollPhysics`
  always builds a `BouncingScrollSimulation`; a Clamping outer travels a
  fraction of that distance at low speed (24 vs 150px at 300px/s), so the
  header stops short while the feed rolls on, and a light pull-down dies at
  the edge (09-30 profile "dip"/"stuck").
- The wrapper hands `EasyRefresh` a `child`, so EasyRefresh makes
  `ERScrollBehavior(_ERScrollPhysics)` the `ScrollConfiguration` of that
  whole subtree, on every axis. A horizontal scrollable inside a feed opts
  out with `ScrollConfiguration.of(context).copyWith(physics: ...)`;
  otherwise a sideways drag past its start edge arms the refresh header.
  An explicit `physics:` on the scrollable is not enough — `Scrollable`
  applies it on top of the inherited physics.
- Indicator behavior, stated as observable outcomes:
  - A pull that reverses before release moves the indicator back with the
    finger; releasing below the threshold cancels without calling `onRefresh`.
  - **While any part of the indicator is on screen, the list does not scroll.**
    The reverse gesture retracts the indicator first; only once it is gone does
    the remaining gesture move the content. This requires the pull to be stored
    as real overscroll in the scroll coordinate space — under clamping physics
    the distance does not exist and the two necessarily move together.
  - Motion produced after the pointer has lifted (ballistic settle, bounce,
    overscroll) never starts or resumes a pull.
  - Every pull ends with the indicator hidden — whether it refreshed or cancelled.
  - Once `onRefresh` starts, no scroll activity resets the refreshing state
    until that Future completes. Exactly one `onRefresh` per qualifying pull.
  - `trigger` springs the list onto the trigger offset (`MotionTokens.fast`,
    a jump under reduced motion) and refreshes once it settles, exactly as
    after a release; the indicator shows from the first frame. Only the
    branch re-tap calls it.
- The refresh threshold is decided in exactly one place. The wrapper must not
  maintain a drag-distance judgement in parallel with the framework's, and must
  not veto a refresh the framework has already triggered.
- Reading `metrics.pixels` to *render* is allowed and is how the wrapper drives
  the indicator; accumulating a drag distance, deciding a threshold, or
  overriding the framework's decision is not. Mirroring the framework's own
  value creates no second source of truth — the previous implementation's
  defect was the second judgement, not the act of listening.
- The first-load skeleton is scoped to the initial load
  (`PagedFeedState.showInitialSpinner` / `AsyncValue.loading`). A refresh
  keeps the loaded list mounted under the indicator and never falls back to
  the skeleton; load-more uses the feed's own tail. See
  [First-Load Skeletons](#first-load-skeletons).

### 4. Validation & Error Matrix

| Condition | Required behavior |
| --- | --- |
| Armed pull reverses before release | Indicator follows the finger back; releasing below threshold cancels without calling `onRefresh`. |
| Reverse gesture continues past the indicator | Indicator retracts fully before the list scrolls; the two never move together. |
| Scroll motion continues after the pointer lifts | No pull starts or resumes; indicator stays hidden. |
| Refresh completes or cancels | Indicator returns to hidden; nothing residual on screen. |
| Sideways drag on a horizontal scrollable inside the feed | Never calls `onRefresh`. |

### 5. Tests Required

- Pull-to-refresh tests drive a real scrollable and cover: reverse-then-release
  below threshold, a valid release, and pointer-up ballistic overscroll.
  Assert the indicator's **final** visibility in every case, not only its
  motion before release.
- The reverse-drag case must pull **past the arm threshold**. A pull that stops
  short takes a different framework path, so a test written that way passes
  without ever exercising the behavior it claims to cover.

### 6. Wrong vs Correct

Do not let the framework's armed visual state pin the indicator after the user
has reversed the drag. Correct that in the shared wrapper — but not by running
a second scroll-notification state machine alongside the framework's. Take the
framework's answers (its status callbacks, its scroll metrics) rather than
re-deriving them; "do not rebuild the state machine" is not "do not read the
framework's state".

## Haptics Contract

`AppHaptics` (`lib/app/haptics/app_haptics.dart`) is the single haptic
entry point. Feature code never calls `HapticFeedback` or the
`parfait/haptics` channel — the architecture test only allows them inside
`lib/app/haptics/`.

### 1. Principle

Vibrate to confirm a **state change the user caused**. Navigation (tab
bar, bottom nav, root swipe, opening a page, back) and high-frequency
events (scrolling to an edge, zoom limits, every drag frame) stay silent.
A test pins the navigation chrome files as haptic-free. Background events
(a download finishing, an offline-queued action replaying later) never
vibrate: the user is elsewhere and would read it as feedback for whatever
they are doing.

### 2. Roles

Callers name a role, never an effect or a level:

| Role | Use |
|---|---|
| `select` | picking one option (segment, radio row, single chip), toggling an item in selection mode, removing a bookmark, a follow landing |
| `toggleOn` / `toggleOff` | a switch or toggle chip by its new value; a watchlist change landing |
| `tick` | a stepped slider crossing one division |
| `thresholdOn` / `thresholdOff` | a drag crossing the point where releasing acts (pull-to-refresh arm, drag-to-dismiss distance) and pulling back under it |
| `longPress` | an app long-press opening a sheet or menu |
| `confirm` | entering a management/selection mode, opening a batched or destructive surface |
| `success` | a submitted action landed (bookmark added, download queued, copy) |
| `error` | the action the user just attempted failed |

The role → effect mapping lives only in the Android `HapticPlanner.kt`
(see the `parfait/haptics` channel contract). Adding a role needs a real
consumer and a planner row.

### 3. Strength, throttling, capability

- The persisted `hapticStrength` (`off` / `light` / `standard` / `strong`,
  default `standard`) is read through the reader `ParfaitApp.build` injects
  via `AppHaptics.configure`. An unreadable setting is silent; before
  `configure` everything is silent. Legacy `enableHaptics: false` migrates
  to `off`, `true` to `standard`.
- Throttling is per lane, not per role: light (select, toggles, tick,
  thresholds) 50 ms, medium (success) 80 ms, heavy (longPress, confirm,
  error) 120 ms. A long-press that enters selection mode vibrates once.
- `AppHaptics.preview(strength)` plays `confirm` at the given strength
  unthrottled — only the strength picker uses it, and that picker turns
  off its own select haptic (`SettingsMenuTile(haptics: false)`).
- The settings footer shows the device tier from `capabilities`; the
  vibrator tiers degrade to `View` haptics on ROMs that refuse them.
- Haptics are redundant: with strength `off` or no vibrator, every visual
  feedback must still be complete.

### 4. Ownership

- **Components own their haptic.** `SettingsControl` and
  `ReplicaSwitchTile` (toggleOn/Off), `SettingsChoiceTile` (select on a
  different entry), `SettingsMenuTile` and `FilterMenuButton` (select on a
  different option), `AppChoiceChip` (single: select, and `onSelected` runs only
  for an unselected chip; `.toggle`: toggleOn/Off), `AppSlider` (tick per
  division; continuous sliders are silent). External value changes never
  vibrate. The architecture test confines raw
  `ChoiceChip`/`FilterChip`, `Slider`, `Switch`/`SwitchListTile` and
  `Radio`/`RadioListTile` to these wrappers.
- **Store mutations vibrate on the settled outcome, at the call site.**
  `toggleBookmark`, `toggleFollowWithUndo` and `WatchlistToggle`
  read the entry
  before, await the action, then read it again: a pending (queued) or
  cancelled entry is silent, an error plays `error`, a landed change plays
  its role. Do not `ref.listen` the store for haptics — a replay landing
  later, or several buttons for the same key, would vibrate out of
  context.
- **Clipboard writes** go through `copyToClipboard(context, text, message:)`
  (`lib/app/clipboard.dart`): write, then `success`, then the toast. A
  failed write throws before either. The architecture test allows
  `Clipboard.setData` in `lib/app` / `lib/features` only there.
- **Long press.** The handler calls `longPress()` (or `confirm()` when it
  enters a mode). `InkWell` / `ListTile` / Material buttons vibrate on
  long press themselves, so a carrier with an app long-press sets
  `enableFeedback: false` (`EntityRow` and `TagChip` use
  `onLongPress == null`). That also drops the Android tap click sound on
  those carriers; accept it. `GestureDetector` has no built-in feedback.

### 5. Tests

Configure haptics with `recordHaptics()` (`test/helpers/recording_haptics.dart`)
and assert `driver.roles` / `driver.played`; do not mock
`SystemChannels.platform`. The throttle reads the wall clock, so a test
that expects two haptics in the same lane waits
`AppHaptics.lightInterval` (or the lane's interval) inside
`tester.runAsync` between them.

## Motion Contract

`MotionTokens` and `MotionSpring` (`lib/app/motion/motion_tokens.dart`)
are the only sources of UI animation lengths and springs. Data-level
durations (debounce, throttles, frame scheduling) do not belong there.

### 1. Speed and the reduced-motion gate

- `MotionScope` (mounted in `MaterialApp.builder`) publishes `reduce`,
  `speed` (`AnimationSpeed` fast/normal/slow = 250/350/450, factor
  `code / 350`) and `pressFeedback`. The persisted key stays
  `pageTransitionSpeedCode`.
- Read every duration through `MotionTokens.resolve(context, token)`: the
  token times the speed factor, or zero when the gate is closed (platform
  `disableAnimations`, platform `reduceMotion`, or the in-app setting).
  Callers above `MotionScope` (the `MaterialApp` theme animation) use
  `resolveWith(..., reduce:, speed:)`.
- Reduced motion removes the flight, never the state it communicates.
  A scroll animation asserts a non-zero duration, so programmatic page
  turns go through `turnPage(context, controller, page)`, which jumps
  under reduced motion.
- `test/architecture/motion_census_test.dart` fails on a token read
  outside `resolve`. Its pinned exceptions: the `FuncPage` constructor
  defaults, `PixivImage` fade parameters (resolved where they are used),
  the skeleton shimmer period, and wheel-scroll physics.
  `feedback_channels_test.dart` pins every raw `Duration(milliseconds:`
  per file. Framework-owned animations (`MenuAnchor`, the `TabBar`
  indicator) do not follow the speed; the settings footer says so.

### 2. Springs

- `MotionSpring` holds Material 3 (damping ratio, stiffness) pairs from
  androidx `StandardMotionTokens` / `ExpressiveMotionTokens`, mass 1,
  listed only when something uses them: `spatialFast` (press,
  expand/collapse, removal, drag return, bookmark heart dip on removal),
  `spatialDefault` (bottom
  sheet), `effectsFast` (state fades, check marks), `expressiveSpatialFast`
  (bookmark heart pop). **Spatial** springs move position, scale and
  size; **effects** springs change opacity and colour — never swap them.
- `MotionTokens.spring(context, token)` returns a `SpringDescription`
  whose stiffness is divided by factor², or null under reduced motion
  (jump to the end value). `springCurve(context, token)` returns the
  settle time and a `SpringCurve` for APIs that only take a duration and
  curve (`AnimatedSize`, `AnimatedSwitcher`, `AnimationStyle`); zero
  under reduced motion. The census test allows spring tokens only inside
  these two calls.
- Physical springs run on `AnimationController.unbounded` with
  `animateWith(SpringSimulation(..., snapToEnd: true))`. Without
  `snapToEnd` the value rests inside the tolerance (0.9998), leaving a
  permanent non-identity transform on the widget.
- A zero-duration `AnimatedSize` asserts during its own layout:
  `SpringSize` returns its child as-is under reduced motion.

### 3. Shared motion widgets

| Widget | Motion |
|---|---|
| `PressScale` | spring to the rest scale while pressed and back, interruptible; off with the press-feedback setting; frozen tickers set the value without playing. Wraps every tappable card (`MotionTokens.pressScale`, 0.97) and pill (`MotionTokens.pillPressScale`, 0.96). |
| `StateIconSwitcher(value:)` | effectsFast fade plus scale from 0.8 when `value` changes — selection checks, watchlist, download badges. Keyed by state, not by widget instance. |
| `StateFade(kind:)` / `.onMount` | fades the new state in from 0 when `kind` changes (skeleton → content); replaces, never cross-fades. `onMount` for widgets that only appear as a change (`FeedEmpty`, `FeedError`). Keeps semantics during the fade. Frozen tickers and reduced motion show it at once. |
| `SpringSize` | `AnimatedSize` on spatialFast for sections that open and close (`ErrorDetails`). |
| `RemovalScope` / `Removable` | see §4. |
| `DragToDismiss` | the return runs `SpringSimulation(spatialFast, offset, 0, release velocity)` in pixels. |

**Press feedback rules (HCI 11).** Every tappable element shows a press,
and only one kind of ink:

- Ripple (Material ink) where the ink fits the visible shape: list rows,
  tiles, menu items, buttons, icon buttons, the bottom bar.
- Scale (`PressScale`) on cards and pills: feed cards at 0.97; tags and
  chips (`TagChip`, `AppChoiceChip`) at 0.96. A chip keeps its own clipped
  ripple; `TagChip` drops ink altogether, because its tap target (48dp tall,
  touching its neighbours) is larger than the 32dp pill and ink would fill
  the invisible margin.
- A disabled element (no callback) gets no press scale.
- Small targets extend their hit area to 48dp without growing the visible
  shape; neighbouring targets touch, so the gap between them is never dead.

Feed cards land in place; only their images fade. Do not add an entrance
or a `StateFade` around grid content or detail sections.

### 4. Removal: exit first, then commit

Lists stay driven by their provider. The page state owns a
`RemovalController` and hands it down with `RemovalScope`; each item is
`Removable(id:, style: row | tile)`. To delete: `await
controller.playExit(ids)`, then commit the change, and call
`controller.restore(ids)` when the commit fails. A row collapses and
fades, pinned to its top edge (the bottom edge moves, the rows below
follow, and a container that draws the row's corners keeps them in
view); a tile shrinks to 0.9 and fades and the grid reflows on the
commit. Ids not on screen are skipped and reduced motion completes at
once. `controller.leaving` lists the built ids whose exit started, from
`playExit` until `restore` or until the row unregisters (its list rebuilt
without it — dropped silently, since the tree is being finalized then).
A container that shapes rows by position (`SettingsGroup`) lays out
without them from the exit's first frame. Row callbacks read the controller with `RemovalScope.of` (no
dependency). Read stores and actions before awaiting the exit: the
widget may be gone afterwards.

`Removable(animateIn: true)` plays the exit backwards on first build, for
rows a user action inserts (download group expand). Only mark the rows
inserted on that frame, and cap how many: a growing row starts at zero
height, so a lazy list would build every one of them.

### 5. Overlays

Page transition styles and the back-gesture driver are part of the
Predictive Back Contract.

`showAppBottomSheet` opens on the spatialDefault spring curve and closes
over `MotionTokens.medium` (Material's 200 ms exit), with
`AnimationStyle.noAnimation` under reduced motion. Dialogs use
`MotionTokens.dialog`; snackbars resolve `medium` / `fast`.

### 6. Rebuild and semantics budget

On Android, Dart runs on the platform main thread. With an accessibility
service running, every semantics update also makes the service re-read
the tree on that thread. Users with an always-on service (GKD, TalkBack)
pay this on every frame that changes semantics. So widgets repeated per
card or per image keep their dependencies narrow:

- Read `MediaQuery` through aspect getters
  (`MediaQuery.maybeDisableAnimationsOf`, `sizeOf`, …). A whole-object
  `MediaQuery.of` / `maybeOf` dependency rebuilds every card whenever any
  field changes, such as insets or `accessibleNavigation`.
- Do not depend on `TickerMode.valuesOf` in per-card or per-image state.
  A route covered by an opaque route and a branch fading out both have
  `TickerMode` flipped for the whole page, and every dependent rebuilds
  in that frame.
  - Mix in `TickerModeWatch` (`motion_tokens.dart`): read `tickersEnabled`
    and override `didChangeTickerMode`. Rebuild there only when the output
    actually changes. Examples:
    - `PressScale` drives only a card that is off its rest scale;
    - `PixivImage` rebuilds only a cold load still in flight.
  - A one-shot read at an animation's start uses
    `TickerMode.getValuesNotifier(context).value` (`StateFade`).
- Opacity-driven entrances pass `alwaysIncludeSemantics: true`
  (`StateFade`). The content then joins the semantics tree when it mounts,
  not when the fade crosses zero.
- Progress semantics values move in 10 % steps
  (`ImageLoadProgressOverlay`); the drawn indicator stays continuous.
- Measurement builds count the scenes in progress for the frame probe:
  - a subtree whose lifetime is the scene (a Hero shuttle) is wrapped in
    `ProbeScene`;
  - anything else pairs `FrameProbe.instance.enter` / `exit`.

  Both are no-ops unless `FrameProbe.available`.

### 7. Tests

Wrap the subject in `MotionScope(reduce:, speed:)` and step frames with
`tester.pump(duration)`; spring settle times are about 150 ms
(effectsFast), 225 ms (spatialFast) and 320 ms (spatialDefault) at normal
speed. Cover reduced motion for every new motion. Golden tests whose
subject fades in pump past the fade before comparing.

## Artwork Badges Contract

Every marker painted over artwork is an `EntityBadge(icon:, label:,
semanticsLabel:)` (`lib/app/widgets/entity_row.dart`): the
`FuncTokens.imageControl` scrim with `onImageControl` content, legible on
light and dark images and identical in both themes; at least
`EntityBadge.height` (20) tall with a 6dp inset and `FuncShape.badge`
corners; 14dp icons; `labelSmall` w600 tabular text. No badge picks its own
color — R-18 and AI differ by their text, not by a fill.

`IllustCard` keeps four fixed corners, 7dp inside the image: R-18 top-left,
page count top-right (`Icons.photo_library_outlined` + compact count, read
as `illustPagesTotal`), ugoira bottom-left (icon only, read as
`badgeUgoira`), AI bottom-right (read as `badgeAi`). The labels merge into
the card's semantics.

`NovelEntry` is a full-bleed `EntityRow` (16/12dp padding, no card, ink
only): title, author, `series · word count` meta, a footnote of up to four
`#tags`, and the bookmark count as an `EntityBadge` (`Icons.favorite` +
compact count) 4dp inside the cover's bottom-left corner, only when above
zero. The row reads "title, author, `novelEntryBookmarks`". `EntityRow`
carries no `PressScale`: it is a list row (HCI 11).

A ranking position is not a badge: `EntityRankLabel` leads the title line
(`titleSmall`, bold, tabular, `onSurface`, 4dp before the title, no medal
or top-three color) in `IllustCard(rank:)` and, through
`EntityRow.titleLeading`, in `NovelEntry.ranking`. The line reads
"`rankLabel`, title". Owning tests: `illust_card_badges_test.dart`,
`novel_entry_test.dart`, and the `lists: ranked entries` locale matrix.

## Author Row Contract

An author shown as a link is an `AuthorRow(userId:, name:, avatarUrl:,
trailing:)` (`lib/app/widgets/author_row.dart`): the whole avatar + name
row is one `InkWell` at least 48dp tall that calls `openUser`, announced
as one button labelled with the name and hinted `openAuthorProfile`.
`AuthorSummary` (compact, 32dp avatar) draws the content; `trailing` (a
follow button) stays a separate target outside the ink. Never make only
the name text tappable. Inside a card the card itself is the target, so
the card's byline stays plain text. Where navigation needs a step first
(the novel info sheet closes before opening the profile), keep
`AuthorSummary` with padding that makes the target 48dp. Owning test:
`author_row_test.dart`.

## Expandable Text Contract

Long user text (captions, descriptions) uses `ExpandableText(span,
maxLines:)` (`lib/app/widgets/expandable_text.dart`). A `TextPainter` at
the laid-out width decides whether the text exceeds `maxLines`; text that
fits shows no toggle. Collapsed text ellipsizes; the toggle is a
`TextButton` under the text, end-aligned (`expandText` / `collapseText`),
merged with `expanded` semantics. Links in the span stay tappable in both
states. The height change animates with `AnimatedSize` at
`MotionTokens.medium` through the motion gate; the state is not persisted.
Owning test: `expandable_text_test.dart`.

## Discovery Pages Contract

**Search results.** The result types (illustration, novel, user) are an
`AppTabBar` on the results page. A tab switch replaces the route
(`replaceSearchResults` with `searchQueryForType` for the new type), so
the page keeps its State and the URL keeps the type. The page holds one
filter draft per artwork type for this search, seeded from the persisted
defaults with the URL's own type laid over it; a user query carries no
filters, so illustration → user → illustration comes back with the
illustration draft. A results page built
without `onTypeChanged` (the tag page) switches locally. The filter
summary bar under the tabs shows only for work types; every part of it
reads as words (`searchRangeAtLeast`, `searchDateFrom`, …), never a
bare `≥`/`~` between numbers. Owning test: `search_result_page_test.dart`.

**Ranking date.** A past ranking is the `date=yyyy-MM-dd` query
parameter (`formatApiDate` / `parseApiDate`, strict and round-trip
checked). `rankingDateOrLatest` maps a missing, malformed or
out-of-range date to the latest ranking (null). The picker
(`RankingDateButton`, app-bar action) allows `rankingFirstDate` through
`rankingLastDate()` — yesterday in Japan, where rankings are
published. A date is part of the feed identity: the family key is
`(mode, date)`, the `feedKey` is `ranking:<mode>@<date>`, and a cursor
from another day (or the latest) is rejected. Only the latest ranking
has a snapshot codec — a past date must never overwrite the cold-start
snapshot. While a date is shown, `RankingDateBar` sits at the top of
the body, not in `AppBar.bottom`, so its label wraps at large text
sizes; "back to latest" clears the date. Changing the date resets every
mode's controller and keeps only the current tab loaded. Illustration
and novel rankings follow the same rules. Owning tests:
`ranking_feed_test.dart`, `novel_ranking_feed_test.dart`.

**Recommended users.** A recommended user's card shows up to
`UserRelationPage.previewLimit` (3) of the works pixiv sends with the
user, in three equal square slots. The works merge into `IllustStore`;
`userPreviewIdsProvider` (account-scoped) keeps only the ids. Works
hidden by the local R-18/AI blocks or a mute are left out, never shown
blurred; a user with no visible works shows no strip. Each thumbnail is
its own button labelled with the work's title and opens the work. A
malformed preview payload fails the page (`FormatException`), it is not
silently dropped. Owning test: `recommended_home_test.dart`.

**Comments.** Reply and, when there are replies, "view N replies"
(`commentViewReplies`) are `TextButton`s under the body with their
default 48dp targets, in an `OverflowBar` that wraps; reply is on
`onSurfaceVariant`, the replies link on `primary`. Everything else —
translate (disabled while a translation runs) and delete on the
viewer's own comment (`destructive`, confirmed by the page) — is in a
⋮ `AppMenuButton` (`commentMoreActions`) at the end of the row; with
neither it is not built. No pill buttons. Owning test:
`comment_item_test.dart`.

**Series.** The series header has one primary button. With a reading
record (`SeriesRecentOpenStore`, this session's last opened work) it is
"continue episode n" (`seriesContinueEpisode`, or `seriesContinue`
without an episode number), and "start from episode 1"
(`seriesStartFromFirst`) is a `TextButton` beside it, absent when pixiv
sends no first work. Without a record the only button is "start
reading". The watchlist sheet uses the same continue wording. The
caption is an `ExpandableText` folded at three lines. Owning test:
`series_feed_test.dart`.

## Library, Settings and Onboarding Contract

**Selecting several entries.** A list whose entries can be removed in
batches (download tasks, history, watch later) enters selection with a
"manage" `TextButton` (`l10n.manage`) in the app bar, shown only when
the list has entries — a spelled-out word, not an icon (an icon alone
was unreadable in testing). Selection swaps the bar for
`selectionAppBar` (close, count, select all, the batch actions). System
back leaves selection before it leaves the page. Grid entries wrap in `SelectableTile`
(`lib/app/widgets/selectable_tile.dart`): while managing, the whole
tile toggles on tap and long press, the child's own gestures are
absorbed, a selected tile gets a tinted frame and a check and is
announced selected; outside management a long press is the child's
(watch later opens the card sheet) or the page's (history enters
selection). Removing never asks first: the entries play their exit
(`RemovalController.playExit`), the store removes them in one write, and
`showUndoSnackBar` puts them back in their old places. Batch removal
leaves selection first.

**Undoable removals.** A removal returns what undo needs, and undo
restores positions, not just membership. `DownloadManager.dismissAll`
removes finished tasks only (records, never files) and returns a
`DownloadRemoval`; `restore` re-inserts each task into its own group at
its old index, rebuilds a group removed with its last task, skips a
task whose dedupe key was submitted again in the meantime, and
persists. "Clear completed" (an icon with a tooltip, shown only when a
task succeeded) passes the succeeded ids to `dismissAll`. Batch cancel
keeps its confirmation — it stops work that cannot be undone. A
download task row opens its work on tap (`downloadOpenWork` tap hint),
so it has no View button; while managing it selects. `WatchLaterStore.removeAll` returns a
`WatchLaterRemoval` (account id and the entries with their original
`addedAt`); `restoreAll` re-inserts them so they sort back into place,
and restores nothing once another account is current. Owning tests:
`download_manager_test.dart`, `download_tasks_page_test.dart`,
`watch_later_store_test.dart`, `watchlater_page_test.dart`.

**Muted items.** Work mutes are `MutedWork {illustId, title,
thumbnailUrl}` captured from the card when muted; the stored list
(`muted_works_<account>`) and the backup (`mutes.works`) are written as
objects, and `MutedWork.fromJson` also reads the earlier bare ids
(backups: `mutes.workIds`). Importing a backup, under merge or
overwrite, fills a muted work's missing title or thumbnail from the file
and keeps what it already has; that is not counted as a mute change
(`workMutesChanged`). The store has `muteWork` / `unmuteWork`, no
toggle; unmute undo passes the removed `MutedWork` (or `MutedUser`) so
the entry comes back whole. The management page shows a muted author
with `PersonAvatar(radius: 20)` and a muted work with a 48dp
`FuncShape.control` thumbnail blurred like `MutedCover` (sigma 10) —
the user hid it, the list does not show it plainly. A work without a
stored title or thumbnail falls back to a loaded copy, then to "#id"
and a placeholder icon. An empty author or work group shows one
non-interactive line saying where those mutes are made
(`muteEmptyHint(action)` with the card menu label); there is no
page-wide empty state. Owning tests: `muted_items_page_test.dart`,
`mute_store_test.dart`, `backup_test.dart`.

**Onboarding.** The guide is welcome → language → sign-in. The welcome
page shows the app mark (`assets/branding/parfait_icon.png`, 96dp,
excluded from semantics), a `headlineMedium` title and a `bodyLarge`
`onSurfaceVariant` line. The language page lists the languages as
`SettingsChoiceTile`s in a `SettingsGroup`; a pick applies at once and
the page's own text (read with `l10nLookupFor` from the persisted
language) follows it. Its single action completes the guide and opens
sign-in (`openLogin(isFirst: true, returnToHomeOnSuccess: true)`);
there is no "set up later" and no theme step — the theme is in
settings, whose options list the default first (follow system, light,
dark). Owning tests: `onboarding_pages_test.dart`, `settings_test.dart`.

**Naming template variables.** Under the custom template field, one
`ActionChip` per `NamingRule.supportedVariables` entry, labelled with
what it inserts (`namingVar…`) and announced as "meaning, {variable}".
A tap inserts `{variable}` at the cursor or over the selection (at the
end when the field has no cursor yet), moves the cursor after it and
keeps the field focused; an insertion that would pass the field's
128-character limit is dropped. An insertion is an unsaved edit like
typing: the preview updates, save is offered and leaving asks first.
The preview has a localized sample for every variable, so every chip
visibly changes it. Owning
test: `download_settings_page_test.dart`.

**Profile images.** On the profile edit page the avatar and the
background image are the controls: ink over the image, a 24dp
`primaryContainer` edit badge in the corner, one `Semantics(button)`
node labelled `profileChangeAvatar` / `profileChangeBackground`. A field
the current route cannot change is a plain image with
`profileEditFieldUnsupported` under it; while editing is unavailable the
page notice explains and no image is a control. Owning test:
`profile_edit_test.dart`.

## Management List Rows

Management-style lists (Settings → Download Tasks and any future
batch-manageable list) render **rows**, not stacked cards, and follow
these rules:

- **Lazy construction.** The list is a `CustomScrollView` of two flat,
  lazily built lists: the groups (each header, plus its children while
  expanded) and the ungrouped items. Large item sets and large expanded
  groups must not build every row eagerly; row keys
  (`download-task-*`/`download-group-*`) follow the task or group
  identity, and the two lists are keyed so one leaving does not rebuild
  the other's rows.
- **One container per group.** The group list is a `SliverSurfaceList`
  (`lib/app/widgets/sliver_surface_list.dart`): at paint time it draws one
  rounded `surfaceContainer` rectangle over each group's built rows and
  clips their content and ink to it. Rows never pick corners by position
  and never change parent when a group opens or closes, so the outline
  follows rows growing in, folding away and leaving (no frame shows a
  square corner) and a header keeps its element and the ripple of the tap
  that opened it. Do not split a group into its own slivers or reparent
  rows with `GlobalKey`s: a deactivated element drops its ink. Each group
  header carries the gap above its group as top padding (`leadingGap`),
  so the gap leaves with the header. Groups start
  collapsed. Hierarchy is expressed by the shared surface, a smaller
  child thumbnail, and text-column alignment, not by indentation alone.
- **Status color is icon-only.** Status text stays on the secondary text
  color (`onSurfaceVariant`); only the status icon carries the semantic
  color (`success`/`warning`/`danger`/primary). Tinted status text was
  measured below the 4.5:1 contrast floor on `surface`, so the icon
  carries the signal and the text stays readable.
- **Progress bars are unfinished-only.** Terminal and paused rows show
  none; an unknown total renders the bar indeterminate.
- **Thumbnail first.** Rows lead with a square artwork thumbnail decoded
  at display size through `PixivImage` (shared cache + Referer); a
  missing URL falls back to a neutral placeholder, never to a metadata
  fetch.
- **Text wraps; content titles stop at two lines.** Status lines and
  failure reasons are UI text and wrap in full. A work title is user
  content: two lines on phones, one on wide rows. A group header title is
  mostly app copy ("Batch download · N items") and wraps in full
  (`titleWraps`).
- **Selection mode uses `selectionAppBar`.** The title is the bare count
  (see the Multi-Locale Layout Contract).

## Settings Rows and Groups

Settings pages compose shared rows inside `SettingsGroup`
(`lib/app/widgets/settings/`). `SettingsSection` is deleted — do not
reintroduce it or hand-build group containers.

- `SettingsGroup` owns the group chrome: an optional `title` rendered as
  a `Semantics(header: true)` label in `titleSmall`/`onSurfaceVariant`
  (never `primary` — the brand color is reserved for actions, selection,
  and indicators), the rows as an M3 Expressive segmented list, and an
  optional `footer` rendered below the rows. Every child is its own
  `surfaceContainer` `Material` (clip `antiAlias`, so ink stays inside the
  segment), `SettingsGroup.segmentGap` (2dp) apart; `segmentRadius(index,
  count)` gives the group's outer edge `FuncShape.card` corners and every
  edge facing another segment `FuncShape.segment`. A single-row group is
  one card. A `separated` group (the me page's settings list, never a
  settings page) sets its rows `separatedGap` (8dp) apart, each with
  `FuncShape.card` corners on every side. A composite control (a text field in
  `SettingsGroupContent`) is one child and therefore one segment — the
  group never splits a child. Explanatory copy that used to sit above the
  rows belongs in `footer` so the rows come first. Empty `children` render
  no segment. The gap is the only separator — never `Divider`. Under a
  `RemovalScope`, a `Removable` child in `leaving` no longer counts: the
  other segments take their final corners and the gap above the leaving
  row (or above the new first row) closes as the exit starts, both on the
  `spatialFast` spring the row collapses on, so the commit moves nothing.
  Removable segments are keyed by id, so gap and corner state follow
  their row across the commit.
  Spacing between groups is `FuncSpacing.xl`; the page `ListView` keeps
  only `top: sm, bottom: xl` padding because the group supplies the
  horizontal margins.
- Row types — all built on `ListTile`/`SwitchListTile`, so existing
  `find.widgetWithText(ListTile, …)` tests keep working:
  - `SettingsTile` navigates to a subpage: optional `icon`, drawn
    `onSecondaryContainer` in a 40dp `secondaryContainer` circle (the
    settings index's category rows), chevron trailing.
  - `SettingsControl` is the `SwitchListTile` toggle; it plays the
    toggle haptic (see Haptics Contract). `onChanged: null` disables the
    row (a setting the platform cannot honour yet, e.g. system colors
    while the palette loads). `contentPadding` lines the row up inside an
    already padded form (the bookmark sheet).
  - `SettingsMenuTile<T>(title:, value:, options:, onChanged:, icon:,
    haptics:)` is a setting with one value from two to four options
    (asserted; a longer list is an inline group of `SettingsChoiceTile`s):
    title, and at the row's end the current option's label (subtitle look,
    at most 160dp, ellipsized) with `Icons.arrow_drop_down`. A tap opens
    an `AppMenuButton` menu anchored to the row and lined up with its end
    edge — below the row, under the value, never over the title (outside
    press and back close it); every option is checkable and the
    one matching `value` is checked — `options` are `AppMenuEntry`s whose
    own `checked` is ignored. A different pick plays `select` (unless
    `haptics: false`) and calls `onChanged`; the current one changes
    nothing; `onChanged: null` disables the row. Explanations go in the
    group `footer`. Owning tests: `settings_test.dart` (current value,
    checked semantics, value at the row end, menu below the row on its end
    edge, back closes, write and update),
    `selection_controls_haptics_test.dart`.
  - `SettingsChoiceTile` is one option in a single-choice list. It always
    sets `ListTile.selected` and, when selected, shows a `primary`
    `Icons.check` trailing. `RadioListTile` is deprecated in this Flutter
    version; the check is the single-choice marker, and `selected` is
    what lets screen readers announce the chosen row. It plays `select`
    when a different entry is picked, and takes `contentPadding` so dialog
    options (backup import strategy) use it too.
  - `SettingsActionTile` shows a current value, runs an action, or
    presents read-only info; `onTap: null`/`enabled: false` disables the
    row and its ink.
  - `SettingsGroupContent` holds non-row controls (text fields,
    sliders, buttons) inside the group with
    `horizontal: lg, vertical: sm` padding.
- Hand-written `ListTile`s are allowed only for content rows — entries
  that are data rather than settings (muted items, the account list,
  diagnostic results, the read-only download path, the dashboard's
  account row).
  `test/architecture/settings_rows_test.dart` pins the exact per-file
  `ListTile(` count; adding a hand-written row means extending that
  whitelist with a stated reason.

**Settings search and anchors.** `lib/features/settings/settings_catalog.dart`
is the whole search index: `enum SettingsPageRef` (path, title key,
`parent` page, `indexed`) and `enum Setting` (page, title key or null for
an untitled choice group, `optionKeys`, `extraKeys`, `available`). A new
setting is added there and nowhere else.

- Every row type, `SettingsGroupContent` and `SettingsGroup` take an
  optional `setting:` (`SettingsEntry`, the interface in
  `app/widgets/settings/settings_anchor.dart` that keeps `app/` free of
  `features/`). Given one, a row takes its title from it and wraps
  itself in a `SettingAnchor`. A row that opens a subpage passes the
  subpage's `SettingsPageRef`. A choice group, a block whose rows depend
  on state (credential rows, server settings) or a composite block is
  anchored on the group; its conditional rows' titles go in `extraKeys`.
- `searchSettings(l10n, query)` matches the current locale's titles,
  options, extras and page names, case- and whitespace-insensitive.
  Title prefix hits rank first, then title substrings, then
  option/extra hits; catalog order breaks ties. A result row is the
  matched text over its page path (`›`-joined), and opens
  `Setting.location` (`<page path>?focus=<id>`).
- Every settings route is wrapped in `SettingsFocusScope(target: focus)`.
  After the first frame it `ensureVisible`s the target anchor (alignment
  0.2, `medium` / `fastCurve`). If a lazy list has not built the target,
  it pages down by the viewport, at most 20 times. The anchor then shows
  a `primary` wash at 12% that holds for `settingHighlightHold` and fades
  over `settingHighlightFade`. Reduced motion keeps the hold and drops
  the fade. A group anchor leaves the wash to its segments
  (`SettingHighlight`), so the wash follows the segment corners.
- `test/settings_search_test.dart` renders every settings page and
  requires its anchors to equal its catalog entries, each showing its
  title and options, with no settings row left unanchored. It also
  searches every entry by every term in all four locales and covers
  result → reveal → mark and back-to-results through the router.

**Me tab layout.** The fifth shell destination is `homeMe`; its root
`/settings` is `MeDashboardPage`, and every `/settings/*` sub-route is
unchanged. Top to bottom:

1. The account row: a 58dp avatar, the name, and `labelValue(accountId,
   id)`. Tapping it calls `openMe`; signed out it shows `login` and calls
   `openLogin`. Its trailing `switch_account_outlined` button opens
   `/settings/account`.
2. My content, after Shaft's me page (user decision 2026-10-09, option
   乙, with more room between the sections than the prototype):
   - three cards 12dp apart, one height (the tallest label): each a
     `surfaceContainer` card with a 40dp rounded square in an accent
     container — bookmarks `primary`, following `tertiary`, download
     tasks `secondary` — over a `bodyMedium` label. Bookmarks and
     following call `openMe(tab: MeTab.…)`, which pushes `/me?tab=`; the
     download tasks square carries a `Badge` counting active tasks;
   - under them a row of four plain entries (`onSurfaceVariant` icon,
     no container): watchlist, history, watch later, local novels. Below
     80dp per entry (scaled by `textScaler`) they go two to a row;
   - labels wrap between words, never inside one; each row shares one
     `LabelFit` scale.
3. The settings pages (theme through about — not account, which the
   account row owns, nor the frame probe) as `SettingsTile`s with the
   index's icons (`settingsPageIcons`) and no summaries, in a
   `separated` group (user decision 2026-10-09: always listed, no fold,
   and room between the rows). The group's heading is "settings" with a
   search button that opens `/settings/all`, whose search field is on
   top.

`SettingsPage` is the settings index with a `SearchBar` in the app bar's
`bottom`. Typing swaps the groups for the results; an empty result shows
`FeedEmpty`. The index's groups are: account; appearance (theme,
language, translation, motion & haptics); browse (browse settings and
the muted list); network & downloads; data (backup); the untitled about;
and the conditional developer group.

Page ownership:
- `/settings/motion` holds transition style, animation speed, reduced
  motion, press feedback and haptic strength.
- Credential export lives in account management.
- The history record/Pixiv switches and delete-all live in the history
  page's overflow menu. There is no history settings page and no
  `/settings/history/view` route.

## First-Load Skeletons

A feed or detail page's *initial* load paints a skeleton that mirrors
the loaded layout — never `FeedEmpty`, a blank area, or a spinner alone.
Shared pieces live in `lib/app/widgets/skeleton/` (`FuncSkeleton`,
`SkeletonBone`, `IllustGridSkeleton`); page-shaped skeletons live with
their feature (`IllustDetailSkeleton`, `ProfileSkeleton`).

- `FuncSkeleton` paints every descendant `SkeletonBone` in the ambient
  `surfaceContainer` — the same color `PixivImage` resolves as its image
  placeholder, so the swap to real content does not shift the surface.
  One shared `AnimationController` (`MotionTokens.shimmer`, 1400 ms,
  `repeat()`) drives a diagonal highlight sweep across the whole
  skeleton.
  - Each `SkeletonBone` paints its own slice of one gradient. The gradient
    spans the outermost skeleton's box, which is also a repaint boundary.
  - So there is no `ShaderMask` and no other offscreen layer. A full-page
    mask cost an offscreen layer on every frame the skeleton was up.
  - Bones never run their own animation and never hard-code a color.
    Colors and the shared sweep come from `FuncSkeleton`'s inherited
    widget.
- Nesting: a `FuncSkeleton` under another one (a page skeleton embedding
  `IllustGridSkeleton`) renders its child as-is: no controller, no second
  gradient root, no second semantics node. The outermost skeleton owns all
  three.
- Reduced motion: when `MotionTokens.enabled(context)` is false, the
  controller never starts and the bones paint a static fill.
  `didChangeDependencies` tracks the toggle.
- Semantics: `FuncSkeleton` exposes exactly one node —
  `Semantics(label:, container: true)` wrapping
  `ExcludeSemantics(child: …)`. The label is a localized loading string
  (`context.l10n.contentLoading` or a page-specific `*Loading` key).
- `IllustGridSkeleton` mirrors `IllustFeedGrid`: columns come from the
  same `illustColumnsFor(maxWidth - padding.horizontal)` call, and its
  `padding`/`mainAxisSpacing`/`crossAxisSpacing` must be passed the same
  values as the real grid beneath it, so loaded cards land where bones
  stood. It fills the viewport and clips (`ClipRect`/`OverflowBox`); it
  never scrolls.
- First load only. Skeletons cover `AsyncValue.loading` /
  `showInitialSpinner`. Refresh and load-more keep the loaded list — see
  the Shared Pull-to-Refresh Contract — and a refresh must never collapse
  back to the skeleton. Surfaces with no grid-shaped layout (novel
  detail, novel/user search results, novel-type feeds) use
  `FeedLoading(label:)` instead, keeping the label visible under the
  spinner.
- `IllustDetailSkeleton` renders only when the route has no
  `initialEntity` snapshot — the snapshot first frame and Hero hand-off
  are untouched. `ProfileSkeleton` mirrors the C3 no-cover header
  geometry — the avatar centre and the name's top edge match the real
  header exactly (pinned by a test in `user_profile_test.dart`); its
  `surfaceContainerHigh` banner band is structural (painted beneath the
  skeleton, no shimmer), and it keeps a real `BackButton` outside
  `ExcludeSemantics` so the page can be left while loading. It clips
  rather than overflows on short viewports.
