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
reviewed: 2026-10-31
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
  `required` parameters with no English fallback. The first-load, empty
  and error views centre on the area under the page's toolbar, the
  bar's extension (tabs, a filter row, a search field) counted in.
- **Why:** Hand-drawn status buttons drifted in look; a fallback label
  shipped untranslated UI. Centred under the tabs, an empty state stood
  half a tab bar lower than on a page without them (user report).
- **Check:** `test/shared_widgets_test.dart` "an empty state stands as high under a bar with tabs as without"
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

### FEED-22 A list its filters emptied says so and loads on
- **Rule:** When the local filters hid every work loaded so far and the
  server has more (`PagedFeedState.isAllHidden`), the page shows
  `FeedAllHidden`: the loaded works are all blocked, muted or filtered
  out (search's client-side filters empty pages too), and
  "continue loading" runs one load-more per tap with its spinner and
  error in place; a failed one retries when the network is back. Never "no results", and no automatic walking. A work
  page's related section puts the same note and button in its own row,
  and the page's bottom-of-scroll paging skips such a list.
- **Why:** A search or ranking whose first pages were all filtered said
  "no results" and dropped the paging trigger while more remained (user
  decision 10-28).
- **Check:** `test/search_result_page_test.dart` "loaded pages all filtered: a note offers loading more (B9)"; `test/illust_detail_page_test.dart` "related works all filtered: the section offers loading on"
- **Code:** `lib/app/widgets/feed/feed_states.dart`, `lib/features/illust/detail/related_illusts_section.dart`, `lib/features/illust/detail/illust_detail_page.dart`

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

### FEED-20 The next page is asked for three screens ahead
- **Rule:** A paged list sits in a `LoadMoreListener`, never a hand-made
  scroll listener: it asks for the next page while the end is less than
  three viewports below, on a user scroll, once after the list mounts and
  once after each commit (an item count change). A commit is checked at
  once only while the list cannot scroll; otherwise on the next metrics
  notification, because rows appended past the laid-out ones keep the old
  estimated end until a layout reaches them. A size change alone never
  asks, and a nested scrollable never counts. Deduping, pacing
  (PAGING-07) and errors stay in the controller, and a controller clears
  its cursor on the last page.
  The artwork detail's related works keep their own on-demand trigger.
- **Why:** At 1.2 screens a fast reader reached the bottom spinner, and a
  short page that could not scroll stopped paging until the user dragged.
  Asking on a size change retried a failed page as soon as its error tail
  replaced the spinner; reading the stale estimate asked page after page
  without a scroll; a kept cursor reloaded the last page forever.
- **Check:** `test/load_more_listener_test.dart`, `test/watchlist_test.dart` "the last page ends the feed", `test/feed_generation_commit_test.dart` "refresh wins over a late append and drops its entity/cursor commit"
- **Code:** `lib/app/widgets/feed/load_more_listener.dart`

### FEED-06 Card text is laid out between frames before its card
- **Rule:** Content text on feed cards and rows sets
  `locale: contentLocale(context, text)`. `IllustFeedGrid`s of `IllustCard`s
  and `SliverCardList`s of `NovelEntry`s or recommended users'
  `AuthorSummary`s pass the card's `warmTexts`, built
  by `warmLine` from the style helpers the card itself uses, so a warm line
  equals the laid-out `RenderParagraph` (or `RenderEditable`) in spans,
  styles, locale and strut. A detail page's title, author and tags
  (`InfoBlock.warmTexts`, sharing `_Title`'s style and `TagChip`'s span)
  are laid out while a finger rests on an `IllustCard` (dropped on a
  cancel and on the push) and, in the pager, a paragraph per still frame
  before a neighbour joins (MOTION-21). `FeedTextWindow` queues at most `maxTexts` lines past the furthest built
  item; `FeedTextWarmup` lays out one per gap, right after a frame that
  started at most `vsync - itemCost` earlier, never inside a frame or at
  idle priority. Fonts are not prefetched as whole files.
- **Why:** A first-time glyph reads its outline from the font file; under
  memory pressure those pages are evicted within about 30 s, and the read
  was a 2–4 ms wait inside the frame that built the card. Whole-file
  prefetch (31 MB per 40 s) was evicted before use and still missed. The
  layout also fills SkParagraph's shared 128-entry cache (key: text, locale,
  font style), which spares the frame the shaping only if the line matches
  exactly and is not evicted before its card is built.
