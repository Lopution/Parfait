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

Use `MotionTokens` for shared UI and route durations. A visible image keeps
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

## Material 3 Theme Contract

`replicaTheme(Brightness)` is the single source of light/dark `ThemeData`.
`ColorScheme.fromSeed` uses `FuncTokens.primary`, while semantic background,
surface, text, subdued, and error values are mapped from `FuncTokens` for the
current brightness. AppBar, NavigationBar, NavigationRail, SegmentedButton,
TabBar, Card, Chip, Dialog, BottomSheet, SnackBar, and Switch styles are
defined there.

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
`EntityRow`) use `primaryContainer`/`onPrimaryContainer`. Known legacy: the
secondary text on a selected row is ~4.15:1 in the dark theme — below the
4.5 target; tracked for a later fix, do not "repair" it ad hoc.

**Component text styles.** Component themes (`appBarTheme.titleTextStyle`,
`snackBarTheme.contentTextStyle`, `chipTheme` label styles,
`dialogTheme` title/content, `navigationRailTheme` label styles) derive from
the *resolved* `theme.textTheme` in the trailing `copyWith` block of
`replicaTheme` — never from a raw `TextStyle` inside `ThemeData(...)`. Raw
styles drop the Montserrat family (AppBar/SnackBar/Chip/Dialog install the
style wholesale via `DefaultTextStyle`, no merge) and fall back to the
platform font for Latin glyphs. Explicit sizes/weights stay; only family,
letter spacing, and line height come from the text theme.

**SnackBar.** Transient feedback uses `inverseSurface`/`onInverseSurface`
with `inversePrimary` actions, so a SnackBar reads as inverted chrome on
both themes. Do not restyle it to a container tier.

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
- **Root default.** `PixivFuncApp`'s `MaterialApp.router` builder wraps the
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
  never thrown or silently dropped. `PixivFuncApp.initState` enters
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

`HomePage` renders one M3 `NavigationBar` with the five localized
`NavigationDestination`s. Its selected index comes from
`StatefulNavigationShell.currentIndex`, and destination selection calls
`goBranch`. Branch selection is owned by the shell; the destination callback
does not create a second tab controller or animation.

The shell continues to publish the rendered bar bounds through
`homeShellMetricsProvider`. The bar publishes at the end of its first frame
after mount — consumers never see a permanent null gap between layout and
the first measurement. `bottomNavTop` and `bottomNavHeight` are the bar's
resting position: the measured box sits outside both `SlideTransition`s,
whose offsets only move its child, so a sample taken mid-slide still reads
the resting geometry. Motion and Hero code uses those measured bounds, not
a copied navigation-bar height.

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
`RootSwipeSwitcher`. `app_type_switch_test.dart` proves both — a fitting
row under `FuncScrollBehavior` hands the swipe to an enclosing horizontal
drag detector, and sideways drags on fitting and overflowing rows never
call `onRefresh` — and the `a sideways swipe from the type row` group in
`new_content_feed_test.dart` repeats them on the real feed.

The sliver form clamps `constraints.overlap` at zero before handing it to
`SliverFloatingHeader`. `PullToRefresh` lays out non-clamping, so an
overscroll hands the first sliver a negative overlap; unclamped, the header
parks at the viewport top while the list overshoots and the refresh
indicator paints over the switch row. The clamp keeps the row traveling
with the list while positive overlaps — which the Hero return clip reads —
pass through untouched. `app_type_switch_test.dart` proves the row's top
edge tracks the first card's during a pull; `new_content_feed_test.dart`
repeats that on the real feed and adds that the indicator bottom stays at
or above the row top.

`AppTypeSwitch` enables `emptySelectionAllowed` and reports an empty
selection as the current value, so a tap on the active segment reaches
`onSelected` as a re-tap — hosts map it to scroll-to-top, matching the
Branch Re-tap Contract. Loading, error, and empty feed states keep the
selector reachable by rendering the box form as a fixed header above the
status widget; only a loaded feed uses the floating sliver.

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
clearance is computed once by `appSnackBarShellMargin` from
`homeShellMetricsProvider`; branch snackbars and app-level snackbars on the
root messenger share the same margin so both rest above the bar.

Widget tests for this contract pump `material_ui`'s `MaterialApp` and query
`material_ui`'s `SnackBar` and `ScaffoldMessenger` types. Cover both stale
queue replacement and an explicit ordered sequence.

## Route Restoration Contract

`MaterialApp.router`, `GoRouter`, the shell, and each branch use stable
restoration scope IDs. Feed scrollables use their stable `PageStorageKey` and
`restorationId`; the key preserves in-process tab/mode switching and the
restoration ID covers the Flutter restoration bucket.

Ranking mode, search input/filter, and viewer page are durable path/query
values and are updated through the route facade. An entity or input passed as
route `extra` accelerates the first frame but is not the restoration source.
The router instance stays stable while settings, account, or providers update.

