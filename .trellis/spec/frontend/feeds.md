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
reviewed: 2026-11-23
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
- **Rule:** Empty, error, and tail states use `FeedEmpty`, `FeedError`, and `FeedTail` (custom restricted/blocked states use `StateActionButton`) with required localized strings and no English fallbacks. Empty/error views place a 40dp `onSurfaceVariant` icon on a `surfaceContainerHigh` disc above a `titleSmall` title (no explanatory prose, PAGE-20), positioned at optical center (40% free space above, accounting for toolbar extensions at layout). `FeedError` offers category-scoped secondary recovery buttons (Network settings for network/DNS/TLS errors, Account settings for auth errors) guarded by `GoRouter.maybeOf` and popping `PopupRoute` ancestors first; signed-out `HistoryPage` uses `FeedEmpty` with a Login action. Oversized empty views scroll only when taller than their viewport so pull-to-refresh keeps normal drags.
- **Why:** Prevents untranslated fallbacks, drifting status layouts, dead-end network/auth error walls, off-center views under tabs, and overflow on landscape phones.
- **Check:** `test/shared_widgets_test.dart` "an empty state stands as high under a bar with tabs as without" "an empty state scrolls only when the window cannot hold it" "FeedError exposes category-scoped settings action with GoRouter and LoginWebViewErrorCard offers browser fallback", `test/history_page_test.dart` "signed-out state uses FeedEmpty with Login action"
- **Code:** `lib/app/widgets/feed/feed_states.dart`, `lib/features/history/history_page.dart`

### FEED-02 Refresh only where content can still arrive
- **Rule:** Empty views offer `refresh` only on live feeds; genuinely empty views (no works, empty history, no search hits) offer no refresh/retry (at most an alternate action). When user settings explain emptiness (history off, active search filters), name it and offer a one-tap reversal.
- **Why:** Refresh on permanently empty views looked broken and hidden filters confused users.
- **Check:** `test/history_page_test.dart` "an empty history with recording off offers to turn it on", `test/search_result_page_test.dart` "an empty result with filters on offers resetting them"
- **Code:** `lib/app/widgets/feed/feed_states.dart`

### FEED-22 A list its filters emptied says so and loads on
- **Rule:** When local filters hide all loaded items while more exist (`PagedFeedState.isAllHidden`), show `FeedAllHidden` with an explicit manual "continue loading" button (no "no results", no auto-walking); detail related-works uses the same row and skips bottom-scroll paging while all-hidden.
- **Why:** User decision: filtered-out first pages must not masquerade as "no results" or stall paging.
- **Check:** `test/search_result_page_test.dart` "loaded pages all filtered: a note offers loading more (B9)"; `test/illust_detail_page_test.dart` "related works all filtered: the section offers loading on"
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
- **Check:** `test/responsive_layout_test.dart` "a refresh that moves visible works to the head lays out"
- **Code:** `lib/app/widgets/feed/feed_grid.dart`

### FEED-19 Grid columns follow the user's density
- **Rule:** Every illustration grid uses `IllustFeedGrid` with `illustColumnsForContext(context, extent, density)` over `illustColumnsFor(extent, density)`: mobile/tablet min card extent 120/180/360dp and min columns 3/2/1 (compact/standard/comfortable); `FormFactor.pc` uses 176/204/268dp for compact/standard/comfortable (min columns 3/2/1; keeping 3 columns beside the 1280px inspector and ~5 columns full-width at 1440px).
- **Why:** User decision: unified density preference with comfortable desktop proportions.
- **Check:** `test/responsive_layout_test.dart` "illustColumnsFor derives columns from the extent and density" "IllustFeedGrid counts columns on the sliver extent, not the window" "PC standard grid keeps 3 columns at 1280px inspector width"
- **Code:** `lib/app/widgets/feed/feed_grid.dart`, `lib/core/settings/app_settings.dart`

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

### FEED-18 A list builds its cache area from its second frame
- **Rule:** Lists using `kFeedCacheExtent`, settings, and detail pages use `DeferredCacheScrollView` / `DeferredCacheListView` (first frame builds visible items only; cache extent activates next frame) with `SliverCacheRamp` growing trailing cache by at most 1/4 viewport per frame. Look up scroll views by subtype (`CustomScrollView`), never exact type.
- **Why:** Eagerly building half a screen of cache on mount/push frames caused 13–25 ms frame spikes.
- **Check:** `test/shared_widgets_test.dart` "sliver cache ramp"
- **Code:** `lib/app/layout/deferred_cache_scroll_view.dart`, `lib/app/layout/sliver_cache_ramp.dart`, `lib/app/motion/hero_transition.dart`, `lib/features/illust/detail/illust_detail_shells.dart`

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

## Pull to refresh

