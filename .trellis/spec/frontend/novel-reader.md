---
prefix: NOVEL
applies_to:
  - lib/features/novel/**
  - lib/core/novel/**
reviewed: 2026-11-02
---

# Novel markup and reader

## Contents

- [Markup and layout](#markup-and-layout)
- [Reader stage](#reader-stage)

## Markup and layout

### NOVEL-01 Markup becomes typed tokens with visible fallbacks
- **Rule:** `NovelMarkupParser` scans the body into sealed typed tokens
  (text, newpage, chapter, ruby, jumps, images, unknown, budget exceeded)
  that keep their raw text and attributes. Pixiv writes `[newpage]`,
  `[chapter:title]`, `[jump:page]`, `[uploadedimage:id]` and
  `[pixivimage:id-page]` in single brackets (ruby and `jumpuri` links in
  double); only those exact names,
  closed on their line, are single-bracket markers, so bracketed prose
  stays text. Malformed or unknown markers
  stay visible as raw text. Jumps go only to registry-allowed `pixivWeb`
  URIs or positive pages; image tokens expose only validated ids, never a
  URL or path. Body HTML is never executed.
- **Why:** Regex stripping dropped content; a foreign jump URI or an image
  path could have opened arbitrary pages or files. A parser that read only
  double brackets showed every real page break and chapter as raw text.
- **Check:** `test/novel_markup_hardening_test.dart` "novel markup produces typed tokens and visible fallbacks" "single brackets mark only page breaks, chapters, jumps and images" "novel parser keeps raw attributes and reports malformed nesting"; `test/novel_reader_test.dart` "webview text pages and chapters at its single-bracket markers"
- **Code:** `lib/core/novel/novel_entity.dart`

### NOVEL-02 Parsing and layout are bounded and cancellable
- **Rule:** Source size, tokens, lines, pages and diagnostics have budgets;
  overflow is an explicit budget state or a retryable error, never a
  silently truncated body. Async work yields at chunk boundaries and
  reports monotonic progress; cancellation is observable, never partial
  success.
- **Why:** Huge novels froze the UI isolate.
- **Check:** `test/novel_markup_hardening_test.dart` "cancellable parser exposes cancellation instead of partial success" "document layout honors chapter/page boundaries and layout budget", `test/novel_reader_test.dart` "layout budget overflow renders a retryable error state"
- **Code:** `lib/features/novel/novel_layout.dart`

### NOVEL-03 Layouts commit through the reader gate, anchored by start
- **Rule:** A layout commits only through `NovelReaderCommitGate` for the
  current content version, chapter and generation. A commit restores the
  place on screen at commit time: in page mode the start anchor of the
  page, jumping the `PageController` only when the restored page
  differs; in scroll mode the line at the top, jumping the column only
  when that line's offset differs.
- **Why:** A late layout overwrote a newer one; restoring by page index
  lost a swipe made while layout ran, and an unconditional jump cut the
  swipe short.
- **Check:** `test/novel_markup_hardening_test.dart` "reader gate rejects stale chapter and disposed layout results", `test/novel_reader_test.dart` "anchor notifications distinguish echoes from user turns" "scroll mode: open restores the line, a settle reports once,"
- **Code:** `lib/features/novel/novel_reader.dart`

### NOVEL-04 Translations add lines, never characters
- **Rule:** Bilingual reading lays each translation under its paragraph,
  carrying the paragraph's id with both offsets at its end, so anchors,
  progress and history never point into a translation. The stage
  translates one page's missing paragraphs per batch; a failure turns the
  mode off with a prompt. Translations live in memory only.
- **Why:** Anchors pointing into translations broke restore after the mode
  was turned off.
- **Check:** `test/novel_reader_test.dart` "a translation lays out under its paragraph and moves no anchor", `test/novel_reader_stage_test.dart` "translate this page: translations under the paragraphs, on with each"
- **Code:** `lib/features/novel/novel_bilingual.dart`, `lib/features/novel/novel_layout.dart`

### NOVEL-11 A pixiv novel opens on its title block; headings read as headings
- **Rule:** Every laid-out line has a `NovelLineKind`, and
  `NovelLayoutStyle.lineStyle` gives the one style it is measured and
  painted with (LAYOUT-04). A chapter heading takes the heading style.
  An online novel's first page opens with a title block: the title in the
  heading style, then a byline (author, and series when there is one),
  then a blank line's distance to the text. Like translations, the block
  adds lines, never characters: its lines carry the first paragraph's id
  at offset 0, and bilingual reading skips them. A chapter at the very
  start shares page 1 with the block. Local TXT files show none.
- **Why:** The reader opened straight into the body, and a chapter heading
  read as one more paragraph (critique, 10-31).
- **Check:** `test/novel_reader_test.dart` "each line lays out as tall as the style of its kind" "a title block opens page 1 and moves no character"
- **Code:** `lib/features/novel/novel_layout.dart`, `lib/features/novel/novel_page.dart`

### NOVEL-12 Every image marker takes a page; one that cannot show says so
- **Rule:** In a pixiv body every valid image marker becomes a
  `NovelImageBlock` (a local file's stay text). The block keeps its
  marker line's paragraph id, so anchors and history saved before images
  showed still land. Layout gives it one line as tall as the page, alone
  on that page. `NovelIllustration` draws it at the novel image quality
  setting (大图/原图): an upload from the payload (`1200x1200` or the
  original); a Pixiv work's page from the work's detail
  (`detailUrlAt`), the payload's preview standing in while it loads or
  when it fails. A work the detail reports gone, restricted or short of
  the page, or an upload the payload lacks, shows a notice in the hint
  colour and takes no tap. An image is contained and centred, and only
  the image takes a tap: a work opens its viewer at the marker's page,
  an upload opens alone (`novel/:id/image/:imageId`, at the viewer
  quality). In page mode the margins beside it keep the turn zones.
  Bilingual reading skips it.
- **Why:** Every image showed as a raw `[uploadedimage:…]` line, and the
  payload's work preview is a 540px crop (user report, 11-01).
- **Check:** `test/novel_markup_hardening_test.dart` "an image takes its marker line and moves no paragraph id"; `test/novel_reader_test.dart` "a work preview is found by page, then work; an image fills a page" "an image shows at its setting, opens on tap; margins turn"; `test/navigation_restoration_test.dart` "a novel image shows and opens its work page; a lost one says so"
- **Code:** `lib/core/novel/novel_entity.dart`, `lib/features/novel/novel_layout.dart`, `lib/features/novel/novel_illustration.dart`, `lib/app/navigation/routes.dart`

## Reader stage

### NOVEL-05 Chrome state and rendered state are separate
- **Rule:** The reader chrome runs on one stage-owned controller; the
  user's intent and the rendered state are separate fields. The progress
  hint exists only while the controller is dismissed. The bars are opaque
  in the reading palette's background.
- **Why:** The hint painted under the exiting bottom bar. Text showing
  through see-through bars read as a smudge behind the controls.
- **Check:** `test/novel_reader_chrome_test.dart` "the progress hint never overlaps the sliding bottom bar"
- **Code:** `lib/features/novel/novel_reader_stage.dart`

### NOVEL-06 The series fetch is held by watch, once per session
- **Rule:** The series provider is an `autoDispose` family the stage keeps
  alive with `ref.watch` in build, with `retry: (_, _) => null`. Only the
  retry button refetches. The series strip keeps one height in every
  state.
- **Why:** A build-time `ref.listen` re-subscribed with a dispose gap and
  refetched on every chrome toggle; a resizing strip jumped under the
  bottom chrome.
- **Check:** `test/novel_reader_chrome_test.dart` "the series fetch happens once across chrome toggles" "a failed series fetch shows localized text and retries"
- **Code:** `lib/features/novel/novel_reader_stage.dart`

### NOVEL-07 Opening and toggling never write reading history
- **Rule:** Opening the reader, toggling sheets and switching between
  scrolling and pages write nothing; a page turn, or a scroll that comes
  to rest on another line, writes once; a restored record is not
  rewritten. A Pixiv novel with no record of this account's opens at the
  account's bookmark (NOVEL-15) and writes nothing either.
- **Why:** Opening a novel overwrote the stored position with page 1.
- **Check:** `test/novel_reader_stage_test.dart` "open and sheet toggles never write; a page turn writes once" "a stored record restores without being rewritten" "scroll mode: open writes nothing, a settle writes once;"; `test/novel_reader_chrome_test.dart` "the account's bookmark: opened at without a place of your "
- **Code:** `lib/features/novel/novel_reader_stage.dart`

### NOVEL-08 The chrome and page turns leave the reader alone
- **Rule:** The stage keeps one reader widget while the novel, settings,
  initial anchor, text colour, translations and padding hold; the chrome,
  the progress hint and the anchor rebuild around it. The reader does not
  rebuild when the page changes or the column scrolls: nothing it builds
  reads the page.
- **Why:** A tap that showed the chrome took 25 ms, and every page turn
  rebuilt the stage and the reader mid-swipe; each rebuild re-created
  every line of the pages on screen.
- **Check:** `test/novel_reader_stage_test.dart` "chrome and page turns keep the reader and its lines"
- **Code:** `lib/features/novel/novel_reader_stage.dart`, `lib/features/novel/novel_reader.dart`

### NOVEL-09 Pages and bars are built while the reader rests
- **Rule:** In page mode the reader's `PageView` has a one-pixel cache
  (`allowImplicitScrolling` with `ScrollCacheExtent.pixels(1)`): the
  pages beside the one on screen are built at rest, and the page after
  them enters on the frame a turn lands. Once a turn or a relayout comes
  to rest, the lines of the pages two away are queued on a
  `FeedTextWarmup` (`_NovelPage.warmTexts`: the page's styles through
  `warmStyle`, the UI locale, as the lines set none); a turn starting
  clears the queue. A dismissed chrome bar stays mounted offstage
  (`Visibility` with `maintainState`, tickers stopped); its contents are
  rebuilt only while the chrome shows.
- **Why:** The first frame of every swipe built the next page, about
  15 lines of text layout (8–21 ms). The landing frame then built the page
  after it and laid out its lines cold (16 dropped frames in a turning
  trace, Shaft 1). Each reveal re-created both bars and laid out their
  text again (4 ms on device).
- **Check:** `test/novel_reader_chrome_test.dart` "immersive reader: chrome toggles, back closes chrome first"
- **Code:** `lib/features/novel/novel_reader.dart`, `lib/features/novel/novel_reader_stage.dart`, `lib/app/widgets/feed/feed_text_warmup.dart`

### NOVEL-10 The progress hint and pill keep their contrast on every palette
- **Rule:** The bottom progress hint uses `bodySmall` and the page's text
  color at `novelReaderHintAlpha`, set no fainter than keeps 4.5:1 on the
  system and every reader palette. In the chrome's bottom bar the
  progress readout is an outlined pill ending in an expand glyph, which
  opens the progress sheet; its outline is the text color at
  `novelReaderPillOutlineAlpha`, no fainter than keeps 3:1 on every
  palette.
- **Why:** An 11sp hint at 45% of the text color measured about 2.9:1.
  The readout as bare text did not show it opened anything (user report,
  10-25).
- **Check:** `test/novel_reader_settings_test.dart` "the progress hint keeps 4.5:1 and the pill outline 3:1 on every palette"
- **Code:** `lib/features/novel/novel_reader_stage.dart`

### NOVEL-13 Scroll mode is one column over the same pages
- **Rule:** `NovelReaderSettings.pageTurn` picks scrolling (the default,
  and what a saved setting without the field opens in) or pages; the
  reader settings sheet switches it. Scroll mode shows the paginated
  layout's lines as one `ListView` column (`NovelScrollColumn`), each
  line at its measured extent, so pages stay the unit of progress,
  chapters, jumps and bilingual batches. A page that ran on continues
  the column; a chapter starts after `chapterGap`, an author's
  `[newpage]` after a short faint rule (`pageBreakGap`); an image keeps
  its page-tall slot. Lines paint only between the page margins and
  touches land anywhere. A tap anywhere toggles the chrome or opens the
  image under it, unless it caught the column moving: then it only
  stops it. A scroll that settles reports the line at the top and its
  page; `goToPage` scrolls that page's first line to the top. Switching
  modes opens the page holding the top line, or the column at the
  page's first line.
- **Why:** Pages turned left and right were the only way to read; long
  novels and phones read by scrolling (user request, 11-01).
- **Check:** `test/novel_reader_settings_test.dart` "theme falls back to system, page turn to scroll"; `test/novel_reader_test.dart` "the scroll column runs pages on, with a rule at a new page and a gap" "scroll mode: a tap toggles the chrome or opens an image; one"; `test/novel_reader_stage_test.dart` "scroll mode: open writes nothing, a settle writes once;"
- **Code:** `lib/core/novel/reader_settings.dart`, `lib/features/novel/novel_layout.dart`, `lib/features/novel/novel_reader.dart`, `lib/features/novel/novel_reader_stage.dart`

### NOVEL-14 An author's links lead where they say
- **Rule:** A body's `[newpage]` markers split it into Pixiv pages
  (`NovelMarkupDocument.pixivPageStarts`, `pixivPageOf`); a chapter
  starts none. A page jump counts in them: one past the last page reads
  as written with an `invalidJump` diagnostic. A page jump without a
  label of its own adds no text to the document, so bilingual reading
  never translates it; the layout lays out the reader's label
  (`novelJumpToPage`) at its place, and a line carries its links'
  ranges. Links show in the accent colour in both modes: a page jump
  brings its page's first line, as a turn does; a `jumpuri` link opens
  as a caption link does (`openPixivLink`), and reads as text where the
  host opens none (a TXT file). A tap that stops a fling only stops it.
- **Why:** Choose-your-path novels branch by `[jump:N]`, which showed
  as raw text and led nowhere (user request, 11-02).
- **Check:** `test/novel_markup_hardening_test.dart` "a page jump counts Pixiv pages; one past the last reads as written"; `test/novel_reader_test.dart` "an author's links: a page jump brings its Pixiv page in "
- **Code:** `lib/core/novel/novel_entity.dart`, `lib/features/novel/novel_layout.dart`, `lib/features/novel/novel_reader.dart`, `lib/app/widgets/caption_rich_text.dart`

### NOVEL-15 The progress sheet holds the place, the bookmark and the chapters
- **Rule:** Under the slider, the progress sheet shows the account's
  bookmark (Pixiv's marker, one per novel at the start of a Pixiv page,
  `NovelEntity.markerPage` from the webview payload) for a Pixiv novel
  read with an account, when the novel has more than one Pixiv page or
  a bookmark already. Without one, a row marks the Pixiv page of the
  reader's top line; with one, the row names its screen page and goes
  there, moves it to the reader's Pixiv page when that differs, and
  removes it. Writes go straight to the account
  (`novelMarkerWritesProvider`, not the action queue): the row waits
  for the answer, the novel in `NovelStore` changes only on success, and
  a failure says so. The chapter list marks the chapter the reader is
  in, opens scrolled to it, and grows to half the screen. The slider and
  its buttons stay put; below them the bookmark and the chapters scroll
  inside what is left of the sheet, and on a window under 480dp tall the
  list may shrink to two rows. The settings sheet scrolls the same way.
- **Why:** Pixiv's bookmark, kept with the account, was unreachable;
  a long table of contents showed four rows and no place in it (user
  request, 11-02). On a turned phone both sheets overflowed.
- **Check:** `test/novel_reader_chrome_test.dart` "the account's bookmark: opened at without a place of your " "a one-page novel without a bookmark offers none"; `test/novel_reader_stage_test.dart` "progress sheet: the chapter you are in is marked and in "; `test/novel_reader_stage_test.dart` "a turned phone fits the progress and settings sheets"; `test/novel_webview_text_test.dart` "the account's marker: its page, none, or a parse error"
- **Code:** `lib/features/novel/novel_reader_stage.dart`, `lib/features/novel/novel_page.dart`, `lib/core/novel/novel_store.dart`, `lib/core/novel/novel_webview_text.dart`

### NOVEL-16 The info sheet states the novel's facts
- **Rule:** Under the author, the info sheet links the novel's series
  (one button with a chevron, as the author's row, opening the series
  page of NOVEL-18), then lists the novel's facts as the illust detail
  lists a work's (`MetaFact`, wrapping as whole facts, one semantics
  node): its length (`AppFormat.count` and `novelWords`, as its card),
  views, bookmarks and the full posting time
  (`AppFormat.date(withTime: true)`); a fact the payload lacks is left
  out.
- **Why:** Length, date and series were in the payload but nowhere in
  the reader (user request, 11-02); the series had nowhere to lead until
  it had a page.
- **Check:** `test/novel_reader_chrome_test.dart` "the info sheet links the series and states length, counts "
- **Code:** `lib/features/novel/novel_page.dart`, `lib/app/widgets/meta_fact.dart`

### NOVEL-17 The account's bookmarks have a list; a row opens at its bookmark
- **Rule:** A signed-in Me page lists the novels the account has a
  bookmark in (`/v2/novel/markers`, paged by its `next_url`; an entry
  without a novel or a page of at least 1 is a parse error). Each row
  is the novel's card with its bookmark's Pixiv page above the title,
  and the list seeds `NovelEntity.markerPage` so the reader and the list
  agree. Tapping a row opens the reader at that page, ahead of a saved
  place, which it leaves unchanged; the page rides in the route's
  in-memory `extra`, so a restored route opens as usual. The row's
  button removes the bookmark and puts it back at the page it was on,
  through the same writes as the progress sheet (NOVEL-15).
- **Why:** A bookmark was only reachable from inside the novel it was
  in (user request, 11-02).
- **Check:** `test/novel_markers_test.dart` "the bookmark list pages by next_url; each novel lands with its " "an entry without a novel or a page is a parse error" "rows say where the bookmark is and open there; the button " "an empty list and a failed one say so"; `test/novel_reader_chrome_test.dart` "the account's bookmark: opened at without a place of your "; `test/navigation_router_test.dart` "a novel opened at a page carries it in memory, not the "; `test/settings_test.dart` "the Me header, manage button and end rows open their pages"
- **Code:** `lib/features/novel/novel_markers_page.dart`, `lib/core/novel/novel_feed_controller.dart`, `lib/core/novel/novel_repository.dart`, `lib/features/novel/novel_page.dart`, `lib/app/navigation/routes.dart`

### NOVEL-18 A novel series has a page that continues where you left
- **Rule:** `novel-series/:seriesId` opens on the current stack
  (`openNovelSeries`) from the info sheet's series, the reader's series
  bar title and the watchlist novel entry's contents item. It reads
  `/v2/novel/series`, paged by `last_order`; a malformed entry is a
  parse error, and a restricted entry (`visible: false`) needs only its
  id, title and order, and stays closed whatever the novel store kept. The header holds the title, the author, the
  works count with the completed and original labels, the actions and
  the caption collapsed to three lines; opening it marks the watchlist
  cursor at the latest novel. Rows are novel cards under their
  「第 n 话」, without the series name in their length line, in series
  order and not filtered, as the manga series; a
  restricted row shows pixiv's reason, or the generic one, and does not
  open. The primary action continues at the novel this account last
  opened in the series (「继续第 n 话」 once its entry has loaded,
  「继续阅读」 before), else starts at the first; starting from the
  first and reading the latest are text buttons below, and a novel
  opens at its saved place. The reader records the series' last-opened
  novel when it opens one that names a series:
  `NovelSeriesLastReadStore`, keyed by account and series, recency
  trimmed to 200, kept across restarts and whatever the history
  setting. The watchlist novel entry's sheet continues there too
  (「继续阅读」: the record keeps no episode number).
- **Why:** The series was named but led nowhere, and a followed novel
  series had no contents; no other client continues a novel series, and
  novels are read over days (user request, 11-02).
- **Check:** `test/novel_series_test.dart` "a series page: its facts, numbered novels past the first "; `test/watchlist_page_test.dart` "watchlist page lists entries under both type tabs; a novel "
- **Code:** `lib/features/novel/novel_series_page.dart`, `lib/core/novel/novel_feed_controller.dart`, `lib/core/novel/novel_repository.dart`, `lib/core/novel/reader_settings.dart`, `lib/features/novel/novel_page.dart`, `lib/features/novel/novel_reader_stage.dart`, `lib/features/watchlist/watchlist_page.dart`, `lib/app/navigation/routes.dart`
