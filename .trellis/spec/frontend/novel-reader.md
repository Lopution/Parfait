---
prefix: NOVEL
applies_to:
  - lib/features/novel/**
  - lib/core/novel/**
reviewed: 2026-10-17
---

# Novel markup and reader

## Contents

- [Markup and layout](#markup-and-layout)
- [Reader stage](#reader-stage)

## Markup and layout

### NOVEL-01 Markup becomes typed tokens with visible fallbacks
- **Rule:** `NovelMarkupParser` scans the body into sealed typed tokens
  (text, newpage, chapter, ruby, jumps, images, unknown, budget exceeded)
  that keep their raw text and attributes. Malformed or unknown markers
  stay visible as raw text. Jumps go only to registry-allowed `pixivWeb`
  URIs or positive pages; image tokens expose only validated ids, never a
  URL or path. Body HTML is never executed.
- **Why:** Regex stripping dropped content; a foreign jump URI or an image
  path could have opened arbitrary pages or files.
- **Check:** `test/novel_markup_hardening_test.dart` "novel markup produces typed tokens and visible fallbacks" "novel parser keeps raw attributes and reports malformed nesting"
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
  them enters on the frame a turn lands. A dismissed chrome bar stays
  mounted offstage (`Visibility` with `maintainState`, tickers stopped);
  its contents are rebuilt only while the chrome shows.
- **Why:** The first frame of every swipe built the next page, about
  15 lines of text layout (8–21 ms). Each reveal re-created both bars and
  laid out their text again (4 ms on device).
- **Check:** `test/novel_reader_test.dart` "the pages beside the page on screen are built at rest"; `test/novel_reader_chrome_test.dart` "immersive reader: chrome toggles, back closes chrome first"
- **Code:** `lib/features/novel/novel_reader.dart`, `lib/features/novel/novel_reader_stage.dart`

### NOVEL-10 The progress hint keeps 4.5:1 on every palette
- **Rule:** The bottom progress hint uses `bodySmall` and the page's text
  color at `novelReaderHintAlpha`, set no fainter than keeps 4.5:1 on the
  system and every reader palette.
- **Why:** An 11sp hint at 45% of the text color measured about 2.9:1.
- **Check:** `test/novel_reader_settings_test.dart` "the progress hint keeps 4.5:1 on every palette"
- **Code:** `lib/features/novel/novel_reader_stage.dart`