### FEED-07 PullToRefresh is the only refresh wrapper
- **Rule:** All feeds (including `SearchHomePage` trending tags + Spotlight) refresh via `PullToRefresh` (`SakuraRefreshIndicator` on `MotionTokens.refreshSpin`; `FeedTail`/`FeedLoading` use `AppSpinner`), using `clamping: false` so lists pull down with the finger, passing explicit `scrollController` for active-tab re-tap refresh (`reTapScrollToTop`), exposing `HeaderRefresh` on wide headers, and surfacing pull-to-refresh failures on loaded feeds via `listenFeedRefreshError` (`showErrorSnackBar` + Retry) rather than silent swallows or bottom-of-list banners. `TabSlideStack` keeps resting neighbors (`|i - pos| >= 1.0`) offstage and `isRenderBoxVisibleOnScreen` excludes offstage/clipped ancestors so refresh and select-all shortcuts hit only the visible tab. Inside `NestedScrollView`, tab bodies pass `isNested: true` with `PullToRefresh.nestedHeader` and the outer view uses `NestedRefreshOuterPhysics` (never wrap the whole `NestedScrollView`).
- **Why:** User decision: list pulls down cleanly across platforms without clamping bugs, dead search headers, buried refresh errors, clipped neighbor hijacking, or nested profile-header conflicts.
- **Check:** `test/pull_to_refresh_test.dart` "the shared wrapper refreshes a nested scroll view once", `test/feed_selection_test.dart` "wide split TabSlideStack keeps resting neighbors offstage for both refresh and select-all", `test/search_result_page_test.dart` "search refresh failure surfaces a Retry prompt and active tab re-tap triggers refresh", `test/search_catalog_test.dart` "SearchHomePage supports pull-to-refresh for trending tags & spotlight and InkWell hover/focus on tag tiles", `test/user_profile_test.dart` "a reversed pull retracts the indicator before the header collapses" "a header pushed up during a refresh stays when it ends"
- **Code:** `lib/app/pull_to_refresh.dart`, `lib/app/widgets/app_spinner.dart`, `lib/app/widgets/feed/feed_states.dart`, `lib/features/search/search_page.dart`, `lib/features/profile/user_page.dart`, `lib/features/profile/profile_illust_feed.dart`, `pubspec.yaml`

### FEED-08 The indicator follows observable outcomes
- **Rule:** Reversing a pull retracts the indicator before scrolling the list; ballistic overscroll after pointer-up never arms a pull; every pull ends with the indicator hidden; qualifying pulls invoke `onRefresh` once and stay refreshing until its future completes.
- **Why:** Prevents stuck indicators and ballistic re-arming.
- **Check:** `test/pull_to_refresh_test.dart` "a reverse drag retracts the indicator and cancels" "a released armed pull refreshes once and hides the indicator" "ballistic overscroll after the pointer lifts starts no pull", `test/user_profile_test.dart` "a reversed pull retracts the indicator before the header collapses"
- **Code:** `lib/app/pull_to_refresh.dart`

### FEED-09 The framework decides the threshold
- **Rule:** `PullToRefresh` reads scroll metrics only to render the indicator and never tracks duplicate drag distance or vetoes framework triggers.
- **Why:** A parallel state machine disagreed with EasyRefresh and caused stuck indicators.
- **Check:** `test/pull_to_refresh_test.dart` "reversing an armed pull retracts the indicator before the list"
- **Code:** `lib/app/pull_to_refresh.dart`

### FEED-10 Pull tests pull past the arm threshold
- **Rule:** Pull-to-refresh tests drive a real scrollable past the arm threshold before reversing and assert final indicator visibility.
- **Why:** Sub-threshold pulls bypassed the real refresh path.
- **Check:** `test/pull_to_refresh_test.dart` "crossing the refresh trigger is felt both ways" "a released armed pull refreshes once and hides the indicator"
- **Code:** `test/pull_to_refresh_test.dart`

### FEED-17 PullToRefresh keeps one EasyRefresh while its settings hold
- **Rule:** `PullToRefresh` rebuilds `EasyRefresh` only when colors, exit mode, `isNested`, or `scrollController` change (child arrives via inherited slot, `onRefresh` via forwarding); EasyRefresh avoids global `MediaQuery` dependencies.
- **Why:** Rebuilding `EasyRefresh` on page appends or inset changes walked the entire list every frame.
- **Check:** `test/pull_to_refresh_test.dart` "a new list keeps the refresh and refreshes with the new callback"
- **Code:** `lib/app/pull_to_refresh.dart`, `pubspec.yaml`

## Scroll physics

