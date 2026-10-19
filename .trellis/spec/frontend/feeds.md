---
prefix: FEED
applies_to:
  - lib/app/widgets/feed/**
  - lib/app/widgets/skeleton/**
  - lib/app/pull_to_refresh.dart
  - lib/app/layout/deferred_cache_scroll_view.dart
  - lib/app/scroll_behavior.dart
  - lib/app/format/content_locale.dart
  - lib/features/**/*_page.dart
reviewed: 2026-10-19
---

# Feeds: states, grid, pull to refresh, skeletons

## Contents

- [Status views](#status-views)
- [Grid](#grid)
- [Pull to refresh](#pull-to-refresh)
- [Scroll physics](#scroll-physics)
- [First-load skeletons](#first-load-skeletons)

## Status views

### FEED-01 Status views come from feed_states.dart
- **Rule:** Empty, error and tail states use `FeedEmpty`, `FeedError` and
  `FeedTail`; a custom status (restricted, blocked) uses
  `StateActionButton` as its one button. Their user-visible strings are
  `required` parameters with no English fallback.
- **Why:** Hand-drawn status buttons drifted in look; a fallback label
  shipped untranslated UI.
- **Check:** `test/shared_widgets_test.dart`
- **Code:** `lib/app/widgets/feed/feed_states.dart`

### FEED-02 Refresh only where content can still arrive
- **Rule:** An empty view offers `refresh` only for a live feed. Content
  that is simply not there (a user without works, an empty history, no
  search results) offers no refresh and no retry, at most another action
  (edit the search, import). `retry` belongs to failures. When a choice
  of the user's explains the emptiness, the view names it and offers to
  undo it: history recording off offers to turn it on, a search with
  filters on offers to reset them.
- **Why:** Refresh on a permanently empty page did nothing and read as
  broken. An empty page caused by a switch or a filter gave no hint why.
- **Check:** `test/history_page_test.dart` "an empty history with recording off offers to turn it on", `test/search_result_page_test.dart` "an empty result with filters on offers resetting them"
- **Code:** `lib/app/widgets/feed/feed_states.dart`

### FEED-03 Failures retry once when the network returns
- **Rule:** An error with a retry button is `FeedError`, `FeedTail`, or
  wrapped in `RetryOnNetworkRestore`; each retries once per
  no-network → network transition. Only network and timeout failures, or
  an unknown error, retry; a 404 or a parse error stays put.
- **Why:** Users came back online to a dead error page; retrying a 404
  would fail the same way.
- **Check:** `test/shared_widgets_test.dart` "a connection failure retries once per restore" "a failure the network does not explain stays put"
- **Code:** `lib/app/widgets/feed/feed_states.dart`

## Grid

### FEED-04 The card key lives inside the grid extent
- **Rule:** `IllustFeedGrid` keeps `FeedItemExtent` unkeyed and puts
  `ValueKey(entity.id)` on the card subtree inside it. State tied to an
  item (played sets, `findChildIndexCallback`, element keys) uses the
  entity id, never the index.
- **Why:** With `flutter_staggered_grid_view` 0.7.0 a keyed extent let a
  refresh that moved visible works to the head leave masonry index 0
  without a layout offset (null-check crash). Index-keyed state replayed
  on every refresh.
- **Check:** `test/responsive_layout_test.dart` "a refresh that moves visible works to the head lays out"
- **Code:** `lib/app/widgets/feed/feed_grid.dart`

### FEED-19 Grid columns follow the user's density
- **Rule:** Every illustration grid is an `IllustFeedGrid` and takes its
  column count from `illustColumnsFor(extent, density)`, the density
  being the `feedDensity` setting: the narrowest card is 120, 180 or
  360dp and the fewest columns 3, 2 or 1 (compact, standard,
  comfortable), so a phone shows three, two or one and wider layouts add
  columns in proportion. Standard is the default and the old grid.
- **Why:** User decision: quick scanning wanted more columns, slow
  looking a single one; a per-page setting would split one habit.
- **Check:** `test/responsive_layout_test.dart` "illustColumnsFor derives columns from the extent and density" "IllustFeedGrid counts columns on the sliver extent, not the window"
- **Code:** `lib/app/widgets/feed/feed_grid.dart`, `lib/core/settings/app_settings.dart`

### FEED-05 No feed prefetch
- **Rule:** Feeds do not prefetch images. The grid's cache extent builds
  cards ahead and each card's image loads as it mounts.
- **Why:** A prefetch window competed with visible images for the image
  lanes.
- **Check:** manual
- **Code:** `lib/app/widgets/feed/feed_grid.dart`

### FEED-06 Card text is laid out between frames before its card
- **Rule:** Content text on feed cards sets
  `locale: contentLocale(context, text)`. Every `IllustFeedGrid` of
  `IllustCard`s passes `warmTexts: IllustCard.warmTexts(...)`, and a card's
  text styles live only in `IllustCard`, shared by the card and the warmup.
  `FeedTextWarmup` lays out one line per gap, right after a frame that
  started at most `vsync - itemCost` earlier, never inside a frame and
  never at idle priority. Fonts are not prefetched as whole files.
- **Why:** A first-time glyph reads its outline from the font file; under
  memory pressure those pages are evicted within about 30 s, and the read
  was a 2–4 ms wait inside the frame that built the card. Whole-file
  prefetch (31 MB per 40 s) was evicted before use and still missed;
  warming the exact lines left no in-frame reads on device.
- **Check:** `test/feed_text_warmup_test.dart`
- **Code:** `lib/app/widgets/feed/feed_text_warmup.dart`, `lib/app/widgets/feed/illust_card.dart`, `lib/app/format/content_locale.dart`

### FEED-18 A list builds its cache area from its second frame
- **Rule:** A list with `kFeedCacheExtent`, and the settings list, is a
  `DeferredCacheScrollView` or `DeferredCacheListView`: its first frame
  builds what is on screen, and the cache extent applies from the next
  frame, which builds only the children it adds. Code and tests look a
  scroll view up by subtype (`is CustomScrollView`, `find.bySubtype`),
  never by exact type.
- **Why:** A feed mounts on a busy frame (a push, a branch switch, its
  first data), and building half a screen more there took the first
  visit to ranking, new works, an author or the settings to 13–25 ms.
- **Check:** `test/responsive_layout_test.dart` "a deferred cache builds the screen, then only the cache area"
- **Code:** `lib/app/layout/deferred_cache_scroll_view.dart`, `lib/app/motion/hero_transition.dart`

## Pull to refresh

### FEED-07 PullToRefresh is the only refresh wrapper
- **Rule:** Feeds refresh through `PullToRefresh`, with
  `clamping: false` for ordinary lists. A tab body inside a
  `NestedScrollView` passes `isNested: true` and has exactly one
  `HeaderLocator` as its first item; its header is clamping, the only kind
  EasyRefresh 4 accepts there. Nothing wraps the whole
  `NestedScrollView`; its outer physics is `NestedRefreshOuterPhysics`,
  which holds the outer scroll while the user drags a feed's header out.
- **Why:** Per-page wrappers diverged; under clamping the reversed pull is
  not real overscroll, so the indicator stayed pinned while the list
  moved. A clamping header keeps the feed at its top, so the coordinator
  gave a reversed pull to the outer scroll first: the profile header
  collapsed under a stuck indicator. EasyRefresh holds only an outer scroll
  that runs its own physics.
- **Check:** `test/pull_to_refresh_test.dart` "the shared wrapper refreshes a nested scroll view once", `test/user_profile_test.dart` "a reversed pull retracts the indicator before the header collapses"
- **Code:** `lib/app/pull_to_refresh.dart`, `lib/features/profile/user_page.dart`

### FEED-08 The indicator follows observable outcomes
- **Rule:** A reversed pull moves the indicator back with the finger, and
  while any of it is on screen the list does not scroll. Motion after the
  pointer lifts never starts or resumes a pull. Every pull ends with the
  indicator hidden. A qualifying pull calls `onRefresh` exactly once, and
  no scroll resets the refreshing state until its future completes.
- **Why:** Pointer-up overscroll re-armed pulls and the indicator stuck on
  screen.
- **Check:** `test/pull_to_refresh_test.dart` "a reverse drag retracts the indicator and cancels" "a released armed pull refreshes once and hides the indicator" "ballistic overscroll after the pointer lifts starts no pull", `test/user_profile_test.dart` "a reversed pull retracts the indicator before the header collapses"
- **Code:** `lib/app/pull_to_refresh.dart`

### FEED-09 The framework decides the threshold
- **Rule:** The wrapper reads scroll metrics only to render the indicator.
  It never accumulates its own drag distance, decides a threshold, or
  vetoes a refresh the framework triggered.
- **Why:** A second scroll state machine beside EasyRefresh disagreed with
  it: one root cause behind re-armed pulls, vetoed refreshes and a stuck
  indicator.
- **Check:** `test/pull_to_refresh_test.dart` "reversing an armed pull retracts the indicator before the list"
- **Code:** `lib/app/pull_to_refresh.dart`

### FEED-10 Pull tests pull past the arm threshold
- **Rule:** Pull-to-refresh tests drive a real scrollable, pull past the
  arm threshold before reversing, and assert the indicator's final
  visibility in every case.
- **Why:** A pull that stops short takes another framework path, so the
  test passed without exercising the behavior.
- **Check:** `test/pull_to_refresh_test.dart`
- **Code:** `test/pull_to_refresh_test.dart`

### FEED-17 PullToRefresh keeps one EasyRefresh while its settings hold
- **Rule:** `PullToRefresh` rebuilds its `EasyRefresh` only when the
  colours, the indicator exit, `isNested` or the scroll controller change;
  the list reaches it through an inherited slot and `onRefresh` through a
  forwarding method. EasyRefresh itself depends on no `MediaQuery`: the
  fork reads the padding (`MediaQuery.paddingOf`) in its indicator
  builders.
- **Why:** EasyRefresh syncs its nested host after every update and
  dependency change, and the sync walks the whole list: each new page,
  load phase and keyboard frame cost a walk of the feed after the frame.
  The padding changes while the keyboard crosses the navigation bar and
  whenever the system bars show or hide (the novel chrome), and every
  mounted feed walked its list then.
- **Check:** `test/pull_to_refresh_test.dart` "a new list keeps the refresh and refreshes with the new callback"
- **Code:** `lib/app/pull_to_refresh.dart`, `pubspec.yaml`

## Scroll physics

### FEED-11 One bouncing physics everywhere; flings stop at the edge
- **Rule:** `FuncScrollBehavior` gives every page the feed's bouncing
  physics with no overscroll glow; do not add a `ClampingScrollPhysics`
  region. A fling stops at either edge; only a drag overscrolls.
  `PullToRefresh` passes `notLoadFooter: NotLoadFooter(hitOver: false)`.
  The scrollable inside a text control (`EditableText`) is not always
  scrollable: every scroll behavior the app installs returns
  `textScrollPhysics` for it first. Both the app's and the feed's physics
  sit under `NoDragDeadZonePhysics`: a list follows the finger from the
  move that crosses the slop.
- **Why:** Mixed physics felt different per page; a fling into the end of
  a feed sprang back while the next page loaded, because EasyRefresh
  copies `ClassicFooter`'s `hitOver: true` without `onLoad`. A text
  control's scrollable takes the nearest behavior's physics; always
  scrollable, a one-line selectable title followed the finger instead of
  the page, and came back after LAYOUT-11 fixed two pages only. Bouncing
  physics bring iOS's 3.5px start threshold: past the slop a slow drag
  stuck before the list moved, which Android lists never do.
- **Check:** `test/scroll_behavior_test.dart` "a fling stops at the end instead of springing back" "a selectable title that fits scrolls the page, not itself" "the list follows the finger from the move past the slop", `test/pull_to_refresh_test.dart` "a fling stops at the trailing edge instead of bouncing back"
- **Code:** `lib/app/scroll_behavior.dart`, `lib/app/pull_to_refresh.dart`

### FEED-12 NestedScrollView gets explicit physics and one inner tab
- **Rule:** A `NestedScrollView` passes the behavior's physics,
  `ScrollConfiguration.of(context).getScrollPhysics(context)`, as the
  parent of its outer physics (FEED-07), and a nested `PullToRefresh`
  flings with `FuncScrollPhysics` on top of EasyRefresh's nested physics,
  so outer and inner run the same simulation. Only the selected tab sits on the inner controller;
  unselected tabs park on a controller of the same kind, and the
  `PrimaryScrollController` is never `.none`.
- **Why:** Its outer position defaults to clamping, so the header stopped
  short while the feed rolled on; EasyRefresh 4's nested physics flings
  with a clamping simulation and brought the same stop back. Kept-alive
  tabs on one inner controller were driven as one: a fling died at the
  header and hidden tabs dragged along.
- **Check:** `test/user_profile_test.dart` "a light upward fling never leaves the inner feed ahead of the header" "a light pull-down while the header is collapsing keeps it expanding" "each tab scrolls on its own; re-tap rewinds only the selected one"
- **Code:** `lib/features/profile/user_page.dart`

### FEED-13 Horizontal strips inside a feed opt out of the refresh physics
- **Rule:** A horizontal scrollable inside `PullToRefresh` wraps itself in
  `ScrollConfiguration.of(context).copyWith(physics: ...)`; an explicit
  `physics:` on the scrollable is not enough.
- **Why:** EasyRefresh's physics applies to the whole subtree on every
  axis, so a sideways drag past the start armed the refresh header.
- **Check:** manual
- **Code:** `lib/app/pull_to_refresh.dart`

## First-load skeletons

### FEED-14 Skeletons cover the first load only
- **Rule:** A feed or detail page's initial load paints a skeleton shaped
  like the loaded layout, never `FeedEmpty`, a blank area or a lone
  spinner. Refresh and load-more keep the loaded list. Surfaces without a
  grid shape use `FeedLoading(label:)`. `IllustDetailSkeleton` shows only
  without an `initialEntity`.
- **Why:** A refresh that fell back to the skeleton threw away the list;
  a skeleton over the snapshot broke the Hero hand-off.
- **Check:** manual
- **Code:** `lib/app/widgets/skeleton/func_skeleton.dart`, `lib/features/illust/detail/widgets/illust_detail_skeleton.dart`

### FEED-15 One skeleton root paints, animates and speaks
- **Rule:** The outermost `FuncSkeleton` owns the one shimmer controller,
  the one gradient (each `SkeletonBone` paints its slice) and the one
  semantics node with a localized loading label. A nested `FuncSkeleton`
  renders its child as-is. No `ShaderMask`; under reduced motion the
  bones are static.
- **Why:** A full-page `ShaderMask` cost an offscreen layer every frame.
- **Check:** `test/motion_test.dart`
- **Code:** `lib/app/widgets/skeleton/func_skeleton.dart`

### FEED-16 Skeleton geometry matches the real layout
- **Rule:** `IllustGridSkeleton` takes its columns from
  `illustColumnsFor` at the same density, and the same padding and
  spacing as the grid beneath
  it; it fills and clips, never scrolls. `ProfileSkeleton` puts the avatar
  and name exactly where the real header does and keeps a real
  `BackButton` outside its excluded semantics.
- **Why:** Cards landing off the bones read as a jump; a loading profile
  could not be left.
- **Check:** `test/user_profile_test.dart` "a pending profile shows the skeleton and the back button leaves"
- **Code:** `lib/app/widgets/skeleton/illust_grid_skeleton.dart`, `lib/features/profile/profile_skeleton.dart`
