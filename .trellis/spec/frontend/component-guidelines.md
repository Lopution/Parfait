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
  background needs a `divider`-token hairline border to stay legible —
  same-value fills blend in both themes (`TagChip`, `_ActionPill` in
  `comment_item.dart`).
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
NavigationRail, SegmentedButton, TabBar, Card, Chip, Dialog, BottomSheet,
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
control states (`SegmentedButton`, `NavigationRail`, `NavigationBar`,
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

**AppBar scrolled-under.** `appBarTheme.backgroundColor` must stay a
`WidgetStateColor` that resolves `colorScheme.surface` at rest and
`colorScheme.surfaceContainer` under `WidgetState.scrolledUnder` — M3's
"tint when content scrolls beneath" without an elevation overlay. Feature
`AppBar`s never set a background. For a page whose tabs each own a
scrollable, pick the rule by the tab body, not by hand:

| Tab body | Scroll-notification depth | Rule |
|---|---|---|
| `TabSlideStack` (no Scrollable ancestor; list depth 0) | 0 | Default judgement is already the visible list — call `announceTabScroll` after each switch |
| `TabBarView`/`PageView` wrapping the list | 1 | `AppBar(notificationPredicate: (n) => n.depth == 1)` |

The AppBar only reacts to `ScrollUpdateNotification`, so after a tab switch
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
`onSelected`) — not a `NavigationBar` — because the M3 widget sizes its
indicator to the label while this app paints the fixed pill. Each item
renders a 56×32 `NavigationIndicator` stadium behind the icon
(`FuncBottomNav.indicatorSize`), cross-faded by a per-item selection
controller; the ink response is clipped to that pill, so splashes never
cover the label. Item semantics mirror `NavigationBar`'s: the destination
exposes its localized `tabLabel` plus the selected flag, so screen readers
announce "selected, <label>, tab, N of 5". Labels are laid out through
`LabelFit` with a hard 1.3 scale cap — above `textScaler` 1.3 the label
stays at 1.3 so the row cannot outgrow the 64dp bar.

The shell publishes the bar's resting extent through `HomeShellChrome`, an
InheritedWidget `HomeBranchStack` wraps around the strip and the bar —
computed synchronously, not measured post-layout:
`rail ? 0 : FuncBottomNav.restingExtent(MediaQuery.paddingOf(context).bottom)`.
`restingExtent` is the fixed `_height` row plus the bottom safe-area inset
the bar's own `SafeArea` adds, and nothing between the stack and that
`SafeArea` strips the inset, so the computed value equals the rendered bar
height on the very first frame. `FuncNavBarSpacer`, `showAppSnackBar`'s
branch margin and the Hero landing clip all read the same extent — no
consumer measures or copies the bar geometry.

The bar also slides out (covered by a pushed route, or scroll auto-hide), so
`HomeShellChrome.bottomBarVisibleExtent` publishes the height it covers *right
now*: `FuncShellBottomNav` computes it from the same two `CurvedAnimation`s
that drive its `SlideTransition`s. The Hero landing clip caps the home-side
edge with it per frame, so a returning image is not cut at a bar that is not
there yet. Consumers read `.value` and never listen — the bar writes it from
its own `build`. Everything else keeps the resting extent. On NavigationRail layouts the
extent is 0 and no `FuncShellBottomNav` exists. The only consumer that
cannot reach the scope is the root-messenger update prompt; it reads the
`homeShellBarVisibleProvider` presence flag (`FuncShellBottomNav` publishes
it on mount/deactivate) and recomputes the same formula from its own
context's padding.

Scroll auto-hide yields to touch exploration: while
`MediaQuery.accessibleNavigationOf(context)` is true,
`HomeBranchStack._onScrollNotification` returns early — a TalkBack user
cannot find a bar that scrolled away. If the flag flips while the bar is
hidden, `_navVisibility` is driven back to 1. `accessibleNavigation` tracks
only TalkBack-style touch exploration; services that merely open the
semantics tree (for example `tester.ensureSemantics()`) do not set it, and
the bar keeps hiding on scroll for them. A pushed route covering the shell
still slides the bar away — that is not auto-hide.

The five labels share one `LabelFit` (see the Multi-Locale Layout
Contract): the widest translation sets one scale for all of them against
the slot `itemWidth − 2 × 6`, floor 0.8, and past the floor every label
ellipsizes with a tooltip. The labels are measured and painted in one
style — the ambient `DefaultTextStyle` merged with the bar's 12sp label
style — so one shared scale keeps every destination identical.
`func_bottom_nav_test.dart` pins the shared scale, the tooltip, the pill
geometry, the 1.3 cap, the pill-clipped ripple, and the selected
semantics.

