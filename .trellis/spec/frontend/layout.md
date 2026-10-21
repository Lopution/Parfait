---
prefix: LAYOUT
applies_to:
  - lib/app/widgets/**
  - lib/app/format/**
  - lib/features/**
  - lib/l10n/**
reviewed: 2026-10-17
---

# Layout across locales, text sizes and keyboards

## Contents

- [Text in every locale](#text-in-every-locale)
- [Locale layout matrix](#locale-layout-matrix)
- [Boxes, headers and keyboards](#boxes-headers-and-keyboards)
- [Semantics](#semantics)
- [Edges](#edges)

## Text in every locale

### LAYOUT-01 UI text is never cut, clipped or shrunk below 0.8
- **Rule:** UI text (a paragraph equal to one of the locale's l10n
  messages) is never cut by `maxLines`, clipped in height, wider than its
  box, or scaled below `LabelFit.minScale` (0.8). The one exception: in
  the compact profile a `FitLabel` at the 0.8 floor may ellipsize and
  then carries its full text in a tooltip. User content (titles, names,
  tags, captions, comments) may ellipsize.
- **Why:** Every screen ships in zh, en, ja and ru down to 320dp at large
  text; Russian and English labels run up to twice as wide as Chinese.
- **Check:** `test/locale_layout/harness_test.dart` "catches UI text ellipsized at maxLines" "catches a FittedBox shrinking UI text below 0.8" "lets a FitLabel ellipsize in the compact profile only"
- **Code:** `lib/app/widgets/fit_label.dart`

### LAYOUT-02 Fix a failing layout in a fixed order
- **Rule:** Never branch per language. Fix in this order: (1) wrap (body
  copy, settings rows, dialogs, button rows via `Wrap`/`OverflowBar`;
  text-field helpers get `helperMaxLines`); (2) scroll (tab rows); (3)
  one shared `LabelFit` for a group of compact labels; (4) shorten the
  translation in all four languages together, Chinese changing only for
  its own layout, each change listed in the PR as key, language,
  old → new; (5) only then `FitLabel` in the compact profile. Single-line
  slots (top-bar titles, search hints, chip labels) go straight to (4) or
  carry less text.
- **Why:** Per-language patches and `FittedBox` shrank labels to 0.5 in
  long locales.
- **Check:** manual
- **Code:** `lib/app/widgets/fit_label.dart`

### LAYOUT-03 Label-value pairs and punctuation follow the locale
- **Rule:** A label followed by its value goes through
  `l10n.labelValue(label, value)` (errors through `errorWithReason`),
  never `'$label: $value'`. Chinese copy uses full-width punctuation and
  a space between Chinese and Latin words.
- **Why:** Chinese and Japanese take a full-width colon with no space.
- **Check:** `test/architecture/l10n_placeholders_test.dart`
- **Code:** `lib/l10n`

### LAYOUT-04 Measure text with the style it paints with
- **Rule:** A widget that measures its own text measures with the exact
  style and text scaler it paints with. `FitLabel` never measures; its
  host computes the fit from the slot it lays out.
- **Why:** Measured and painted widths disagreed under non-linear text
  scalers, so labels ellipsized that should have fit.
- **Check:** `test/fit_label_test.dart` "the painted width is the measured width times the scale" "a non-linear text scaler measures and paints alike"
- **Code:** `lib/app/widgets/fit_label.dart`, `lib/app/widgets/func_bottom_nav.dart`, `lib/app/widgets/app_tab_bar.dart`

### LAYOUT-05 The selection bar title is the bare count
- **Rule:** Lists in selection mode use `selectionAppBar`; its title is
  the number alone, with `selectedCount(n)` as the semantics label.
- **Why:** Next to three actions a sentence did not fit 320dp at large
  text, and an ellipsis cut the number off the Russian copy.
- **Check:** `test/locale_layout/lists_layout_test.dart`
- **Code:** `lib/app/widgets/selection_app_bar.dart`

### LAYOUT-06 Dates and counts go through AppFormat
- **Rule:** User-facing dates use `AppFormat.date`/`relative`, counts
  `AppFormat.count`; a number that changes in place also takes
  `.tabular`. Data formats (route query dates, file names) stay out and
  are allow-listed with a reason in the architecture test.
- **Why:** Hand-formatted dates and `'${n}k'` ignored the locale
  (zh 1.2万, en 12K); changing digits shifted their neighbours.
- **Check:** `test/architecture/format_and_font_test.dart` "user-facing dates go through AppFormat" "counts go through AppFormat"
- **Code:** `lib/app/format`

## Locale layout matrix

### LAYOUT-07 Pages are checked in every locale and profile
- **Rule:** A page with UI text registers in `test/locale_layout/` with
  `localeLayoutMatrix`, builds with `localeLayoutApp`, settles with
  `settleLayout` (shimmer never settles `pumpAndSettle`) and checks with
  `expectPageLayoutIntact`. Page setups live in `test/helpers/`, shared
  with the page's own tests. Detector exemptions are structural, never
  per language. For alignment, render temporary goldens and look; do not
  commit them.
- **Why:** The matrix runs real glyph widths in regular (360×780, 1.0) and
  compact (320×568, 1.3) profiles; it cannot see misalignment.
- **Check:** `test/locale_layout/harness_test.dart`
- **Code:** `test/helpers/locale_layout.dart`

## Boxes, headers and keyboards

### LAYOUT-08 Headers with text measure their extent
- **Rule:** A `SliverPersistentHeaderDelegate` whose content holds text
  never hard-codes `maxExtent`: it measures the laid-out content after the
  frame and feeds it back, keeping the estimate frame transparent.
- **Why:** A fixed extent overflowed at large text scales and in longer
  translations.
- **Check:** `test/user_profile_test.dart` "header height tracks the drag without jumps"
- **Code:** `lib/features/profile/profile_header_delegate.dart`

### LAYOUT-09 A Stack does not clip; add a ClipRect
- **Rule:** Content that must stay inside a boundary gets an explicit
  `ClipRect`; a `Stack` passes its constraints to non-positioned children
  and lets positioned `OverflowBox` children paint outside.
- **Why:** The profile identity block overflowed the collapsing header.
- **Check:** manual
- **Code:** `lib/features/profile/profile_header_delegate.dart`

### LAYOUT-10 The keyboard pads the scrollable, not the page
- **Rule:** A `Scaffold` with a text field sets
  `resizeToAvoidBottomInset: false` and pads its scrollable by
  `viewInsets.bottom`. A composer raised over the page for a moment (the
  detail page's) takes the inset in its own bottom slot instead, and the
  page under it keeps its size.
- **Why:** The default resize compressed the page geometry under the
  keyboard. Resizing a long detail page under a passing composer would
  lay it out on every keyboard frame and move what its Hero measures.
- **Check:** `test/scrollable_form_shell_test.dart`
- **Code:** `lib/app/widgets/scrollable_form_shell.dart`

### LAYOUT-11 Long documents use one SelectionArea
- **Rule:** A long document page wraps its one list in a single
  `SelectionArea` and renders paragraphs as plain `Text`, never
  `SelectableText` per paragraph.
- **Why:** Selection cannot span `SelectableText` paragraphs. Each also
  owns a scrollable that inherited the bouncing physics, so every
  paragraph dragged on its own; FEED-11 now stops that for all text.
- **Check:** `test/onboarding_pages_test.dart` "a drag on a paragraph scrolls the whole page", `test/spotlight_article_test.dart` "a drag on a paragraph scrolls the whole article"
- **Code:** `lib/features/spotlight/spotlight_article_page.dart`

### LAYOUT-12 Images of unknown ratio take their shape without a crossfade
- **Rule:** An image whose ratio is unknown until decode holds a square
  placeholder, then takes its own ratio through
  `PixivImage(sizeToImage: true)` inside `SpringSize`, without a
  crossfade. Under a height cap a tall image is drawn narrower and
  centered, with no bars.
- **Why:** A square dissolving over an image of another height read as
  banded loading.
- **Check:** `test/spotlight_article_test.dart` "a tall work is drawn narrower, centered, without bars"
- **Code:** `lib/features/spotlight/spotlight_article_page.dart`

## Semantics

### LAYOUT-13 A work card is one stop
- **Rule:** A work card's label carries rank, title and author; the lines
  under the image are excluded. `PixivImage` keeps decoded pixels out of
  semantics. Icon-only actions have a localized tooltip, and selection is
  never shown by colour or an unlabeled icon alone.
- **Why:** Screen readers read each card two or three times.
- **Check:** manual
- **Code:** `lib/app/widgets/feed/illust_card.dart`

## Edges

### LAYOUT-14 One page, one margin
- **Rule:** A page keeps one horizontal margin for its text, rows and
  cards: 16dp on list, card, settings and artwork detail pages, 8dp
  around the artwork grids of feed pages. The detail page's related works
  grid keeps the page's 16dp. A hint or overlay takes the margin of the
  content under it, and a full-width button lines up with the cards above
  it.
- **Why:** Pages mixed 12, 16 and 24dp, so the blocks of one page did not
  line up and pages of one kind differed. The detail page kept 24dp
  until 10-21; user decision (10-21): an 8dp related grid stood off the
  16dp text and author strip above it on the same page.
- **Check:** manual
- **Code:** `lib/app/theme/func_tokens.dart`

### LAYOUT-15 An inline icon button's glyph sits on the content edge
- **Rule:** At the end of a row, the last icon button's glyph, not its
  48dp target, lines up with the text above and below. In a `ListTile`
  wrap the buttons in `EdgeIconButtons`, which moves them into the tile's
  end padding. A custom row ends its padding
  `EdgeIconButtons.glyphInset` short of the margin instead, so the whole
  target stays inside the row.
- **Why:** A button ended 12dp inside the text edge. Moved past a parent's
  bounds by a transform, the outer part of the target stopped taking taps.
- **Check:** `test/user_profile_test.dart` "profile social links open, report failures, and copy"
- **Code:** `lib/app/widgets/edge_icon_buttons.dart`, `lib/features/profile/user_page.dart`
