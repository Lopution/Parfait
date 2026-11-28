---
prefix: FEED
applies_to:
  - lib/app/widgets/feed/**
  - lib/app/widgets/skeleton/**
  - lib/app/pull_to_refresh.dart
  - lib/app/layout/deferred_cache_scroll_view.dart
  - lib/app/scroll_behavior.dart
  - lib/app/format/content_locale.dart
  - lib/core/bookmark/bookmark_actions.dart
reviewed: 2026-11-28
---

# Feeds: states, grid, pull to refresh, skeletons

## Contents

- [Status views](#status-views)
- [Grid](#grid)
- [Pull to refresh and scroll](#pull-to-refresh-and-scroll)
- [First-load skeletons](#first-load-skeletons)

## Status views

### FEED-01 Status views come from feed_states.dart
- **Rule:** Empty, error, and tail states use `FeedEmpty`, `FeedError`, and `FeedTail` (custom restricted/blocked states use `StateActionButton`) with required localized strings and no English fallbacks. `FeedError` offers category-scoped secondary recovery buttons (Network settings for network/DNS/TLS errors, Account settings for auth errors) guarded by `GoRouter.maybeOf` and popping `PopupRoute` ancestors first; signed-out `HistoryPage` uses `FeedEmpty` with a Login action.
- **Why:** Prevents untranslated fallbacks, drifting status layouts, and dead-end network/auth error walls.
- **Check:** `test/shared_widgets_test.dart` "FeedError exposes category-scoped settings action with GoRouter and LoginWebViewErrorCard offers browser fallback", `test/history_page_test.dart` "signed-out state uses FeedEmpty with Login action"
- **Code:** `lib/app/widgets/feed/feed_states.dart`, `lib/features/history/history_page.dart`

### FEED-02 Refresh only where content can still arrive
- **Rule:** Empty views offer `refresh` only on live feeds; genuinely empty views (no works, empty history, no search hits) offer no refresh/retry (at most an alternate action). When user settings explain emptiness (history off, active search filters), name it and offer a one-tap reversal.
- **Why:** Refresh on permanently empty views looked broken and hidden filters confused users.
- **Check:** `test/history_page_test.dart` "an empty history with recording off offers to turn it on", `test/search_result_page_test.dart` "an empty result with filters on offers resetting them"
- **Code:** `lib/app/widgets/feed/feed_states.dart`

### FEED-22 A list its filters emptied says so and loads on
- **Rule:** When local filters hide all loaded items while more exist (`PagedFeedState.isAllHidden`), show `FeedAllHidden` with an explicit manual "continue loading" button (no "no results", no auto-walking); detail related-works uses the same row and skips bottom-scroll paging while all-hidden.
- **Why:** User decision: filtered-out first pages must not masquerade as "no results" or stall paging.
- **Check:** `test/search_result_page_test.dart` "loaded pages all filtered: a note offers loading more (B9)"; `test/illust_detail_page_test.dart` "related works all filtered: the section offers loading on, reaching the bottom does not load (FEED-22)"
- **Code:** `lib/app/widgets/feed/feed_states.dart`, `lib/features/illust/detail/related_illusts_section.dart`, `lib/features/illust/detail/illust_detail_page.dart`

### FEED-03 Failures retry once when the network returns
- **Rule:** Retryable errors (`FeedError`, `FeedTail`, or `RetryOnNetworkRestore`) retry once per offline -> online transition for network/timeout/unknown failures only; 404 and parse errors stay put.
- **Why:** Recovers offline error screens automatically without looping on permanent errors.
- **Check:** `test/shared_widgets_test.dart` "a connection failure retries once per restore" "a failure the network does not explain stays put"
- **Code:** `lib/app/widgets/feed/feed_states.dart`

## Grid

### FEED-04 The card key lives inside the grid extent
- **Rule:** `IllustFeedGrid` leaves `FeedItemExtent` unkeyed and places `ValueKey(entity.id)` on the inner card subtree; item-scoped state and `findChildIndexCallback` key by entity ID, never index.
- **Why:** Keying `FeedItemExtent` triggered a `flutter_staggered_grid_view` 0.7.0 null-offset crash when refresh reordered visible items.
- **Check:** manual — structural key placement
- **Code:** `lib/app/widgets/feed/feed_grid.dart`

### FEED-05 No feed prefetch
- **Rule:** Feeds never prefetch images; grid cache extent mounts cards ahead and each card fetches on mount.
- **Why:** Prefetch windows contended with visible cards for worker lanes.
- **Check:** manual
- **Code:** `lib/app/widgets/feed/feed_grid.dart`

### FEED-20 The next page is asked for three screens ahead
- **Rule:** Paged lists sit in `LoadMoreListener` (never ad-hoc scroll listeners), requesting the next page when the trailing edge is within 3 viewports on user scroll, mount, and post-commit (immediately only when non-scrollable, otherwise on next metrics). Size changes and nested scrollables never trigger requests; controllers clear cursors on the last page.
- **Why:** 1.2 screens hit bottom spinners; naive size/commit triggers looped failed pages or requested repeatedly off stale scroll estimates.
- **Check:** `test/load_more_listener_test.dart` "a list asks once its end is within three screens" "a nested row reaching its end asks for nothing", `test/watchlist_test.dart` "the last page ends the feed", `test/feed_generation_commit_test.dart` "refresh wins over a late append and drops its entity/cursor commit"
- **Code:** `lib/app/widgets/feed/load_more_listener.dart`

### FEED-06 Card text is laid out between frames before its card
- **Rule:** Content text sets `locale: contentLocale(context, text)`. `IllustFeedGrid`, `SliverCardList`, and `InfoBlock.warmTexts` warm matching `warmLine` paragraphs via `FeedTextWindow` / `FeedTextWarmup` between frames (never inside frames or via whole-font prefetch).
- **Why:** Cold glyph reads and SkParagraph shaping stalled card build frames by 2–4 ms under memory pressure.
- **Check:** manual — warm-up only saves layout time inside a frame (TEST-12)
- **Code:** `lib/app/widgets/feed/feed_text_warmup.dart`, `lib/app/widgets/feed/illust_card.dart`, `lib/features/illust/detail/widgets/info_block.dart`, `lib/app/widgets/tag_chips.dart`, `lib/app/widgets/novel_entry.dart`, `lib/app/widgets/author_summary.dart`, `lib/app/layout/card_columns.dart`, `lib/app/format/content_locale.dart`

### FEED-21 A built card rebuilds only when its own inputs change
- **Rule:** Feed grids/lists pass `items` and `itemDeps` so `FeedItemCache` reuses unchanged cards; bodies reading `Notifier<Map>` stores select via `StoredEntities` (lists with per-row selection rebuild directly).
- **Why:** Avoids rebuilding every visible card on unrelated store merges or page appends.
- **Check:** `test/feed_item_cache_test.dart` "stored entities list theirs in order and differ once one is replaced"
- **Code:** `lib/app/widgets/feed/feed_item_cache.dart`, `lib/core/entity/stored_entities.dart`, `lib/app/layout/card_columns.dart`, `lib/app/widgets/feed/feed_grid.dart`

### FEED-24 Wide feed multi-selection and batch bookmark or download bar
- **Rule:** `SelectableFeedHost` enables multi-select only at `>= AppBreakpoints.medium` (600dp, clearing when narrowed), supporting `ScrollAwareHoverRegion` hover checkboxes with localized per-card select/deselect labels, touch long-press sheet/context-menu "Select" entry, `Ctrl`/`Cmd`+Click, `Shift`+Click range, `Ctrl`/`Cmd`+A (macOS & iPadOS), and `Esc`/back dismissal; entering selection closes any open `DesktopInspectorScope`, and the floating `FeedBatchActionBar` clears `HomeShellChrome.bottomBarExtent` on landscape phones while driving bounded-concurrency `BookmarkActions.addBatch` and downloads.
- **Why:** Gives desktop and tablet users discoverable, collision-free batch triage without cluttering phones, overlapping bottom navigation, or flooding network writes.
- **Check:** `test/feed_selection_test.dart` "SelectableFeedHost gates >=600dp multi-select, Ctrl/Cmd+Click, Shift range, Ctrl+A, Esc, and batch bookmark/download" "touch tablet enters multi-select via card sheet, landscape phone bar clears bottom nav, and inspector respects content width & auto-closes"
- **Code:** `lib/app/widgets/feed/feed_selection.dart`, `lib/app/widgets/feed/feed_grid.dart`, `lib/app/widgets/feed/illust_card.dart`, `lib/app/widgets/card_actions/card_action_sheet.dart`, `lib/app/widgets/card_actions/ios_card_context_menu.dart`, `lib/core/bookmark/bookmark_actions.dart`

## Pull to refresh and scroll

### FEED-07 PullToRefresh is the only refresh wrapper
- **Rule:** All feeds (including `SearchHomePage` trending tags + Spotlight) refresh via `PullToRefresh` (`clamping: false`, passing explicit `scrollController` for active-tab re-tap refresh, exposing `HeaderRefresh` on wide headers, and surfacing pull-to-refresh failures on loaded feeds via `listenFeedRefreshError`). `TabSlideStack` keeps resting neighbors (`|i - pos| >= 1.0`) offstage and `isRenderBoxVisibleOnScreen` excludes offstage/clipped ancestors so refresh and select-all shortcuts hit only the visible tab. Inside `NestedScrollView`, tab bodies pass `isNested: true` with `PullToRefresh.nestedHeader` and the outer view uses `NestedRefreshOuterPhysics` (never wrap the whole `NestedScrollView`).
- **Why:** User decision: list pulls down cleanly across platforms without dead search headers, buried refresh errors, clipped neighbor hijacking, or nested profile-header conflicts.
- **Check:** `test/feed_selection_test.dart` "wide split TabSlideStack keeps resting neighbors offstage for both refresh and select-all", `test/search_result_page_test.dart` "search refresh failure surfaces a Retry prompt and active tab re-tap triggers refresh", `test/search_catalog_test.dart` "SearchHomePage supports pull-to-refresh for trending tags & spotlight and InkWell hover/focus on tag tiles"
- **Code:** `lib/app/pull_to_refresh.dart`, `lib/app/widgets/app_spinner.dart`, `lib/app/widgets/feed/feed_states.dart`, `lib/features/search/search_page.dart`, `lib/features/profile/user_page.dart`, `lib/features/profile/profile_illust_feed.dart`, `pubspec.yaml`

### FEED-13 Horizontal strips inside a feed opt out of the refresh physics
- **Rule:** Horizontal scrollables inside `PullToRefresh` override `ScrollConfiguration.of(context).copyWith(physics: ...)`, not just `physics:` on the scrollable.
- **Why:** EasyRefresh's physics applies to all axes in its subtree and armed refresh on horizontal overscroll.
- **Check:** manual
- **Code:** `lib/app/pull_to_refresh.dart`

## First-load skeletons

### FEED-14 Skeletons cover the first load only
- **Rule:** Initial loads of network feeds paint a layout-shaped skeleton (`IllustGridSkeleton`, `NovelListSkeleton`, `UserListSkeleton`, `SpotlightListSkeleton`, `ProfileSkeleton`; never `FeedEmpty`, blank space, or a lone spinner; instant local SQLite pages may omit shimmer); refresh and load-more keep existing content; `IllustDetailSkeleton` shows only without `initialEntity`.
- **Why:** Dropping content on refresh or masking snapshots broke Hero hand-offs, while bare spinners on slow network lists caused layout jumps.
- **Check:** `test/spotlight_feed_test.dart` "SpotlightListSkeleton renders bones, AppChoiceChip omits PressScale, and UserPreviewRow mounts Hero without press ink"
- **Code:** `lib/app/widgets/skeleton/func_skeleton.dart`, `lib/app/widgets/skeleton/list_skeletons.dart`, `lib/features/illust/detail/widgets/illust_detail_skeleton.dart`

### FEED-15 One skeleton root paints, animates and speaks
- **Rule:** The outermost `FuncSkeleton` owns the single shimmer controller, shared gradient (painted per `SkeletonBone`, no `ShaderMask`), and single localized loading semantics node (`UserListSkeleton` separates title and `@handle` bones). Nested `FuncSkeleton`s render their child as-is; reduced motion keeps bones static.
- **Why:** Eliminates per-frame `ShaderMask` offscreen layers and duplicate shimmer tickers/announcements.
- **Check:** `test/motion_test.dart` "FuncSkeleton owns one shimmer root, passes nested roots through, and stays static under reduced motion"
- **Code:** `lib/app/widgets/skeleton/func_skeleton.dart`, `lib/app/widgets/skeleton/list_skeletons.dart`

### FEED-16 Skeleton geometry matches the real layout
- **Rule:** `IllustGridSkeleton` matches `illustColumnsForContext`, `FoldPosture.book` wing splits (`WindowLayoutSpec.bookSplitFor`), padding, and spacing (non-scrolling, clipped); `ProfileSkeleton` aligns avatar/name with the real header and keeps a real `BackButton` outside excluded semantics.
- **Why:** Prevents layout jumps on load and lets users leave slow profiles.
- **Check:** `test/user_profile_test.dart` "a pending profile shows the skeleton and the back button leaves"
- **Code:** `lib/app/widgets/skeleton/illust_grid_skeleton.dart`, `lib/features/profile/profile_skeleton.dart`

### FEED-23 A restored offset lands on content or on a skeleton that reaches it
- **Rule:** Scroll views with `restorationId` build only with their content (feed skeletons sit outside); mixed-section skeletons (search trending grid) extend a viewport past the restored offset and recompute on resize.
- **Why:** Short skeletons caused bounce physics to snap restored offsets back to the top before data arrived.
- **Check:** `test/navigation_restoration_test.dart` "restores a representative feed offset"
- **Code:** `lib/features/search/search_page.dart`