## Top Tab Contract

`AppTabBar` is the single entry point for top-of-page tab rows; feature
pages do not instantiate a raw `TabBar`. It measures the widest label in
both label styles at the ambient text scale: when that label plus its
horizontal padding fits an equal share of the row width, the tabs divide
the width evenly (`TabAlignment.fill`); otherwise the row switches to
`isScrollable` and aligns from the start edge. Labels render at the themed
14sp (`replicaTheme` sets the `TabBarTheme` label styles) and are never
shrunk to fit — overflow always resolves through scrolling, not smaller
text. `onTap` is passed through to `TabBar.onTap` unchanged; per the Tab
Navigation Animation Contract a re-tap handler must not `animateTo` the
already-selected index.

## Compact Type Switch Contract

`AppTypeSwitch` is the shared compact segmented selector for a feed's
content type. The box form is a left-aligned row at least the minimum
interactive height tall (48dp at the default text scale; larger text grows
it) whose segments scroll horizontally when they overflow.
The sliver form, `SliverAppTypeSwitch`, is the same row wrapped for use as
the first sliver of a feed: it scrolls away with the content and floats
back in on an upward drag, animating with the bottom-bar show/hide
`MotionTokens` (or `AnimationStyle.noAnimation` under reduced motion).

The row scrolls on its own parentless `BouncingScrollPhysics`, installed
with `ScrollConfiguration.of(context).copyWith(physics: ...)`, so it takes
horizontal drags only when its segments overflow. Inherited physics would
break two things: inside `PullToRefresh` a sideways drag would arm a
refresh (see the Shared Pull-to-Refresh Contract), and
`FuncScrollBehavior`'s always-scrollable parent would let a row that fits
claim the drag, so a swipe starting on it would never reach
`TabSwipeSwitcher`. `app_type_switch_test.dart` proves both — a fitting
row under `FuncScrollBehavior` hands the swipe to an enclosing horizontal
drag detector, and sideways drags on fitting and overflowing rows never
call `onRefresh` — and the `the work type row on a real feed` group in
`user_profile_test.dart` repeats the refresh half on a real profile feed.

The sliver form clamps `constraints.overlap` at zero before handing it to
`SliverFloatingHeader`. `PullToRefresh` lays out non-clamping, so an
overscroll hands the first sliver a negative overlap; unclamped, the header
parks at the viewport top while the list overshoots and the refresh
indicator paints over the switch row. The clamp keeps the row traveling
with the list while positive overlaps — which the Hero return clip reads —
pass through untouched. `app_type_switch_test.dart` proves the row's top
edge tracks the first card's during a pull; `user_profile_test.dart`
repeats that on a real profile feed. Neither test asserts the refresh
indicator's bottom against the row top.

`AppTypeSwitch` enables `emptySelectionAllowed` and reports an empty
selection as the current value, so a tap on the active segment reaches
`onSelected` as a re-tap — hosts map it to scroll-to-top, matching the
Branch Re-tap Contract. Loading, error, and empty feed states keep the
selector reachable by rendering the box form as a fixed header above the
status widget; only a loaded feed uses the floating sliver.

The profile page is the only consumer. The new-works page no longer
switches type in place: its illustration page carries a book action in the
AppBar (`newNovels` tooltip) that pushes the common `new-novels` route —
the same `NewPage` with `type: NewFeedType.novel` and no book action —
mirroring how the novel ranking opens. Each page keeps its own scope in the
URL (`/new?scope=` and `.../new-novels?scope=`); an old `type=novel` link
lands on illustrations. Each profile feed
(`ProfileIllustFeed`, `ProfileNovelFeed`, `UserSeriesFeed`) takes a
`typeSwitch` sliver parameter and inserts it *after*
`HeaderLocator.sliver()` inside the nested list — the locator must come
first so the shell can find it — while loading, error, and empty states
render the switch through `aboveState` so it stays reachable. The profile
tab delegate (`ReplicaProfileTabsDelegate`) no longer hosts the switch:
it is a constant 56dp `AppTabBar`; the old 64dp `ChoiceChip` row is gone.

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
- No layout errors (overflow) in any locale or profile.
- A widget that measures its own text (the bottom bar, `AppSegmentedButton`)
  measures with the exact style and text scaler it paints with, so the
  measured width equals the painted width.