## Predictive Back Contract

The Android application enables `android:enableOnBackInvokedCallback`. Pages
use `PopScope.onPopInvokedWithResult`; `WillPopScope` is not part of the app
route model. go_router first pops the current branch stack. At a branch root,
the shell delegates to `RootBackCoordinator` for the existing double-back exit
window.

Pages with local edit state, such as `ProfileEditPage`, keep their
`canPop`/confirmation behavior in their own `PopScope`. Navigation changes
must not bypass that confirmation or reset the branch stack.

An immersive page restores the system bars on the *successful* pop path:
`onPopInvokedWithResult` fires with `didPop == true`, so the novel reader
calls `setSystemUiMode(SystemUiMode.edgeToEdge)` there — the previous route
needs its status bar while the pop animation is still on screen — and again
in `dispose` as the fallback for pop paths that never notify.

## Hero Drag Contract

`DragToDismiss` is shared by the still image viewer and Ugoira surface. It
accepts a downward drag while the still viewer is at 1x, translates/scales/
fades the surface with the drag, and returns with `MotionTokens.fast` when the
drag is canceled or below threshold. A qualifying drag pops the current typed
route so the existing `CustomTransitionPage`, scoped Hero tag, and
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
- The waterfall card is the only Hero endpoint that carries a visible
  boundary. `IllustHeroCardFrame` wraps the card's Hero child — `ClipRRect`
  at `FuncShape.card` plus a foreground hairline in the semantic `divider`
  color. The shuttle recognizes the frame on the card side and paints the
  same hairline into the overlay, fading its alpha to zero across the flight
  (`× 1 - progress`); the border and the clip share one interpolated
  `BorderRadius`, and the color resolves through the card-side context.
  Detail→viewer flights have no card endpoint and draw no border. The frame
  must live **inside** the Hero child: a border drawn outside the Hero stays
  on the route during flight (a stationary ghost) and pops back in on
  landing.
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

`TabBar` owns the `TabController.animateTo` call for a tap. A tab's `onTap`
callback may update selected state, lazy-build bookkeeping, or an auxiliary
selector, but must not call `animateTo` for the same index. Starting a second
animation from the callback resets the indicator/body flight and produces a
visible stall on fast taps. Programmatic selection may call `animateTo` only
when it did not originate from the `TabBar` tap callback.

## Branch Re-tap Contract

A tap on the bottom-bar destination that is already active is the re-tap
gesture. `BranchSlidePager.selectIndex`
(`lib/app/widgets/branch_slide_stack.dart`) detects it, calls
`goBranch` (a no-op on the live branch), pops the branch Navigator to its
root — a `PopScope`-vetoed route (`doNotPop`) cuts the pop short — and
fires `reTapEvents`.

- `reTapEvents` is a `ReTapChannel` (`ChangeNotifier`): an edge, not a
  state. Every same-destination tap emits, including consecutive taps on
  the same index — a `ValueNotifier<int>` carrying the branch index would
  swallow repeats.
- `syncIndex`, drag settles, and programmatic moves never emit.
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

Owning tests: the `re-tap channel` group in
`test/root_swipe_switcher_test.dart` (emit-once-per-tap, pop-to-root,
sync/drag silence), plus per-page re-tap cases in
`test/new_content_feed_test.dart` and `test/search_catalog_test.dart`.

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
  tab body owns one nested `PullToRefresh` wrapper, following PixEz's
  `EasyRefresh` locator pattern. Do not add another wrapper around the whole
  `NestedScrollView`. Ordinary lists use the default `isNested: false` path.
- Touch scroll physics are unified app-wide through `FuncScrollBehavior`:
  `BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics())` plus no
  platform overscroll indicator — the same scheme `_ERScrollPhysics` installs
  inside `PullToRefresh` subtrees, so non-feed pages (detail, settings,
  search) and `NestedScrollView` outer scrolls share the feed's feel. Do not
  reintroduce a `ClampingScrollPhysics` region.
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
entry point for the app. Feature code must never call
`HapticFeedback` directly — every trigger goes through the owner so the
persisted `enableHaptics` setting, per-level throttling, and platform
tolerance stay in one place.

- Consumers name a **role**, never a level: `select()` (selection
  toggles, mode exits, copy), `confirm()` (entering a management/
  selection mode, opening a batched or destructive action surface),
  `success()` (a save/download/share submission landed) and `error()`
  (the attempted action failed). The role→`HapticFeedback` level mapping
  and per-level throttling live inside `AppHaptics`; adding a role needs
  a real consumer.
- The enabled reader is injected by `PixivFuncApp.build` via
  `AppHaptics.configure`; feature code never reads settings itself.
- Haptics are a redundant feedback channel: with the toggle off or on a
  platform without haptics support, all visual feedback must still be
  complete and distinguishable.
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
