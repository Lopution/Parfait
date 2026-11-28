---
prefix: PAGE
applies_to:
  - lib/features/profile/**
  - lib/features/search/**
  - lib/features/ranking/**
  - lib/features/comments/**
  - lib/features/settings/pages/download_tasks_page.dart
  - lib/features/settings/pages/download_task_rows.dart
  - lib/features/settings/pages/muted_items_page.dart
  - lib/features/history/**
  - lib/features/watchlater/**
  - lib/features/spotlight/**
  - lib/app/widgets/author_row.dart
  - lib/app/widgets/bookmark_switch_button.dart
  - lib/app/widgets/card_actions/**
  - lib/app/widgets/display_actions.dart
  - lib/app/widgets/expandable_text.dart
  - lib/app/widgets/feed/illust_card.dart
  - lib/app/widgets/inline_translation.dart
  - lib/app/widgets/search_keyword_pills.dart
  - lib/app/widgets/selectable_tile.dart
  - lib/app/widgets/tag_actions_sheet.dart
  - lib/app/widgets/sliver_surface_list.dart
  - lib/app/layout/card_columns.dart
  - lib/app/layout/content_widths.dart
  - lib/app/widgets/scrollable_form_shell.dart
  - lib/features/illust/detail/author_works_section.dart
reviewed: 2026-11-28
---

# Page-specific rules

## Contents

- [Profile](#profile)
- [Discovery](#discovery)
- [Shared page pieces](#shared-page-pieces)
- [Library and management lists](#library-and-management-lists)
- [Wide and short windows](#wide-and-short-windows)

## Profile

### PAGE-01 Profile tabs list only the work types a user has
- **Rule:** Profiles expose one bare-named tab per non-zero work type (illust, manga, novel, illust series; preview snapshots keep all four; vanished tabs fall back to first), displaying each list's live total only while works are visible. Artist `illust`, `manga`, and `novel` tabs pair their live total with `ProfileWorkTagHeader` (top-10 loaded App-API work tags + adaptive searchable tag picker) scoped per tab, driving local work filtering with bounded 3-hop refill (`ProfileFilterRefillRunner`) and explicit load-more/clear empty states (`ProfileFilteredEmptyState`). At `>= 840x480` content (`HomeShellChrome.contentSizeOf`), `UserPage` uses the two-band panoramic header (164dp banner, 88dp avatar on 16dp margin, right-anchored actions, `ContentWidths.management`-capped stats/bio, pinned `maxEqualSlotWidth: 76` tabs + gallery controls, `ValueKey('profile-wide-split')`), mirrored by `ProfileSkeleton` without duplicate desktop back buttons.
- **Why:** Counts inside tab labels forced scrolling, stale totals over empty lists looked broken, full-width panoramic headers avoid L-shaped whitespace on wide screens, and artist portfolios need App-API tag filtering without web cookies.
- **Check:** `test/user_profile_test.dart` "work tabs follow the types a user has; each list shows its total" "a profile without works opens on its first other tab" "a tab that disappears on refresh falls back to the first"; `test/user_profile_wide_test.dart` "wide profile aligns two-band header margins with right actions and bio cap" "wide profile skeleton avoids duplicate back button and empty works hide total"; `test/profile_bookmarks_test.dart` "artist work tabs expose progressive tag filter with searchable picker and clear/load-more empty state"
- **Code:** `lib/features/profile/user_page.dart`, `lib/features/profile/profile_work_tag_filter.dart`, `lib/features/profile/profile_header_delegate.dart`, `lib/features/profile/profile_skeleton.dart`, `lib/features/profile/profile_illust_feed.dart`, `lib/features/profile/profile_novel_feed.dart`

### PAGE-22 Bookmarks list illustrations or novels by a kind menu
- **Rule:** Profile bookmarks open with a kind menu (illusts/novels; followed by visibility and per-kind tags on own profile); novel bookmarks read `/v1/user/bookmarks/novel` unfiltered via `ProfileNovelFeed`, carry `kind=novel` in tag routes (defaulting to illusts), preserve list tails when text filters match nothing, and `BookmarkTagsPage` wires its `scrollController` into `PullToRefresh` with `AlwaysScrollableScrollPhysics` so short and empty tag lists remain pull-refreshable.
- **Why:** User request for full novel bookmark and tag parity, plus reliable pull-to-refresh on sparse or empty bookmark tag lists.
- **Check:** `test/profile_bookmarks_test.dart` "your bookmarks switch to novels with their own tags"; `test/user_profile_test.dart` "work tabs follow the types a user has; each list shows its total"; `test/bookmark_tags_test.dart` "a bookmarks cursor pins the tag alongside restrict, for illusts and novels" "bookmark tag filter only changes loaded works locally" "a novel filter that matches nothing keeps the list tail" "BookmarkTagsPage wires scrollController to PullToRefresh and keeps short & empty lists pull-refreshable"; `test/navigation_router_test.dart` "bookmark tag route restores and writes its kind and restrict query"
- **Code:** `lib/features/profile/profile_filter_bar.dart`, `lib/features/profile/user_page.dart`, `lib/features/profile/profile_novel_feed.dart`, `lib/features/profile/bookmark_tag_feed_page.dart`, `lib/features/bookmark/bookmark_tags_page.dart`, `lib/core/novel/novel_feed_controller.dart`

### PAGE-02 Header controls stay mounted through the collapse
- **Rule:** Back and overflow sit on the profile header's topmost layer and stay mounted/tappable across collapse and pop animations.
- **Why:** Back previously vanished mid-handoff and during pop transitions.
- **Check:** `test/user_profile_test.dart` "header back button stays mounted through the pop animation"
- **Code:** `lib/features/profile/profile_header_delegate.dart`

## Discovery

### PAGE-03 A ranking date is part of the feed identity
- **Rule:** Past rankings use `date=yyyy-MM-dd` (invalid/out-of-range opens latest; picker caps at yesterday JST), key feeds by `(mode, date)`, reject cross-day cursors, expose a direct date-picker button on `RankingDateBar`, and only latest rankings write cold-start snapshots.
- **Why:** Past-day snapshots previously overwrote latest rankings on next launch, and switching between past dates previously forced reopening the category sheet.
- **Check:** `test/ranking_feed_test.dart` "a cursor from another day is rejected" "only the latest ranking writes the cold-start snapshot" "the picker stops at yesterday in Japan"; `test/ranking_categories_test.dart` "ranking editor requires explicit handle drag or × button and RankingDateBar exposes pick-date"
- **Code:** `lib/features/ranking`

### PAGE-04 Search result types keep their own filters
- **Rule:** Type switches replace the route and preserve per-type session filter drafts seeded from saved defaults (`TagSearchPage` stays stateful across tab switches); user searches carry no filters and hide the filter button in both the results bar (keeping search field width constant) and the docked search panel. For non-Premium tag searches with `bookmarkMin >= 100`, `SearchRepository` synthesizes server-indexed `users入り` `OR` groups (coercing `exact_match_for_tags` to `partial_match_for_tags` and pinning the rewritten `word` on cursors) while Premium accounts keep native `bookmark_num_min`/`bookmark_num_max`, and `SearchFilterSheet` exposes `AppChoiceChip` bookmark presets plus a non-tag local-filtering notice.
- **Why:** Switching via user tab previously wiped illustration filters, shifted the bar, or left a dead filter control on docked user search; free accounts otherwise hit `FeedAllHidden` because Pixiv ignores `bookmark_num_min` without Premium.
- **Check:** `test/search_result_page_test.dart` "each type switches to its own session filter set" "a user result route ignores stray filter params" "the user tab hides the filter button while keeping search field width constant" "TagSearchPage preserves tab switches and grid feeds align with 14dp horizontal margins"; `test/search_catalog_test.dart` "free-account tag search synthesizes users入り OR groups and pins rewritten word on cursors"
- **Code:** `lib/features/search/search_result_page.dart`, `lib/features/search/search_input_page.dart`, `lib/features/search/docked_search.dart`, `lib/features/search/search_filter_sheet.dart`, `lib/features/search/search_bookmark_filter_section.dart`, `lib/core/search/search_bookmark_synthesis.dart`, `lib/core/search/search_repository.dart`, `lib/features/search/tag_search_page.dart`

### PAGE-21 Search input completes the keyword at the caret
- **Rule:** Half/full-width spaces split keywords; autocomplete queries only the caret keyword on illust/novel tabs (skipping user search, stripping `-`, silent after space, on `OR`, or on a bare `-`, hiding duplicates); tap searches, ↖/long-press appends a space, trailing exclude inserts `-tag `, and `SearchOperatorBar` provides one-tap `OR` / `-` insertion; pinned search history entries (`PreferenceKeys.searchHistoryPinned`) stay at the front and survive `clear()`; the plain text field paints closed keywords as background pills; search input empty/shortcut/status views respect bottom IME insets.
- **Why:** User decision: multi-keyword editing without heavy chip-widget state machines, stale tag suggestions on user search, or keyboard-obscured start content, plus one-tap boolean query building and persistent pinned queries.
- **Check:** `test/search_input_test.dart` "suggestions complete the keyword at the caret" "a suggestion replaces the keyword, keeping its minus" "search keywords support OR operator skip, appendExcludedTag, and insertOrOperator" "SearchHistoryNotifier pins survive clear and persist across restart"
- **Code:** `lib/core/search/search_keywords.dart`, `lib/core/search/search_history.dart`, `lib/features/search/search_input_engine.dart`, `lib/features/search/search_input_chips.dart`, `lib/app/widgets/search_keyword_pills.dart`

### PAGE-05 Work strips omit hidden works
- **Rule:** `UserPreviewRow` (up to 3 works) and detail author strips omit blocked/muted works completely (never blurred; empty strips hide); malformed preview payloads fail loudly.
- **Why:** Blurred previews leaked hidden content and silent drops hid parser bugs.
- **Check:** `test/recommended_home_test.dart` "shows previews, skipping blocked and muted works ($page)"; `test/search_catalog_test.dart` "a malformed preview fails the user search page (PAGE-05)"; `test/illust_detail_actions_test.dart` "the author strip leaves this work and muted ones out and opens the others"
- **Code:** `lib/app/widgets/user_preview_row.dart`, `lib/features/illust/detail/author_works_section.dart`

### PAGE-06 The Spotlight cover comes from the list entry
- **Rule:** Spotlight articles use the list entry's pximg `thumbnailUrl`, falling back to the page cover and loaded article title (in both `AppTopBar` and share payload) on deep links without a list entry; embedded work titles are directly tappable alongside covers, and `SpotlightChallengeView` adapts safely to compact/landscape viewports.
- **Why:** `embed.pixiv.net` covers sit behind Cloudflare outside the network policy and failed intermittently, while deep links lacked titles and narrow challenge panes risked overflow.
- **Check:** `test/spotlight_article_test.dart` "the cover comes from the list entry on pximg" "SpotlightChallengeView skips WebView on unsupported platforms"
- **Code:** `lib/features/spotlight/spotlight_article_page.dart`, `lib/features/spotlight/spotlight_challenge_view.dart`

### PAGE-15 Ranking tabs are the user's categories minus the local block
- **Rule:** Ranking pages display saved categories minus local R-18/R-18G/AI blocks via `RankingTabs` (deep-linked hidden categories prepend transiently; `showRankingCategorySheet` uses a 2–3 column grid clipped above its footer divider, with an explicit leading drag handle for immediate reordering and a trailing `×` button to hide instead of accidental whole-tile tap hiding). Off-screen edits update routes only when visible; last category persists on hide/close, never per tap.
- **Why:** User decision; background route updates stole navigation, per-tap writes rebuilt the app root, and tap-to-hide tiles caused accidental removals when trying to drag.
- **Check:** `test/ranking_categories_test.dart` "a hidden route category goes first; a blocked one does not" "showRankingCategorySheet keeps 3 columns and stays above the footer divider across locales at 1280x800" "ranking editor requires explicit handle drag or × button and RankingDateBar exposes pick-date", `test/ranking_feed_test.dart` "an edit updates the tabs, keeps the category and saves" "an edit made from another branch waits to write the route" "a ranking opened without a mode lands on the last one"
- **Code:** `lib/features/ranking/ranking_tabs.dart`, `lib/app/widgets/ranking_category_sheet.dart`, `lib/core/ranking`

## Shared page pieces

### PAGE-07 An author link is the whole row or the whole card
- **Rule:** Header bylines use `AuthorRow` (avatar + name + chevron, >= 48dp single button); standalone author blocks use `PersonCard` (whole card tappable, trailing button independent, next surface tier on sheets); accounts always format `@account`.
- **Why:** Name-only links were too small and borderless rows looked non-interactive.
- **Check:** `test/shared_widgets_test.dart` "the whole row is one 48dp target that opens the profile" "a person card is one target; its trailing button is its own"
- **Code:** `lib/app/widgets/author_row.dart`, `lib/app/widgets/person_card.dart`

### PAGE-20 Pages carry no explanatory notes
- **Rule:** No page, group, sheet, or empty state includes explanatory usage/how-it-works paragraphs; secondary lines show only state, option effect, confirmation consequences, or credential-exposure risks (developer/help screens exempt).
- **Why:** User decision: explanatory footers cluttered pages and read like annotations.
- **Check:** `test/muted_items_page_test.dart` "an empty group says it is empty, off the cards"; `test/history_page_test.dart` "an empty history with recording off offers to turn it on"
- **Code:** `lib/features/settings/`, `lib/app/widgets/feed/feed_states.dart`

### PAGE-09 Translations are transient and share one entry
- **Rule:** Every translate entry uses `InlineTranslation` / `TranslationPanel`: unconfigured/off states show a neutral notice with a settings link; failed entries stay labelled "translate" to retry; translations never persist or overwrite originals.
- **Why:** User decision: keeps translation entry points consistent and non-destructive.
- **Check:** `test/illust_detail_actions_test.dart` "translate answers inside the menu, or points to settings while translation is off", `test/comment_item_test.dart` "translate is disabled while a translation runs"
- **Code:** `lib/app/widgets/inline_translation.dart`

### PAGE-10 Comment actions are pills; only delete hides behind ⋮
- **Rule:** Reply, view-replies, and translate sit as 32dp pill `TextButton`s (48dp target) in a `Wrap` under the body; only the viewer's own comment shows a trailing ⋮ `AppMenuButton` with danger delete; headers put name (`labelLarge`) and right-aligned date.
- **Why:** User decision: aligns dates cleanly and prevents `OverflowBar` stacking.
- **Check:** `test/comment_item_test.dart` "own comment: the ⋮ only deletes, in danger color" "another user's comment has no ⋮"
- **Code:** `lib/features/comments/comment_item.dart`

### PAGE-19 Composer panels rise and fall like the keyboard
- **Rule:** Emoji/stamp panels share the composer's bottom slot with the keyboard, sizing to persisted `KeyboardHeights` (160dp–60% height; 280dp default capped at 50% on landscape phones) on the sheet spring so the input bar stays stationary during swaps (holding height up to 600 ms while keyboard rises; `StateFade` between emoji/stamp; reduced motion jumps). `onGone` composers sit only on the active surface (DETAIL-17). `CommentRepliesPage` omits the cancel-reply `×` button when targeting the root comment (showing it only for child replies), and both comment pages use `deferCommentSendError` so failed sends report even after pop.
- **Why:** Eliminated composer jumps, misaligned panels above navigation bars, no-op reply cancel icons, and lost send errors after popping.
- **Check:** `test/comments_replies_test.dart` "the panel rises on a spring and waits for the keyboard" "composer reserves the sampled keyboard height for panels" "panels stand exactly where the keyboard stood" "keyboard heights persist per screen shape" "a turned phone keeps the panel to half the window" "CommentRepliesPage hides cancel-reply on root target and surfaces send errors after pop"
- **Code:** `lib/app/widgets/comment_composer.dart`, `lib/features/comments/comments_page.dart`, `lib/core/settings/keyboard_heights.dart`

## Library and management lists

### PAGE-11 Batch selection starts from a "manage" text button
- **Rule:** Batch-removal lists enter selection via a "manage" `TextButton` (hidden when empty; bulk clears live in ⋮), swap to `selectionAppBar` (back exits selection first), and use `SelectableTile` (while managing, `SelectableTile` excludes child focus via `ExcludeFocus` and handles `Enter`/`Space` keyboard activation to toggle selection instead of opening the underlying card). `WatchLaterPage` adds pointer `Shift`+click range and `Ctrl`/`Meta`+A; `HistoryPage` novel covers pass tile width via `LayoutBuilder` to `PixivImage.feed`.
- **Why:** Clearer discoverability than icons, standard desktop multi-select, safe keyboard management without opening cards, and bounded novel thumbnail decodes.
- **Check:** `test/history_page_test.dart` "system back exits selection mode instead of popping"; `test/watchlater_page_test.dart` "several works are removed at once and undone in place" "long press opens the sheet, or selects while managing" "pointer managing supports Shift+Click range selection and Ctrl+A select all"
- **Code:** `lib/app/widgets/selectable_tile.dart`, `lib/app/widgets/selection_app_bar.dart`, `lib/features/watchlater/watchlater_page.dart`, `lib/features/history/history_page.dart`

### PAGE-12 Removals return what Undo needs to restore positions
- **Rule:** Removals play exit animations without confirmation (batch cancel still confirms), commit in one write, and Undo restores exact indices/groups (`DownloadManager.dismissAll`/`restore`; `WatchLaterStore.removeAll`/`restoreAll` no-op after account switch).
- **Why:** Prevented Undo from losing ordering or leaking items across accounts.
- **Check:** `test/download_tasks_page_test.dart` "clear completed leaves failures and is undone in place" "removing a finished group is undone with its header", `test/watch_later_store_test.dart` "removeAll is undone in the old order" "undo after an account switch restores nothing"
- **Code:** `lib/core/download`, `lib/core/watchlater`

### PAGE-13 Muted works are blurred and keep old backups readable
- **Rule:** Muted works display blurred thumbnails; `MutedWork.fromJson` accepts legacy bare IDs and backup imports backfill missing metadata silently.
- **Why:** Keeps hidden art obscured and older backups compatible.
- **Check:** `test/mute_store_test.dart` "work mutes stored as bare ids still load"
- **Code:** `lib/features/settings/pages/muted_items_page.dart`, `lib/core/mute`

### PAGE-14 Management lists are lazy rows on one surface per group
- **Rule:** Download tasks render in one flat lazy list keyed by task/group ID (newest submission first; groups share one `SliverSurfaceList`, singletons stay plain; never reparent rows with `GlobalKey`s). Progress bars show only for unfinished states (`queued`, `running`, `finalizing`, or `canceling`); actions stay on the title row while >= 160dp remains for text, aligned on the trailing edge. Group header actions mirror per-task semantics: `retryable` offers Resume (when every retryable child is paused) or Retry (when interrupted/failed) plus Cancel; terminal `failed`/`canceled` groups offer Retry plus Remove Record (with Undo), never a no-op Cancel.
- **Why:** Avoided eager builds, reparent glitches, wasted lines on phones, misaligned group actions, and dead Cancel controls on terminal groups.
- **Check:** `test/download_tasks_page_test.dart` "a five-hundred-item list only builds the visible rows" "a group of one is a plain task row" "the newest submission comes first, groups among tasks" "on a phone a finished row keeps remove on its title row" "a collapsed group expands on tap and folds its children in" "failed/canceled group header offers retry and remove with undo; retryable error group offers retry and cancel"
- **Code:** `lib/features/settings/pages/download_tasks_page.dart`, `lib/features/settings/pages/download_task_rows.dart`, `lib/app/widgets/sliver_surface_list.dart`

## Wide and short windows

### PAGE-17 Short windows keep the primary action and the tab body
- **Rule:** Under 480dp tall and >= 600dp wide, `ScrollableFormShell` places header beside form (above 840dp non-short windows center header+form+action as one group); short profiles compress the banner to the toolbar band with a single-row 56dp-avatar identity strip so tabs and works appear above the fold.
- **Why:** Kept onboarding actions and profile works reachable on landscape phones and balanced on desktops.
- **Check:** `test/onboarding_pages_test.dart` "a phone held sideways shows the welcome action at once" "a large window centres the mark and the action as a group" "a phone keeps the action at the bottom, as before"; `test/user_profile_test.dart` "a phone held sideways shows the tabs and the works at once"
- **Code:** `lib/app/widgets/scrollable_form_shell.dart`, `lib/features/profile/user_page.dart`, `lib/features/profile/profile_header_delegate.dart`, `lib/features/profile/profile_skeleton.dart`

### PAGE-18 A mouse gets right-click, hover and scrollbars
- **Rule:** Every long-press surface also handles right-click: on PC it opens a pointer-anchored context menu via `showDisplayActions` (same items/order; single direct actions become one-item menus; Arrow/Esc navigate; non-menu forms open their panel), including `NovelEntry` (via `EntityRow.onSecondaryTapAt`: Open, Edit bookmark, Copy link) and `DetailPageImage` (via `showDetailPageContextMenu`: Select pages / Save page, desktop Copy original image, Copy link); on touch it opens the bottom panel (or `IosCardContextMenu` on iOS `IllustCard`, FB-17). Interactive non-button surfaces (`IllustCard`, `DetailPageImage`, `BookmarkSwitchButton`) show `SystemMouseCursors.click`, work cards add hover layers and keyboard focus (`FocusableActionDetector`, 2dp primary ring, Enter/Space open, Menu/Shift+F10 actions), and vertical lists show `mouseScrollbar` (outside coordinated `NestedScrollView` views).
- **Why:** Gives mouse and keyboard users native desktop ergonomics without breaking touch flows.
- **Check:** `test/card_action_test.dart` "a PC opens the card actions as a menu beside the pointer" "the PC menu reads the state when it opens, outside build" "a mouse lights the card on hover and opens it on right-click" "a card takes focus, opens on Enter and shows its actions on the menu keys"; `test/novel_entry_test.dart` "pointer secondary click on NovelEntry opens context menu"; `test/illust_detail_page_test.dart` "DetailPageImage shows pointer click cursor, context menu, and desktop shortcuts"; `test/illust_detail_actions_test.dart` "a PC opens the tag entries as a menu beside the chip"; `test/history_page_test.dart` "a PC right-click on a card offers Manage, then enters"; `test/illust_detail_download_test.dart` "a PC right-click offers the selection mode, then toggles"
- **Code:** `lib/app/widgets/display_actions.dart`, `lib/app/motion/app_overlays.dart`, `lib/app/widgets/card_actions/card_action_sheet.dart`, `lib/app/widgets/tag_actions_sheet.dart`, `lib/app/widgets/bookmark_switch_button.dart`, `lib/app/widgets/entity_row.dart`, `lib/app/widgets/novel_entry.dart`, `lib/app/widgets/feed/illust_card.dart`, `lib/features/illust/detail/widgets/detail_page_actions.dart`, `lib/features/illust/detail/widgets/page_image.dart`, `lib/app/scroll_behavior.dart`, `lib/app/pull_to_refresh.dart`

### PAGE-24 Pointer work card hover feedback and selectable comment lists
- **Rule:** Under `InputModality.pointer`, `IllustCard` keeps immediate `PressScale`, omits touch long-press (keeping silent right-click/menu keys), shows subtle `hoverColor` wash without duplicate hover pills, and disables text selection inside cards via `SelectionContainer.disabled`. `CommentsPage` wraps lists in `SelectionArea` excluding `CommentComposer`.
- **Why:** Clean pointer hover and selectable comments without stray card drags.
- **Check:** `test/feed_selection_test.dart` "Pointer IllustCard keeps immediate PressScale, omits touch long-press, and uses subtle hover highlight without duplicate pills"; `test/illust_detail_page_test.dart` "SelectionArea wraps detail and comments text while excluding IllustCard, collapsed fade, and touch tags"
- **Code:** `lib/app/widgets/feed/illust_card.dart`, `lib/features/comments/comments_page.dart`

### PAGE-25 Five-scenario responsive and input-modality verification matrix
- **Rule:** Responsive breakpoints, foldable hinge/tabletop splits, multi-monitor DPR changes, pointer affordances, and iOS frosted flows must pass the five golden scenarios (`compact_phone`, `foldable_book`, `foldable_tabletop`, `tablet_expanded`, `desktop_multimonitor_pointer`) plus `reduced_motion_gate`.
- **Why:** Prevents platform-specific changes from silently breaking sibling form factors.
- **Check:** `test/home_branch_stack_test.dart` "a turned phone keeps the bottom bar" "tablet landscape auto-collapses expanded ShellRail on Me and Settings"; `test/illust_detail_actions_test.dart` "splits into image pager and meta column"; `test/layout_breakpoints_test.dart` "AdaptiveTwoPane avoids vertical book hinge including rail" "AdaptiveTwoPane splits vertically on tabletop hinge"; `test/desktop_window_test.dart` "desktop pointer layout handles 1x<->2x DPR transitions without throwing"; `test/card_action_test.dart` "iOS card context menu respects reduced motion without scaling"
- **Code:** `lib/app/layout/app_breakpoints.dart`, `lib/app/layout/window_layout_spec.dart`, `lib/features/home/home_page.dart`, `lib/app/widgets/card_actions/ios_card_context_menu.dart`, `lib/app/navigation/func_page.dart`
