# Component Guidelines

> How components are built in this project.

---

## Overview

<!--
Document your project's component conventions here.

Questions to answer:
- What component patterns do you use?
- How are props defined?
- How do you handle composition?
- What accessibility standards apply?
-->

(To be filled by the team)

---

## Component Structure

<!-- Standard structure of a component file -->

(To be filled by the team)

---

## Props Conventions

<!-- How props should be defined and typed -->

(To be filled by the team)

---

## Styling Patterns

<!-- How styles are applied (CSS modules, styled-components, Tailwind, etc.) -->

(To be filled by the team)

---

## Accessibility

<!-- A11y requirements and patterns -->

(To be filled by the team)

---

## Common Mistakes

<!-- Component-related mistakes your team has made -->

(To be filled by the team)

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

const PullToRefresh({
  required RefreshCallback onRefresh,
  required Widget child,
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
- A card may call `PixivImage.preload` on pointer down, but must not await it
  before pushing the detail route. The detail frame creates a fixed-size
  avatar provider immediately; a cold avatar may fill after the transition.
- `PullToRefresh` tracks the leading-edge drag distance separately from
  Flutter's armed lifecycle. Its indicator follows both outward and reverse
  pointer deltas, including the reverse segment above the refresh threshold;
  releasing below the threshold cancels without calling `onRefresh`.
  Once edge tracking has started, apply every vertical `scrollDelta` until
  the matching `ScrollEndNotification`; a reverse update may have a null
  `dragDetails` while the scrollable bounces back.
  Once `onRefresh` starts, scroll notifications cannot reset the refreshing
  state until that Future completes.
- Hero shuttles are clipped in the global coordinate space of the source and
  target vertical viewports. The clip is their intersection for the whole
  flight (not an interpolated boundary), and a sliver's approximate paint clip
  is used so `NestedScrollView` pinned-header overlap remains protected.

### 4. Validation & Error Matrix

| Condition | Required behavior |
| --- | --- |
| Card and detail scopes match | Image Hero may participate in the transition. |
| Same work ID appears in another surface | Different tag, so no cross-surface flight. |
| No source card or no snapshot | Normal route/loading state remains observable. |
| API refresh fails with a snapshot | Snapshot content remains renderable and retry stays available. |
| Current profile is rendered | No settings icon or `onSettings` navigation hook is present. |
| Preview URL differs between card and detail | Correct the route input; do not let Hero fly a placeholder or lower-quality image. |
| Armed pull reverses before release | Dismiss the indicator and do not call `onRefresh`. |
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
- Pull-to-refresh tests arm, reverse, and release a real scrollable, asserting
  linear indicator movement before release, dismissal below the threshold, and
  exactly one refresh after a valid release.
- Hero flight tests cover a partially visible card and a nested pinned header;
  the shuttle clip must stay within the source/target viewport intersection.
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

For refresh and image timing, keep the shared boundary small:

```dart
onTapDown: (_) => unawaited(
  PixivImage.preload(context, previewUrl, cacheManager: cacheManager),
);
onTap: () => Navigator.push(detailRoute); // do not await the preload
```

Do not let the framework's armed visual state pin the indicator after the user
has reversed the drag; keep that correction in the shared wrapper rather than
creating a second per-page refresh implementation.
