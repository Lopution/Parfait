---
prefix: NOVEL
applies_to:
  - lib/features/novel/**
  - lib/core/novel/**
reviewed: 2026-11-01
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
  `[chapter:title]`, `[uploadedimage:id]` and `[pixivimage:id-page]` in
  single brackets (ruby and links in double); only those exact names,
  closed on their line, are single-bracket markers, so bracketed prose
  stays text. Malformed or unknown markers
  stay visible as raw text. Jumps go only to registry-allowed `pixivWeb`
  URIs or positive pages; image tokens expose only validated ids, never a
  URL or path. Body HTML is never executed.
- **Why:** Regex stripping dropped content; a foreign jump URI or an image
  path could have opened arbitrary pages or files. A parser that read only
  double brackets showed every real page break and chapter as raw text.
- **Check:** `test/novel_markup_hardening_test.dart` "novel markup produces typed tokens and visible fallbacks" "single brackets mark only page breaks, chapters and images" "novel parser keeps raw attributes and reports malformed nesting"; `test/novel_reader_test.dart` "webview text pages and chapters at its single-bracket markers"
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
  start anchor of the page on screen at commit time, and jumps the
  `PageController` only when the restored page differs.
- **Why:** A late layout overwrote a newer one; restoring by page index
  lost a swipe made while layout ran, and an unconditional jump cut the
  swipe short.
- **Check:** `test/novel_markup_hardening_test.dart` "reader gate rejects stale chapter and disposed layout results", `test/novel_reader_test.dart` "anchor notifications distinguish echoes from user turns"
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

### NOVEL-12 An image the payload carries takes a page of its own
- **Rule:** An image marker becomes a `NovelImageBlock` only when the
  webview payload carries its address (`NovelEntity.imageUrlFor`: an
  upload by id, its `1200x1200` before the original; a Pixiv work by
  `id-page`, then `id`); any other stays its marker, as text. The block
  keeps its marker line's paragraph id, so anchors and history saved
  before images showed still land. Layout gives it one line as tall as
  the page, alone on that page; the image is contained and centred, and
  only the image takes a tap: a Pixiv work opens its viewer at the
  marker's page, an upload opens alone (`novel/:id/image/:imageId`). The
  margins beside it keep the turn zones. Bilingual reading skips it.
- **Why:** Every image showed as a raw `[uploadedimage:…]` line (user report, 11-01).
- **Check:** `test/novel_markup_hardening_test.dart` "an image takes its marker line and moves no paragraph id"; `test/novel_reader_test.dart` "an image resolves by work page, then work, and fills a page" "an image opens on tap; the margins beside it turn the page"; `test/navigation_restoration_test.dart` "a novel image opens a work at its page, an upload alone"
- **Code:** `lib/core/novel/novel_entity.dart`, `lib/features/novel/novel_layout.dart`, `lib/features/novel/novel_reader.dart`, `lib/app/navigation/routes.dart`

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
- **Rule:** Opening the reader and toggling sheets write nothing; a page
  turn writes once; a restored record is not rewritten.
- **Why:** Opening a novel overwrote the stored position with page 1.
- **Check:** `test/novel_reader_stage_test.dart` "open and sheet toggles never write; a page turn writes once" "a stored record restores without being rewritten"
- **Code:** `lib/features/novel/novel_reader_stage.dart`

### NOVEL-08 The chrome and page turns leave the reader alone
- **Rule:** The stage keeps one reader widget while the novel, settings,
  initial anchor, text colour, translations and padding hold; the chrome,
  the progress hint and the anchor rebuild around it. The reader does not
  rebuild when the page changes: nothing it builds reads the page.
- **Why:** A tap that showed the chrome took 25 ms, and every page turn
  rebuilt the stage and the reader mid-swipe; each rebuild re-created
  every line of the pages on screen.
- **Check:** `test/novel_reader_stage_test.dart` "chrome and page turns keep the reader and its lines"
- **Code:** `lib/features/novel/novel_reader_stage.dart`, `lib/features/novel/novel_reader.dart`

### NOVEL-09 Pages and bars are built while the reader rests
- **Rule:** The reader's `PageView` has a one-pixel cache
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
