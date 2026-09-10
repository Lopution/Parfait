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

## Material 3 Theme Contract

`replicaTheme(Brightness)` is the single source of light/dark `ThemeData`.
`ColorScheme.fromSeed` uses `FuncTokens.primary`, while semantic background,
surface, text, subdued, and error values are mapped from `FuncTokens` for the
current brightness. AppBar, NavigationBar, TabBar, Card, Chip, Dialog,
BottomSheet, SnackBar, and Switch styles are defined there.

Feature code reads `ColorScheme`, `TextTheme`, and component defaults from the
ambient theme. `MaterialUiCompatibilityBridge` is installed once in the app
builder for legacy plugin subtrees; feature pages do not add another bridge.

## NavigationBar Contract

`HomePage` renders one M3 `NavigationBar` with the five localized
`NavigationDestination`s. Its selected index comes from
`StatefulNavigationShell.currentIndex`, and destination selection calls
`goBranch`. Branch selection is owned by the shell; the destination callback
does not create a second tab controller or animation.

The shell continues to publish the rendered bar bounds through
`homeShellMetricsProvider`. Motion and Hero code uses those measured bounds,
not a copied navigation-bar height.

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