### FEED-11 Per-platform scroll physics and drag devices; flings stop at the edge
- **Rule:** `FuncScrollBehavior` and `PullToRefresh` (`NotLoadFooter(hitOver: false)`) keep `textScrollPhysics` inside `EditableText` and adapt per platform: Android uses `AndroidDragPhysics` over `FuncScrollPhysics` (zero dead zone, no carried flick momentum, mouse drag + `mouseScrollbar`); iOS uses `FuncScrollPhysics` directly (native bouncing carry and 3.5px threshold); Desktop removes `PointerDeviceKind.mouse` from `dragDevices` so mouse drags select text, using `ClampingScrollPhysics` on Windows/Linux and bouncing `FuncScrollPhysics` on macOS. Flings stop at edges everywhere.
- **Why:** Matches each OS's scroll feel, enables desktop text selection, and avoids bouncing off loading tails.
- **Check:** `test/scroll_behavior_test.dart` "a fling stops at the end instead of springing back" "a selectable title that fits scrolls the page, not itself" "the list follows the finger from the move past the slop" "a flick while the list coasts starts at its own speed" "iOS restores bouncing momentum carry and 3.5px drag threshold" "desktop removes mouse drag and splits Windows/Linux clamping from macOS bouncing", `test/pull_to_refresh_test.dart` "a fling stops at the trailing edge instead of bouncing back"
- **Code:** `lib/app/scroll_behavior.dart`, `lib/app/pull_to_refresh.dart`

### FEED-12 NestedScrollView gets explicit physics and one inner tab
- **Rule:** `NestedScrollView` passes `ScrollConfiguration.of(context).getScrollPhysics(context)` as parent of its outer physics; nested `PullToRefresh` layers `FuncScrollPhysics` over EasyRefresh's nested physics; only the active tab attaches to the inner controller (`PrimaryScrollController` is never `.none`).
- **Why:** Mismatched outer/inner physics stalled flings at headers and dragged hidden tabs.
- **Check:** `test/user_profile_test.dart` "a light upward fling never leaves the inner feed ahead of the header" "a light pull-down while the header is collapsing keeps it expanding" "each tab scrolls on its own; re-tap rewinds only the selected one"
- **Code:** `lib/features/profile/user_page.dart`, `lib/app/pull_to_refresh.dart`

### FEED-13 Horizontal strips inside a feed opt out of the refresh physics
- **Rule:** Horizontal scrollables inside `PullToRefresh` override `ScrollConfiguration.of(context).copyWith(physics: ...)`, not just `physics:` on the scrollable.
- **Why:** EasyRefresh's physics applies to all axes in its subtree and armed refresh on horizontal overscroll.
- **Check:** manual
- **Code:** `lib/app/pull_to_refresh.dart`

## First-load skeletons

### FEED-14 Skeletons cover the first load only
- **Rule:** Initial loads paint a layout-shaped skeleton (never `FeedEmpty`, blank space, or a lone spinner; non-grid surfaces use `FeedLoading`); refresh and load-more keep existing content; `IllustDetailSkeleton` shows only without `initialEntity`.
- **Why:** Dropping content on refresh or masking snapshots broke Hero hand-offs.
- **Check:** manual
- **Code:** `lib/app/widgets/skeleton/func_skeleton.dart`, `lib/features/illust/detail/widgets/illust_detail_skeleton.dart`

### FEED-15 One skeleton root paints, animates and speaks
- **Rule:** The outermost `FuncSkeleton` owns the single shimmer controller, shared gradient (painted per `SkeletonBone`, no `ShaderMask`), and single localized loading semantics node (`UserListSkeleton` separates title and `@handle` bones). Nested `FuncSkeleton`s render their child as-is; reduced motion keeps bones static.
- **Why:** Eliminates per-frame `ShaderMask` offscreen layers and duplicate shimmer tickers/announcements.
- **Check:** `test/motion_test.dart` "FuncSkeleton owns one shimmer root, passes nested roots through, and stays static under reduced motion"
- **Code:** `lib/app/widgets/skeleton/func_skeleton.dart`, `lib/app/widgets/skeleton/list_skeletons.dart`

### FEED-16 Skeleton geometry matches the real layout
- **Rule:** `IllustGridSkeleton` matches `illustColumnsFor`, padding, and spacing (non-scrolling, clipped); `ProfileSkeleton` aligns avatar/name with the real header and keeps a real `BackButton` outside excluded semantics.
- **Why:** Prevents layout jumps on load and lets users leave slow profiles.
- **Check:** `test/user_profile_test.dart` "a pending profile shows the skeleton and the back button leaves"
- **Code:** `lib/app/widgets/skeleton/illust_grid_skeleton.dart`, `lib/features/profile/profile_skeleton.dart`

### FEED-23 A restored offset lands on content or on a skeleton that reaches it
- **Rule:** Scroll views with `restorationId` build only with their content (feed skeletons sit outside); mixed-section skeletons (search trending grid) extend a viewport past the restored offset and recompute on resize.
- **Why:** Short skeletons caused bounce physics to snap restored offsets back to the top before data arrived.
- **Check:** `test/navigation_restoration_test.dart` "restores a representative feed offset"
- **Code:** `lib/features/search/search_page.dart`