### 3. Fix order

When a cell fails, fix it in this order, never with a per-language branch:

1. **Wrap**: body copy, explanations, settings titles and subtitles,
   dialog text, status lines, rows of buttons (`Wrap`, `OverflowBar`).
   Remove `maxLines`/`ellipsis` from UI text; give text-field helpers
   `helperMaxLines`.
2. **Scroll**: tab rows (`AppTabBar`) and `AppTypeSwitch`, per their
   contracts.
3. **Uniform scale**: groups of compact labels share one `LabelFit`
   (bottom bar, segmented buttons), floor 0.8.
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

// lib/app/widgets/app_segmented_button.dart
final class AppSegment<T> { const AppSegment({required T value, required String label}); }
class AppSegmentedButton<T> extends StatelessWidget {
  const AppSegmentedButton({required List<AppSegment<T>> segments,
      required T selected, required ValueChanged<T>? onSelected,
      VoidCallback? onReselected, bool haptics = true});
}

// lib/app/widgets/selection_app_bar.dart
AppBar selectionAppBar(BuildContext context, {required int count,
    required VoidCallback onClose, required List<Widget> actions});
```

- `LabelFit.group` fits the widest label in `slotWidth`; an unbounded slot
  never scales. One pixel of slack keeps rounding at the scaled size from
  ellipsizing the widest label. `FitLabel` never measures (it works under
  intrinsic-size queries); the host computes the fit from the slot it lays
  out.
- `AppSegmentedButton` is the only place that builds a `SegmentedButton`
  (`test/architecture` enforces it). Single choice, equal-width segments,
  no check icon — the selected fill marks the choice, so labels never shift
  when the selection moves. Padding is explicit (`FuncSpacing.md` per side)
  and the label style is `labelLarge`, so the slot it measures against,
  `maxWidth / n − 2 × (padding + density dx)`, is the slot it paints in.
  A different pick plays the select haptic unless `haptics: false`;
  `onReselected` makes a re-tap on the selected segment reach the host.
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
- `fit_label_test.dart`, `app_segmented_button_test.dart`,
  `func_bottom_nav_test.dart`: measured width equals painted width; the
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
  AppSegmentedButton(...),            // unbounded in a Row: overflows in ru
]);
FittedBox(child: Text(l10n.follow));  // shrinks to 0.5 in long locales
Text(l10n.illustDetailCreateDate(date), overflow: TextOverflow.ellipsis);
```

#### Correct

```dart
Wrap(                                 // the switch drops under the title
  alignment: WrapAlignment.spaceBetween,
  crossAxisAlignment: WrapCrossAlignment.center,
  children: [Text(l10n.searchTrending), AppSegmentedButton(...)],
);
FitLabel(l10n.follow, fit: fit);      // one shared scale, floor 0.8
Text(l10n.illustDetailCreateDate(date)); // wraps
```

## Profile Header Contract

`ReplicaProfileHeaderDelegate`
(`lib/features/profile/profile_header_delegate.dart`) owns the profile
page's flexible header.

**Measured extent.** `maxExtent` is never hard-coded for text-bearing
content. The identity block (banner spacer, action row, name/account
lines, statistics grid) lays out at natural height inside an
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

**Statistics.** `ProfileStatistic` cells render through
`ProfileStatisticsGrid`: equal-width columns, column count chosen
6 → 3 → 2 → 1 by the widest intrinsic cell, row height set by the tallest
cell in the row. There is no horizontal scroll ancestor — all six stats
stay on screen.

**Tests Required** (`test/user_profile_test.dart`):

- R1, both conditions — 360×640 / `textScaler` 2.0 / `ru` and 411×891 /
  1.0 / `zh`: no layout exceptions; every action and statistic rect ends
  at or above the tab bar's top edge; the measured extent tracks
  refreshed identity content; a drag collapse/expand changes the header
  height monotonically with no jumps.
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
an optional icon, `enabled`, and `checked` (non-null renders a trailing
check and checked semantics); `onSelected` receives the anchor's context;
`style` forwards to the default `IconButton` (over-artwork palette);
`anchorBuilder` replaces the anchor (the reverse-image engine chip). The
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

