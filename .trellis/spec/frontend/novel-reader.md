---
prefix: NOVEL
applies_to:
  - lib/features/novel/**
  - lib/core/novel/**
reviewed: 2026-11-21
---

# Novel markup and reader

## Contents

- [Markup and layout](#markup-and-layout)
- [Reader stage](#reader-stage)

## Markup and layout

### NOVEL-01 Markup becomes typed tokens with visible fallbacks
- **Rule:** `NovelMarkupParser` scans body text into sealed typed tokens preserving raw text and attributes. Single-bracket markers (`[newpage]`, `[chapter:title]`, `[jump:page]`, `[uploadedimage:id]`, `[pixivimage:id-page]`, closed on the same line) and double-bracket ruby/`jumpuri` markers parse strictly; unknown/malformed markers stay visible as text. Valid `[[rb:base > reading]]` marks render as baseline-aligned furigana stacked above base glyphs (`novel_ruby.dart`, `novel_reader_text_blocks.dart`) with readings wrapped in `ExcludeSemantics` + `SelectionContainer.disabled` so copied text yields clean base characters and screen readers do not double-read furigana. Jumps allow only `pixivWeb` registry URIs or positive pages; image tokens expose only validated IDs; HTML never executes.
- **Why:** Regex stripping lost prose, unvalidated targets risked open redirects, ignoring single-bracket tags left real Pixiv chapters/breaks raw, and dropping ruby lost Japanese furigana readings.
- **Check:** `test/novel_markup_hardening_test.dart` "novel markup produces typed tokens and visible fallbacks" "single brackets mark only page breaks, chapters, jumps and images" "novel parser keeps raw attributes and reports malformed nesting"; `test/novel_reader_test.dart` "webview text pages and chapters at its single-bracket markers" "soft-wrapped paragraphs copy without hard newlines, mouse "
- **Code:** `lib/core/novel/novel_entity.dart`, `lib/features/novel/novel_layout.dart`, `lib/features/novel/novel_ruby.dart`, `lib/features/novel/novel_reader_text_blocks.dart`

### NOVEL-02 Parsing and layout are bounded and cancellable
- **Rule:** Source size, tokens, lines, pages, and diagnostics enforce explicit budgets (surfacing budget/retryable error states, never silent truncation). Async passes yield at chunk boundaries with monotonic progress and observable cancellation.
- **Why:** Huge novels froze the UI isolate.
- **Check:** `test/novel_markup_hardening_test.dart` "cancellable parser exposes cancellation instead of partial success" "document layout honors chapter/page boundaries and layout budget", `test/novel_reader_test.dart` "layout budget overflow renders a retryable error state"
- **Code:** `lib/features/novel/novel_layout.dart`

### NOVEL-03 Layouts commit through the reader gate, anchored by start
- **Rule:** Layouts commit only through `NovelReaderCommitGate` for current content version, chapter, and generation, restoring the on-screen start anchor (page start in page mode; `NovelScrollRelayoutAnchor` capturing lead padding, sub-item pixel offset, and translation-line ordinal in scroll mode). Scroll relayouts skip `jumpTo` when shift `< 0.5px` and apply `correctBy` during active scrolling so off-screen updates never jump back or cancel flings.
- **Why:** Late layouts overwrote newer ones, dropping sub-item offsets snapped readers upward, and unconditional jumps cut active swipes and flings short.
- **Check:** `test/novel_markup_hardening_test.dart` "reader gate rejects stale chapter and disposed layout results", `test/novel_reader_test.dart` "anchor notifications distinguish echoes from user turns" "scroll mode: open restores the line, a settle reports once," "scroll mode relayout keeps lead-padding and sub-item offset and "
- **Code:** `lib/features/novel/novel_reader.dart`, `lib/features/novel/novel_reader_handle.dart`, `lib/features/novel/novel_reader_text_blocks.dart`

### NOVEL-04 Translations add lines, never characters
- **Rule:** Bilingual translations lay out under their paragraph carrying its ID at end offset so anchors and history stay stable. Single-column page mode translates the current page then prewarms the next page; two-page spread mode translates both visible leaves in one batch and prewarms the next spread (`page + 2`/`page + 3`); scroll mode translates from the current viewport anchor downward (skipping scrolled-past paragraphs above the viewport). Failures disable bilingual mode with a prompt; translations live in memory only.
- **Why:** Anchors inside translations broke position restore when bilingual mode turned off, spread mode left the right leaf untranslated until a turn, and scroll mode wasted translation calls on scrolled-past text.
- **Check:** `test/novel_reader_test.dart` "a translation lays out under its paragraph and moves no anchor", `test/novel_reader_stage_test.dart` "translate this page: translations under the paragraphs, on with each" "bilingual mode batches both spread leaves and skips scrolled-past paragraphs in scroll mode"
- **Code:** `lib/features/novel/novel_bilingual.dart`, `lib/features/novel/novel_layout.dart`, `lib/features/novel/novel_reader_handle.dart`

### NOVEL-11 A pixiv novel opens on its title block; headings read as headings
- **Rule:** Every laid-out line carries a `NovelLineKind` measured and painted with `NovelLayoutStyle.lineStyle` (LAYOUT-04). Online novels open page 1 with a title block (heading title, author/series byline, blank-line gap) sharing paragraph 0 offset 0 (skipped by bilingual mode; omitted for local TXT); an initial chapter shares page 1 with it.
- **Why:** Readers opened abruptly into body text with indistinguishable chapter headings.
- **Check:** `test/novel_reader_test.dart` "each line lays out as tall as the style of its kind" "a title block opens page 1 and moves no character"
- **Code:** `lib/features/novel/novel_layout.dart`, `lib/features/novel/novel_page.dart`

### NOVEL-12 Every image marker takes a page; one that cannot show says so
- **Rule:** Valid Pixiv image markers become `NovelImageBlock`s preserving their paragraph ID and occupying one page-tall slot (skipped by bilingual mode; local TXT stays raw). `NovelIllustration` respects novel image quality (`detailUrlAt` for works with preview stand-in; payload `1200x1200`/original for uploads), shows a non-tappable hint notice if missing/restricted, and opens its viewer on image tap while side margins retain page-turn zones.
- **Why:** Raw `[uploadedimage:...]` tags leaked into prose and work previews were cropped 540px thumbnails.
- **Check:** `test/novel_markup_hardening_test.dart` "an image takes its marker line and moves no paragraph id"; `test/novel_reader_test.dart` "a work preview is found by page, then work; an image fills a page" "an image shows at its setting, opens on tap; margins turn"; `test/navigation_restoration_test.dart` "a novel image shows and opens its work page; a lost one says so"
- **Code:** `lib/core/novel/novel_entity.dart`, `lib/features/novel/novel_layout.dart`, `lib/features/novel/novel_illustration.dart`, `lib/app/navigation/routes.dart`

## Reader stage

### NOVEL-05 Chrome state and rendered state are separate
- **Rule:** Reader chrome runs on one stage-owned controller separating user intent from rendered state, with opaque palette-matched bars and the progress hint visible only while dismissed. Under `InputModality.pointer` when hidden, a compact pill (`ValueKey('novel-pointer-cue')`, `>= 48dp` target) sits inside the reserved bottom footer strip (`NovelReaderFooterStrip`, accounted for by `novelReaderFooterReserve`) beside the passive progress readout so it never occludes body text on narrow, medium, or two-page layouts without altering `PopScope`/center-tap behavior. `pinsImmersiveChromeForAccessibility` pins reader chrome open with `canPop: true` under `accessibleNavigation`, and `F` toggles chrome when not editing text. Chapter rows (`minTileHeight`) and series bars (`minHeight: novelSeriesBarHeight`) grow cleanly under large text scales. On iOS, `PopScope.canPop` stays `true` even while chrome is visible so left-edge swipe-back (TRANS-02) can leave the reader and restore `SystemUiMode.edgeToEdge`, while Android/desktop back still dismisses chrome first. `ShellRail` stays suppressed from the first loading/error frame (`NovelStatusScaffold` uses `AppTopBar` without a top hairline), and wide `SideSheet`s hide background floating bars while open. Settings sliders quantize font size to 1.0sp integer steps (`divisions: 18`) and persist only on `onChangeEnd`.
- **Why:** Eliminated overlapping hints/bars, top-corner pointer pills covering spread/narrow prose, translucent text smearing, 200dp rail jumps during load, dead iOS swipe-back while chrome is visible, slider write storms, and sheets clipping floating chrome.
- **Check:** `test/novel_reader_chrome_test.dart` "the progress hint never overlaps the sliding bottom bar", `test/novel_reader_stage_test.dart` "pointer reader shows bottom-strip cue clear of body text and restores chrome on tap" "key repeat turns pages without animation and settings sliders persist onChangeEnd" "iOS left-edge swipe pops NovelReaderStage even while chrome is visible and restores edgeToEdge"
- **Code:** `lib/features/novel/novel_reader_stage.dart`, `lib/features/novel/novel_reader_stage_widgets.dart`, `lib/features/novel/novel_reader_footer.dart`

### NOVEL-06 The series fetch is held by watch, once per session
- **Rule:** `novelSeriesNavProvider` (`autoDispose`, `retry: noRetry`) is kept alive with `ref.watch`, walks `next_url` boundedly (up to 20 pages) when the current chapter is not yet located or sits at the page tail, and refetches only via retry while keeping the series strip height constant (`novelSeriesBarHeight`). When fetch fails or pagination truncates, prev/next fall back to `seriesPrevId`/`seriesNextId`; when an exhausted series genuinely omits the chapter, navigation dead-ends without writing `markSeen`. Stepping between chapters replaces the current reader route (`openNovel(..., replaceCurrent: true)`) so back returns straight to the reading entry.
- **Why:** Build-time `ref.listen` refetched on every chrome toggle, page-1-only fetches broke multi-page series navigation, and pushing every chapter stacked unbounded back history.
- **Check:** `test/novel_reader_chrome_test.dart` "the series fetch happens once across chrome toggles" "a failed series fetch shows localized text and retries" "a series missing the current entry dead-ends navigation" "series pagination resolves chapters across next_url and keeps "; `test/navigation_router_test.dart` "a novel opened at a page carries it in memory, not the "
- **Code:** `lib/features/novel/novel_reader_stage.dart`, `lib/features/novel/novel_reader_series_nav.dart`, `lib/app/navigation/route_facade.dart`

### NOVEL-07 Opening and toggling never write reading history
- **Rule:** Opening the reader, toggling sheets, switching scroll/page modes, and opening at an account bookmark (NOVEL-15) write nothing; only a page turn or settled scroll to another line writes once (restored records are not rewritten).
- **Why:** Opening a novel previously overwrote stored progress with page 1.
- **Check:** `test/novel_reader_stage_test.dart` "open and sheet toggles never write; a page turn writes once" "a stored record restores without being rewritten" "scroll mode: open writes nothing, a settle writes once;"; `test/novel_reader_chrome_test.dart` "the account's bookmark: opened at without a place of your "
- **Code:** `lib/features/novel/novel_reader_stage.dart`

### NOVEL-08 The chrome and page turns leave the reader alone
- **Rule:** The stage preserves one reader widget across chrome toggles, page turns, and scrolls; nothing inside the reader rebuilds on page or scroll changes.
- **Why:** Rebuilding lines mid-swipe or on chrome toggle caused 25 ms frame spikes.
- **Check:** `test/novel_reader_stage_test.dart` "chrome and page turns keep the reader and its lines"
- **Code:** `lib/features/novel/novel_reader_stage.dart`, `lib/features/novel/novel_reader.dart`

### NOVEL-09 Pages and bars are built while the reader rests
- **Rule:** Page mode `PageView` sets `allowImplicitScrolling` with `ScrollCacheExtent.pixels(1)` so adjacent pages build at rest, queueing pages two away on `FeedTextWarmup` when settled (cleared on turn start). Dismissed chrome bars stay mounted offstage (`Visibility(maintainState: true)`, tickers stopped) and rebuild contents only while visible.
- **Why:** Cold page layout and repeated bar reconstruction dropped frames on every turn and reveal.
- **Check:** `test/novel_reader_chrome_test.dart` "immersive reader: chrome toggles, back closes chrome first"
- **Code:** `lib/features/novel/novel_reader.dart`, `lib/features/novel/novel_reader_views.dart`, `lib/features/novel/novel_reader_stage.dart`, `lib/features/novel/novel_reader_stage_widgets.dart`, `lib/app/widgets/feed/feed_text_warmup.dart`

### NOVEL-10 The progress hint and pill keep their contrast on every palette
- **Rule:** Palettes specifying an explicit `brightness` (`paper`, `sepia`, `night`) wrap the reader stage in a palette-matched `Theme` (`novelReaderThemeData` + `DefaultTextStyle`, preserving `FuncSemanticTokens`) so bars, series links, body links, and error views stay readable under opposite-brightness app themes while modal sheets keep the app theme. The bottom progress hint uses `bodySmall` at `novelReaderHintAlpha` (>= 4.5:1 on every palette), aligned to the centered `ContentWidths.article` column (or constrained to `hingeBounds.left` on `FoldPosture.book` when a valid hinge exists), with an ellipsizing `Flexible` title beside a fixed `page/total · percent%` suffix in `MergeSemantics`. In bottom chrome, the progress readout is an outlined pill (`novelReaderPillOutlineAlpha`, >= 3:1) opening the progress sheet. Reader keyboard shortcuts ignore `Alt`/`Ctrl`/`Meta` modifier chords.
- **Why:** Opposite-brightness app themes dropped reader bar/link contrast to ~1.2:1, low-alpha hints failed contrast, and unguarded arrow handlers swallowed desktop `Alt+Left/Right` navigation.
- **Check:** `test/novel_reader_settings_test.dart` "the progress hint keeps 4.5:1 and the pill outline 3:1 on every palette"; `test/novel_reader_stage_test.dart` "the immersive progress hint stays on the article column"; `test/novel_reader_chrome_test.dart` "reader palette isolates stage theme from opposite app brightness" "reader keyboard handler ignores Alt/Ctrl/Meta modifier chords"
- **Code:** `lib/features/novel/novel_reader_stage.dart`, `lib/features/novel/novel_reader_theme.dart`

### NOVEL-13 Scroll mode and paginated spread share one layout
- **Rule:** `NovelReaderSettings.pageTurn` defaults to scroll; `spreadMode` (`off`/`auto`/`landscape`/`always`, via `AppChoiceChip`, NAV-17) controls two-page paginated spreads (hinge-aligned on `FoldPosture.book`; `auto` spreads `>= 960dp` aspect `> 1.15`; leaf width clamped 380–540dp across a 44dp spine hairline, centered under `FittedBox(scaleDown)` with spine-centered progress; restoring or switching into spread page mode normalizes logical page to the even left leaf `(page ~/ 2) * 2`). `NovelScrollColumn` maps the same paginated lines (with `chapterGap`, `pageBreakGap`, top toolbar reserve, and 16dp edge fades + whole-line bottom clip), preserving the top line's page across mode switches. Both page and scroll modes group contiguous soft-wrapped lines of each paragraph into merged `NovelParagraphSlice` blocks (`NovelReaderTapSurface`; scroll mode caps each merged block at `NovelScrollParagraphBlocks.maxSliceHeight` = `320dp` along visual line boundaries so huge unbroken paragraphs keep lazy virtualization and viewport hit-testing) so soft wraps copy without artificial line breaks and mouse/trackpad double-click word selection works natively without delaying touch taps.
- **Why:** Phones favor continuous scroll while foldables and wide screens read best as balanced two-page spreads sharing one page/progress model, and line-split `Text` + competing `GestureDetector` broke desktop word selection and multi-line copying.
- **Check:** `test/novel_reader_settings_test.dart` "theme falls back to system, page turn to scroll"; `test/novel_reader_test.dart` "the scroll column runs pages on, with a rule at a new page and a gap" "scroll mode: a tap toggles the chrome or opens an image; one" "wide landscape spread shows two pages and steps by two" "soft-wrapped paragraphs copy without hard newlines, mouse "; `test/novel_reader_stage_test.dart` "scroll mode: open writes nothing, a settle writes once;"
- **Code:** `lib/core/novel/reader_settings.dart`, `lib/features/novel/novel_layout.dart`, `lib/features/novel/novel_reader.dart`, `lib/features/novel/novel_reader_views.dart`, `lib/features/novel/novel_reader_text_blocks.dart`, `lib/features/novel/novel_reader_stage.dart`, `lib/features/novel/novel_reader_stage_widgets.dart`

### NOVEL-14 An author's links lead where they say
- **Rule:** `[newpage]` splits Pixiv pages (`pixivPageStarts`, `pixivPageOf`); out-of-range `[jump:N]` stays raw with `invalidJump` diagnostic. Unlabelled jumps add no document text (skipping translation) and render localized `novelJumpToPage` links in accent color; `jumpuri` links delegate to `openPixivLink` (plain text in TXT files). Taps that arrest a fling do not activate links.
- **Why:** Branching Pixiv novels rely on `[jump:N]` navigation.
- **Check:** `test/novel_markup_hardening_test.dart` "a page jump counts Pixiv pages; one past the last reads as written"; `test/novel_reader_test.dart` "an author's links: a page jump brings its Pixiv page in "
- **Code:** `lib/core/novel/novel_entity.dart`, `lib/features/novel/novel_layout.dart`, `lib/features/novel/novel_reader.dart`, `lib/features/novel/novel_reader_views.dart`, `lib/app/widgets/caption_rich_text.dart`

### NOVEL-15 The progress sheet holds the place, the bookmark and the chapters
- **Rule:** Below the fixed slider, the progress sheet exposes Pixiv's account marker (`NovelEntity.markerPage`, direct writes via `novelMarkerWritesProvider`, updating `NovelStore` only on success) for multi-page/bookmarked Pixiv novels, plus a scrollable chapter list opening scrolled to and highlighting the active chapter (shrinking cleanly on `< 480dp` heights). While persisted resume anchors remain on the top visible line (scroll) or even left leaf (spread, `NOVEL-03`/`NOVEL-13`), display progress, active chapter highlight, and Pixiv bookmark targeting read `NovelReaderHandle.displayPage` / `displayAnchor` so scrolling to `maxScrollExtent` and viewing even-page wide spreads reach `100%`, highlight the final chapter, and bookmark the visible end/right leaf. Programmatic rapid taps accumulate target pages in-flight and `KeyRepeatEvent` steps without animation. Wide reader panels use `showAppAdaptiveSideSheet` (`maxWidth: 380`) with a header close button (`UiIcons.close`, `closeButtonTooltip`).
- **Why:** Account markers were unreachable, long TOCs or turned phones overflowed sheets, short final pages and even-page spreads were stuck below 100%, and rapid turns dropped or reset animations.
- **Check:** `test/novel_reader_chrome_test.dart` "the account's bookmark: opened at without a place of your " "a one-page novel without a bookmark offers none"; `test/novel_reader_stage_test.dart` "progress sheet: the chapter you are in is marked and in " "a turned phone fits the progress and settings sheets" "even-page wide spread reaches 100%, highlights last chapter, and bookmarks right leaf" "key repeat turns pages without animation and settings sliders persist onChangeEnd"; `test/novel_reader_test.dart` "rapid edge taps accumulate target pages instead of dropping turns" "displayPage and displayAnchor reach the end in scroll and spread modes while keeping restore anchors"; `test/novel_webview_text_test.dart` "the account's marker: its page, none, or a parse error"
- **Code:** `lib/features/novel/novel_reader.dart`, `lib/features/novel/novel_reader_handle.dart`, `lib/features/novel/novel_reader_stage.dart`, `lib/features/novel/novel_reader_stage_widgets.dart`, `lib/features/novel/novel_page.dart`, `lib/core/novel/novel_store.dart`, `lib/core/novel/novel_webview_text.dart`

### NOVEL-16 The info sheet states the novel's facts
- **Rule:** Below the author, the info sheet links the novel series (`NOVEL-18`) and lists available facts via `MetaFact` (length, views, bookmarks, full posting time via `AppFormat.date(withTime: true)`).
- **Why:** Payload metadata was hidden from readers.
- **Check:** `test/novel_reader_chrome_test.dart` "the info sheet links the series and states length, counts "
- **Code:** `lib/features/novel/novel_page.dart`, `lib/app/widgets/meta_fact.dart`

### NOVEL-17 The account's bookmarks have a list; a row opens at its bookmark
- **Rule:** Signed-in Me lists `/v2/novel/markers` (paged by `next_url`, rejecting missing novel or page `< 1`), seeding `NovelEntity.markerPage` and opening rows at their marker page via in-memory route `extra` (leaving local history untouched) with inline marker remove/restore through `NOVEL-15`.
- **Why:** Bookmarked novels were only reachable by re-opening each novel individually.
- **Check:** `test/novel_markers_test.dart` "the bookmark list pages by next_url; each novel lands with its " "an entry without a novel or a page is a parse error" "rows say where the bookmark is and open there; the button " "an empty list and a failed one say so"; `test/novel_reader_chrome_test.dart` "the account's bookmark: opened at without a place of your "; `test/navigation_router_test.dart` "a novel opened at a page carries it in memory, not the "; `test/settings_test.dart` "the Me header, manage button and end rows open their pages"
- **Code:** `lib/features/novel/novel_markers_page.dart`, `lib/core/novel/novel_feed_controller.dart`, `lib/core/novel/novel_repository.dart`, `lib/features/novel/novel_page.dart`, `lib/app/navigation/routes.dart`

### NOVEL-18 A novel series has a page that continues where you left
- **Rule:** `novel-series/:seriesId` (`openNovelSeries`) pages `/v2/novel/series` by `last_order` (restricted entries stay closed and non-tappable, sharing the `IllustSeriesPage` scaffold), marks the watchlist cursor on open, numbers rows as episodes without filtering, and offers a primary continue button backed by `NovelSeriesLastReadStore` (per-account, recency-trimmed to 200, independent of history toggle; also wired into watchlist novel sheets).
- **Why:** Novel series lacked a contents page and multi-day series reading needed resume-where-left-off.
- **Check:** `test/novel_series_test.dart` "a series page: its facts, numbered novels past the first "; `test/watchlist_page_test.dart` "watchlist page lists entries under both type tabs; a novel "
- **Code:** `lib/features/novel/novel_series_page.dart`, `lib/features/series/illust_series_page.dart`, `lib/core/novel/novel_feed_controller.dart`, `lib/core/novel/novel_repository.dart`, `lib/core/novel/reader_settings.dart`, `lib/features/novel/novel_page.dart`, `lib/features/novel/novel_reader_stage.dart`, `lib/features/novel/novel_reader_stage_widgets.dart`, `lib/features/watchlist/watchlist_page.dart`, `lib/app/navigation/routes.dart`