- **Check:** manual — warm-up only saves layout time inside a frame (TEST-12); checked on a trace
- **Code:** `lib/app/widgets/feed/feed_text_warmup.dart`, `lib/app/widgets/feed/illust_card.dart`, `lib/features/illust/detail/widgets/info_block.dart`, `lib/app/widgets/tag_chips.dart`, `lib/app/widgets/novel_entry.dart`, `lib/app/widgets/author_summary.dart`, `lib/app/layout/card_columns.dart`, `lib/app/format/content_locale.dart`

### FEED-18 A list builds its cache area from its second frame
- **Rule:** A list with `kFeedCacheExtent`, the settings list and the
  artwork detail page are a `DeferredCacheScrollView` or
  `DeferredCacheListView`: the first frame
  builds what is on screen, and the cache extent applies from the next
  frame, which builds only the children it adds. `IllustFeedGrid` and
  `SliverCardList` wrap their sliver in `SliverCacheRamp`: past the
  visible part and what is built, the trailing cache grows at most a
  quarter viewport a frame, and never ends before the built children.
  Code and tests look a scroll view up by subtype (`is CustomScrollView`,
  `find.bySubtype`), never by exact type.
- **Why:** A feed mounts on a busy frame (a push, a branch switch, its
  first data), and building half a screen more there took the first
  visit to ranking, new works, an author or the settings to 13–25 ms.
  A detail page's first frame is its push. Data landing or a page
  appended later built the half screen in one frame (13.7–16.8 ms).
- **Check:** `test/sliver_cache_ramp_test.dart`; when each frame builds the cache area is manual (TEST-12)
- **Code:** `lib/app/layout/deferred_cache_scroll_view.dart`, `lib/app/layout/sliver_cache_ramp.dart`, `lib/app/motion/hero_transition.dart`, `lib/features/illust/detail/illust_detail_page.dart`

### FEED-21 A built card rebuilds only when its own inputs change
- **Rule:** Feed lists pass `items` (the entity behind each card) and
  `itemDeps` (everything else the builder reads, such as the hero scope)
  to `IllustFeedGrid` and `SliverCardList`; the builder reads nothing
  else and not its context. While the entity at an index is the same
  instance and the deps are equal, the list hands back the card it built
  (`FeedItemCache`). A body that lists entities from a `Notifier<Map>`
  store selects them as `StoredEntities`, so merges of other entities do
  not rebuild it. Lists with per-row selection state (history, watch
  later) build every time.
- **Why:** Each body rebuild (a page appended, a load-more phase change,
  any store merge) rebuilt every built card in that frame.
- **Check:** `test/feed_item_cache_test.dart`
- **Code:** `lib/app/widgets/feed/feed_item_cache.dart`, `lib/core/entity/stored_entities.dart`, `lib/app/layout/card_columns.dart`, `lib/app/widgets/feed/feed_grid.dart`

## Pull to refresh

### FEED-07 PullToRefresh is the only refresh wrapper
- **Rule:** Feeds refresh through `PullToRefresh`, with
  `clamping: false` for ordinary lists: the whole list follows the finger
  down and the header shows above it. A tab body inside a
  `NestedScrollView` passes `isNested: true` and starts its list with
  `PullToRefresh.nestedHeader`, its only `HeaderLocator`. Its header is
  clamping, the only kind EasyRefresh 4 accepts there; the locator takes
  the header's height, so the list still slides down under the tabs,
  and the fork gives that height back on the list that holds it, never
  on the outer scroll. Nothing wraps the whole `NestedScrollView`; its
  outer physics is `NestedRefreshOuterPhysics`, which holds the outer
  scroll while the user drags a feed's header out.