Owning tests: `app_menu_button_test.dart` (outside press closes, no
scroll or tap passes through, back closes the menu first, checked and
disabled rows, reduced motion, 320-wide ru truncation) and
`app_overlays_test.dart` (drag-release closes one layer, release over the
content keeps it open, non-dismissible stays, scrim dismiss action).

## SnackBar Feedback Contract

`showAppSnackBar` and `showAppSnackBarOn` are the only app SnackBar
presentation helpers. An ordinary new message clears stale queued messages,
lets the current message use its standard exit animation, then presents the
new message. Callers that communicate ordered steps must pass
`replaceCurrent: false`; for example, the account-transfer clipboard warning
follows its copy confirmation. Keep duration, action, shell-bar margin, and
reduced-motion behavior within the shared helpers.

An action button no longer implies a persistent snackbar — `material_ui`
defaults `SnackBar.persist` to `action != null`, so the helpers pass an
explicit `persist` that is true only when
`MediaQuery.accessibleNavigationOf` reports assistive navigation. Every
other message, action or not, times out on its `duration`. Bottom-bar
clearance is computed once by `appSnackBarShellMargin` from the shell's
computed bar extent (`HomeShellChrome.bottomBarExtent`, or the same
`restingExtent` formula above the shell); branch snackbars and app-level
snackbars on the root messenger share the same margin so both rest above
the bar.

Widget tests for this contract pump `material_ui`'s `MaterialApp` and query
`material_ui`'s `SnackBar` and `ScaffoldMessenger` types. Cover both stale
queue replacement and an explicit ordered sequence.

A reversible action reports through `showUndoSnackBar` (see the Undo
Contract), never through a plain message plus a hand-built
`SnackBarAction`.

## Undo Contract

Reversible actions run immediately and offer Undo; only irreversible ones
(deleting an imported file, clearing history) ask for confirmation first.
Unfollow, unbookmark, unmute and watch-later removal have no confirmation
dialog.

- `showUndoSnackBar(context, message, onUndo:)`
  (`lib/app/widgets/undo_snack_bar.dart`) captures the
  `ProviderContainer`, the messenger and the localizations when it shows.
  Undo plays `AppHaptics.select()` and runs `onUndo(container)`, so it
  still works after the page that offered it is gone. A failed undo is
  recorded in `CrashLog` and reported on the captured messenger (one of
  the approved `showAppSnackBarOn` call sites).
- Bookmarks and follows go through `toggleBookmarkWithUndo(context, key)`
  and `toggleFollowWithUndo(context, userId)` — the only UI entry points
  to `bookmarkActionsProvider.toggle` / `followActionsProvider.toggle`.
  The actions return what a delete removed (`RemovedBookmark` with
  restrict and tags, `RemovedFollow` with restrict); Undo re-adds through
  `addWithRestrict`.
- The snapshot is exact or absent. A bookmark entry is trusted only right
  after an add confirmed in this session (`status == confirmed`): remote
  observations carry visibility but never tags. Otherwise the action reads
  `fetchDetail` (registered tags only) before the delete; a follow with an
  unknown restrict reads `FollowRepository.fetchRestrict`
  (`/v1/user/follow/detail`). When the lookup fails, the delete still
  goes ahead and no Undo is offered — never guess "public": restoring a
  private bookmark or follow as public would expose it. A queued (offline)
  or failed delete offers no Undo either.
- Unmute offers Undo through `showUnmuteUndo(context, MuteKey, user:)`.
  The mute store only toggles, so Undo skips an entry that is muted again
  by then.

Owning tests: `bookmark_actions_test.dart`, `follow_actions_test.dart`
(local snapshot, lookup, failed lookup), `undo_flows_test.dart` (private
and tagged restores, Undo after the page closed, no Undo without the
original visibility), `muted_items_page_test.dart` and
`card_action_test.dart` (unmute Undo).

## Route Restoration Contract

`MaterialApp.router`, `GoRouter`, the shell, and each branch use stable
restoration scope IDs. Feed scrollables use their stable `PageStorageKey` and
`restorationId`; the key preserves in-process tab/mode switching and the
restoration ID covers the Flutter restoration bucket.

Ranking mode, search input/filter, and viewer page are durable path/query
values and are updated through the route facade. An entity or input passed as
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
| `sharedAxis` | `animations` `SharedAxisPageTransitionsBuilder` (horizontal, `fillColor` = `colorScheme.surface`) + back-gesture driver | same, no driver |
| `zoom` | `ZoomPageTransitionsBuilder` + back-gesture driver | same, no driver |
| `slide` | `CupertinoPageTransition` (`linearTransition: popGestureInProgress`) + back-gesture driver | same, no driver |