- **Why:** Per-page wrappers diverged; under clamping the reversed pull is
  not real overscroll, so the indicator stayed pinned while the list
  moved. A clamping header keeps the feed at its top, so the coordinator
  gave a reversed pull to the outer scroll first: the profile header
  collapsed under a stuck indicator. EasyRefresh holds only an outer scroll
  that runs its own physics. A clamping header on every feed, its disc
  dropping over a still list as `SwipeRefreshLayout` draws it, was tried
  on device and dropped: the user kept the list pulling down (user
  decision 10-24). A locator without height left that disc over a still
  list on the profile tabs alone (user report). EasyRefresh took a closing
  header's height off the outer scroll without a layout, so a profile
  header pushed up during a refresh jumped open on the next drag.
- **Check:** `test/pull_to_refresh_test.dart` "the shared wrapper refreshes a nested scroll view once", `test/user_profile_test.dart` "a reversed pull retracts the indicator before the header collapses" "a header pushed up during a refresh stays when it ends"
- **Code:** `lib/app/pull_to_refresh.dart`, `lib/features/profile/user_page.dart`, `lib/features/profile/profile_illust_feed.dart`, `pubspec.yaml`

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
  stuck before the list moved, which Android lists never do. Android's
  clamping physics, an `OverScroller` fling with Android 12's stretch at
  both ends, were tried on device and dropped: the user kept the bounce
  past an end and the iOS fling (user decision 10-24).
- **Check:** `test/scroll_behavior_test.dart` "a fling stops at the end instead of springing back" "a selectable title that fits scrolls the page, not itself" "the list follows the finger from the move past the slop", `test/pull_to_refresh_test.dart` "a fling stops at the trailing edge instead of bouncing back"
- **Code:** `lib/app/scroll_behavior.dart`, `lib/app/pull_to_refresh.dart`

### FEED-12 NestedScrollView gets explicit physics and one inner tab
- **Rule:** A `NestedScrollView` passes the behavior's physics,
  `ScrollConfiguration.of(context).getScrollPhysics(context)`, as the
  parent of its outer physics (FEED-07), and a nested `PullToRefresh`
  flings with `FuncScrollPhysics` on top of EasyRefresh's nested physics,
  so outer and inner run the same simulation. Only the selected tab sits
  on the inner controller; unselected tabs park on a controller of the
  same kind, and the `PrimaryScrollController` is never `.none`.
- **Why:** Its outer position defaults to clamping, so the header stopped
  short while the feed rolled on; EasyRefresh 4's nested physics flings
  with a clamping simulation and brought the same stop back. Kept-alive
  tabs on one inner controller were driven as one: a fling died at the
  header and hidden tabs dragged along.
- **Check:** `test/user_profile_test.dart` "a light upward fling never leaves the inner feed ahead of the header" "a light pull-down while the header is collapsing keeps it expanding" "each tab scrolls on its own; re-tap rewinds only the selected one"
- **Code:** `lib/features/profile/user_page.dart`, `lib/app/pull_to_refresh.dart`

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

### FEED-23 A restored offset lands on content or on a skeleton that reaches it
- **Rule:** A scroll view with a `restorationId` is built with its content;
  a feed's skeleton stands outside it. A skeleton that shares one with
  loaded sections (the search home's trending grid) reaches the viewport's
  end at the offset the list opens at, so an offset restored after process
  death stays put until the content lands.
- **Why:** The search home restored its offset over three skeleton rows,
  and the bounce physics sprang it back to their end before the tags
  landed.
- **Check:** `test/navigation_restoration_test.dart` "restores a representative feed offset"
- **Code:** `lib/features/search/search_page.dart`