Every style uses an official transition; none is hand-written. The slide
uses the `CupertinoPageTransition` widget, never
`CupertinoPageTransitionsBuilder`: the builder adds an iOS edge-swipe back
detector that steals horizontal drags from in-page pagers (the detail
pager). Under the slide the route's `barrierColor` is `CupertinoPageRoute`'s
`0x18000000`, dimming the page below; other styles keep the page's own
(null). Fade-through is not offered: it is the transition between unrelated
destinations, not for pushing a page.

The back-gesture driver (`_BackGestureDriver`) is a
`WidgetsBindingObserver` that forwards the Android predictive back events
to the route's `handleStartBackGesture(progress: 1 - event.progress)` /
update / cancel / commit, so the non-system styles follow the finger. It
claims the gesture only for a non-button event while `route.isCurrent &&
route.popGestureEnabled`; the binding then sends the rest of that gesture
to it alone. It mirrors Material's private predictive-back detector
without its visuals — a framework change there shows up in
`func_page_test.dart`'s gesture tests.

The route's commit path is guarded: if a pop throws after the route has
already reported `didPop`, the guard ends any lingering user gesture before
rethrowing. This keeps the Navigator from absorbing later pointers while
leaving the original error observable.
`transitionDuration` is `MotionTokens.pageTransitionAndroid` (350 ms — the
builder's own 800 ms dragged) on Android and `MotionTokens.pageTransition`
elsewhere, both through `MotionTokens.resolve`, so the animation speed
setting scales them and reduced motion collapses them to zero (see the
Motion Contract). FadeForwards scales its phases to whatever duration the
route carries; every style shares the route duration and brings its own
curve, and Hero flights follow the route duration. Every path is wrapped by
`FuncTransitionGuard` — the shared `TickerMode` + `RoutePopSnapshot` pair that
freezes an outgoing page's tickers and snapshots it for the reverse flight;
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

Future<void> PixivImage.preload(
  BuildContext context,
  String url, {
  BaseCacheManager? cacheManager,
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
  sides use the same `PixivImage` headers and cache manager, including the
  first page of a multi-page work.
- All artwork URL/quality hand-offs go through `PixivImage`; callers must not
  add a second per-page "ready" flag or replace the old image with a blank
  loading state. `PixivImage` keeps `useOldImageOnUrlChange` enabled and uses a
  bounded `transitionKey` URL history for Hero endpoints that are rebuilt
  while flying. The previous decoded frame remains visible while the new
  quality resolves, including preview/detail/original changes, every page of
  a multi-page work, and Ugoira covers.
- The normal loading fade is still required for a cold URL. It is disabled
  only when the target provider is already decoded; a cached Hero target must
  appear immediately rather than fading a translucent frame over the route
  background. This is the distinction between a useful first-load transition
  and the white flash regression.
- A feed slot being reused for a different work is a **slot hand-off**, not a
  cold load: `PixivImage` tracks the URL each element last committed to, and
  a changed URL on a live element drops the fade to zero — OctoImage's
  `useOldImageOnUrlChange` retains the old frame and the new one replaces it
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
  card's cover-top rect to the whole contained image, both directions. The
  feed prefetch resolves the same `illustCardPreview` so it warms exactly
  what the card will paint. The feed entrance is a staggered fade only —
  cards never move.
- Detail page page numbers use only `DetailPageCounter`. Narrow and wide
  layouts both place it at the top-right of the artwork region; single-page
  and ugoira works never show it; selection mode hides it because each
  page's selection badge takes the same corner; it appears only after the
  entry transition completes; it is wrapped in `IgnorePointer`; and its
  screen-reader label uses `viewerPageLabel`. The detail page keeps no
  persistent information strip.
- The detail AppBar directly exposes only download-all and the bookmark
  heart. Share, page selection, and artwork-info navigation live in the ⋮
  overflow menu with text labels; no action may depend solely on a long
  press. Artwork-info navigation must reach the lazily built InfoBlock in
  long works.
- Related works load on demand. Opening a detail page sends no
  `/v2/illust/related` request. `RelatedIllustsSlivers` asks for the first
  page only once its section is on screen (`VisibilityDetector`) **and**
  the page is current (`DetailPageActivity`). The detail pager prebuilds
  its neighbours and sets that scope to inactive on every page except the
  committed one. A route outside the pager has no scope and counts as
  active. Before the request, the section shows a **static** box the size
  of the loading spinner: a spinner below the fold keeps producing frames.
  A related list whose provider already exists (`ref.exists`) renders
  straight away. The detail page's scroll-to-bottom paging check may call
  `loadMore` only on an existing, loaded provider. It must never send the
  first request.

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
  control and preserve rich-link behavior.
- Hero flight tests cover a partially visible card, a nested pinned header, and
  a push from a profile-like feed; both directions must move the global clip
  continuously between endpoint chrome boundaries. Tests must inspect the
  actual render-time clip rather than only a widget property.
- Preview tests assert the source URL and detail index-0 Hero URL are equal;
  first-frame tests assert the avatar slot and provider exist before the detail
  request settles.
- Detail counter tests assert a single-page work shows no page number, the
  multi-page counter follows scrolling and hides once scrolling reaches the
  InfoBlock, and a six-page long work reaches the InfoBlock through the ⋮
  menu.

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

## Tab Navigation Animation Contract

Between home-shell branches there is no swipe: `HomeBranchStack` cross-fades
the outgoing and incoming branch through `FadeThroughTransition` over
`MotionTokens.branchSwitch` (a straight swap at zero duration under reduced
motion). Only the current branch is hit-testable, semantic, and
`BranchActivityScope.active` during the flight; `Offstage` keeps unvisited
branches unbuilt.

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
scrollables but below the Scaffold — so the AppBar's scrolled-under state
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
  under reduced motion. Re-tap is pure scroll-to-top — never a refresh,
  a selector toggle, or a selection change.
- In-page re-taps follow the same rule locally, calling
  `reTapScrollToTop` on that slot's own `ScrollController`: a `TabBar`
  `onTap` on the selected index while `!controller.indexIsChanging`, or an
  `AppTypeSwitch` `onSelected` that reports the current value.

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
});
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
  applies it on top of the inherited physics. `AppTypeSwitch` is the
  reference.
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
  off its own segment haptic (`AppSegmentedButton(haptics: false)`).
- The settings footer shows the device tier from `capabilities`; the
  vibrator tiers degrade to `View` haptics on ROMs that refuse them.
- Haptics are redundant: with strength `off` or no vibrator, every visual
  feedback must still be complete.

### 4. Ownership

- **Components own their haptic.** `SettingsControl` and
  `ReplicaSwitchTile` (toggleOn/Off), `SettingsChoiceTile` (select on a
  different entry), `AppSegmentedButton` (select on a different non-empty
  selection), `AppChoiceChip` (single: select, and `onSelected` runs only
  for an unselected chip; `.toggle`: toggleOn/Off), `AppSlider` (tick per
  division; continuous sliders are silent). External value changes never
  vibrate. The architecture test confines raw `SegmentedButton`,
  `ChoiceChip`/`FilterChip`, `Slider`, `Switch`/`SwitchListTile` and
  `Radio`/`RadioListTile` to these wrappers.
- **Store mutations vibrate on the settled outcome, at the call site.**
  `toggleBookmarkWithUndo`, `toggleFollowWithUndo` and `WatchlistToggle`
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
  Callers above `MotionScope` (the `MaterialApp` theme animation, the root
  messenger) use `resolveWith(..., reduce:, speed:)`.
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
  expand/collapse, removal, drag return), `spatialDefault` (bottom
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
| `PressScale` | spring to `MotionTokens.pressScale` while pressed and back, interruptible; off with the press-feedback setting; frozen tickers set the value without playing. Wraps every tappable card. |
| `StateIconSwitcher(value:)` | effectsFast fade plus scale from 0.8 when `value` changes — selection checks, watchlist, download badges. Keyed by state, not by widget instance. |
| `StateFade(kind:)` / `.onMount` | fades the new state in from 0 when `kind` changes (skeleton → content); replaces, never cross-fades. `onMount` for widgets that only appear as a change (`FeedEmpty`, `FeedError`). Keeps semantics during the fade. Frozen tickers and reduced motion show it at once. |
| `SpringSize` | `AnimatedSize` on spatialFast for sections that open and close (`ErrorDetails`). |
| `RemovalScope` / `Removable` | see §4. |
| `DragToDismiss` | the return runs `SpringSimulation(spatialFast, offset, 0, release velocity)` in pixels. |

Feed grids fade cards in through `StaggeredEntrance`; do not add a
`StateFade` around grid content.

### 4. Removal: exit first, then commit

Lists stay driven by their provider. The page state owns a
`RemovalController` and hands it down with `RemovalScope`; each item is
`Removable(id:, style: row | tile)`. To delete: `await
controller.playExit(ids)`, then commit the change, and call
`controller.restore(ids)` when the commit fails. A row collapses and
fades; a tile shrinks to 0.9 and fades and the grid reflows on the
commit. Ids not on screen are skipped and reduced motion completes at
once. Row callbacks read the controller with `RemovalScope.of` (no
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

### 6. Tests

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

## Management List Rows

Management-style lists (Settings → Download Tasks and any future
batch-manageable list) render **rows**, not stacked cards, and follow
these rules:

- **Lazy construction.** The list is a `ListView.builder` over a
  flattened entry model — group header, expanded group children, and
  ungrouped items. Large item sets and large expanded groups must not
  build every row eagerly; row keys (`download-task-*`/`download-group-*`)
  follow the task or group identity.
- **One container per group.** A group's children paint their share of the
  same rounded `surfaceContainer` block as the header — the header rounds
  the top corners, the last child the bottom — and groups start
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
  one card. A composite control (a `SegmentedButton` in
  `SettingsGroupContent`) is one child and therefore one segment — the
  group never splits a child. Explanatory copy that used to sit above the
  rows belongs in `footer` so the rows come first. Empty `children` render
  no segment. The gap is the only separator — never `Divider`.
  Spacing between groups is `FuncSpacing.xl`; the page `ListView` keeps
  only `top: sm, bottom: xl` padding because the group supplies the
  horizontal margins.
- Row types — all built on `ListTile`/`SwitchListTile`, so existing
  `find.widgetWithText(ListTile, …)` tests keep working:
  - `SettingsTile` navigates to a subpage: optional `icon`, chevron
    trailing.
  - `SettingsControl` is the `SwitchListTile` toggle; it plays the
    toggle haptic (see Haptics Contract). `onChanged: null` disables the
    row (a setting the platform cannot honour yet, e.g. system colors
    while the palette loads).
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
    `SegmentedButton`, sliders, buttons) inside the group with
    `horizontal: lg, vertical: sm` padding.
- Hand-written `ListTile`s are allowed only for content rows — entries
  that are data rather than settings (muted items, the account list,
  diagnostic results, the read-only download path, the
  `AccountSummaryTile` identity block).
  `test/architecture/settings_rows_test.dart` pins the exact per-file
  `ListTile(` count; adding a hand-written row means extending that
  whitelist with a stated reason.

**Me tab layout.** The fifth shell destination is `homeMe` (`SettingsPage`
still owns the `/settings` route; the label and icon change, the path
does not). Its group order is fixed: (1) the untitled account card —
signed-in subtitle shows the account ID and taps through to `openMe`,
signed-out shows `login` and taps through to `openLogin`; (2) my content
(`settingsGroupLibrary`): history (`openHistory` — stays on the current
stack), watch-later, watchlist, local novels, download tasks
(`openDownloadTasks`, a root overlay); (3) account (`accountSettings`):
account management only; (4) appearance: theme, language, translation,
motion & haptics (`/settings/motion`); (5) browse (`/settings/browse`,
static `settingsBrowseHint` summary — blocking and image quality live
there) plus the muted list; (6) network & downloads: network (which also
owns the image-source controls), download settings; (7) data: backup;
(8) untitled about; (9) the conditional developer group. Page ownership:
`/settings/motion` holds transition style, animation speed, reduced
motion, press feedback, and haptic strength; credential export lives in
account management; the history record/Pixiv switches and delete-all
live in the history page's overflow menu — there is no history settings
page and no `/settings/history/view` route.

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
  `repeat()`) sweeps a highlight gradient over the whole tree via
  `ShaderMask`; bones never animate individually and never hard-code a
  color (they read it from `FuncSkeleton`'s inherited widget).
- Nesting: a `FuncSkeleton` under another one (a page skeleton embedding
  `IllustGridSkeleton`) renders its child as-is — no controller, no
  `ShaderMask`, no second semantics node. The outermost skeleton owns
  all three.
- Reduced motion: when `MotionTokens.enabled(context)` is false the
  controller never starts and no `ShaderMask` is built — the bones render
  as a static fill. `didChangeDependencies` tracks the toggle.
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
