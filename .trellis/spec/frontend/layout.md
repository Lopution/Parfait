---
prefix: LAYOUT
applies_to:
  - lib/app/widgets/**
  - lib/app/format/**
  - lib/features/**
  - lib/l10n/**
reviewed: 2026-11-28
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
- **Check:** `test/locale_layout/harness_test.dart` "catches UI text cut, squeezed, overflowing or shrunk" "lets a FitLabel ellipsize in the compact profile only"
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
- **Check:** manual — code review on ARB and copy strings (labelValue, errorWithReason)
- **Code:** `lib/l10n`

### LAYOUT-04 Measure text with the style it paints with
- **Rule:** A widget that measures its own text measures with the exact
  style and text scaler it paints with: the style a `Text` resolves,
  including the system's bold text and spacing overrides
  (`LabelFit.paintedStyle`), and the locale it paints in
  (`Localizations.maybeLocaleOf`). `FitLabel` never measures; its host
  computes the fit from the slot it lays out.
- **Why:** Measured and painted widths disagreed under non-linear text
  scalers, so labels ellipsized that should have fit. The novel reader
  measured its pages unscaled and painted them at the system size, so
  large text cut the tail off every line. A tab slot sized to the
  measured label faded its last glyph under the system's letter spacing.
  The reader measured without the ambient style it painted in (the
  theme's font fallbacks, the letter spacing and even leading of the
  dense CJK type): full lines ran wider than measured, short mixed-script
  lines taller.
- **Check:** `test/architecture/l10n_and_errors_test.dart` "fitted labels are measured in the style and locale they paint in"; `test/novel_reader_test.dart` "large system text is laid out as wide as it paints"
- **Code:** `lib/app/widgets/fit_label.dart`, `lib/app/widgets/func_bottom_nav.dart`, `lib/app/widgets/app_tab_bar.dart`, `lib/app/widgets/follow_switch_button.dart`, `lib/features/search/search_filter_sheet.dart`, `lib/features/novel/novel_layout.dart`

### LAYOUT-05 The selection bar title is the bare count
- **Rule:** Lists in selection mode use `selectionAppBar`; its title is
  the number alone, with `selectedCount(n)` as the semantics label.
- **Why:** Next to three actions a sentence did not fit 320dp at large
  text, and an ellipsis cut the number off the Russian copy.
- **Check:** `test/locale_layout/lists_layout_test.dart` "lists: download tasks" "lists: history"
- **Code:** `lib/app/widgets/selection_app_bar.dart`

### LAYOUT-06 Dates and numbers go through AppFormat
- **Rule:** User-facing dates use `AppFormat.date`/`relative`, counts
  `AppFormat.count`, decimals `AppFormat.decimal`; a number that changes
  in place also takes `.tabular`. Data formats (route query dates, file names) stay out and
  are allow-listed with a reason in the architecture test.
- **Why:** Hand-formatted dates and `'${n}k'` ignored the locale
  (zh 1.2万, en 12K); changing digits shifted their neighbours.
- **Check:** `test/architecture/l10n_and_errors_test.dart` "user-facing dates go through AppFormat" "counts go through AppFormat", `test/app_format_test.dart` "decimal keeps one digit in the locale separator"
- **Code:** `lib/app/format`

### LAYOUT-16 Framework strings ship in the app's languages only
- **Rule:** `MaterialApp` takes `appLocalizationsDelegates`, whose
  Material, Cupertino and Widgets delegates name the zh, en, ja and ru
  translation classes. A new supported language adds its classes there;
  `Global*Localizations.delegate` stays out of `lib/`.
- **Why:** Flutter's delegates switch over every language it ships, so
  all ~80 translations were compiled in: 0.1 MB of the APK.
- **Check:** `test/app_localizations_delegates_test.dart` "the app's locales match Flutter's own delegates"
- **Code:** `lib/l10n/app_localizations_delegates.dart`

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
- **Check:** `test/locale_layout/harness_test.dart` "Latin measures in Roboto" "accepts whole UI text, ellipsized user content and a floating label shrunk by the spec"
- **Code:** `test/helpers/locale_layout.dart`

### LAYOUT-17 Every page opens whole in each state it can show
- **Rule:** Every page of the router has an entry in `smokePages`. The
  matrix opens the whole app at the page in zh-CN: loaded (then back to
  its parent), compact, empty for a page that shows a list, and failed
  for a page that reads the App API, which it must have sent. Each state
  must raise no exception, keep UI text whole, stay at its location and
  come to rest: a page still moving is still loading. It must show
  content past the app's bars (a text or an image outside the top bar,
  the tabs and the navigation; a web view page, its view), or a message
  that there is none or why. A page that stays
  silent by design when its read fails (a best-effort merge,
  suggestions) leaves out `reads`, with a comment saying why.
- **Why:** Page cases build one page over its own fakes. Nothing opened
  every route through the app's shell, router and stores, and the first
  run found a restored image viewer that said it had no images forever.
  A page that drew nothing at all still passed as loaded.
- **Check:** `test/locale_layout/routes_smoke_test.dart` "every page of the router has a smoke entry"
- **Code:** `test/helpers/route_smoke.dart`

## Boxes, headers and keyboards

### LAYOUT-11 Long documents use one SelectionArea
- **Rule:** A long document page wraps its one list in a single
  `SelectionArea` and renders paragraphs as plain `Text`, never
  `SelectableText` per paragraph; `TranslationPanel` checks
  `SelectionContainer.maybeOf(context)` and emits plain `Text` inside an
  outer `SelectionArea` (falling back to `SelectableText` only standalone).
  `CaptionRichText` intentionally keeps inline `TextSpan` link recognizers
  (rather than `WidgetSpan` buttons) so caption links wrap naturally across
  lines and participate cleanly in `SelectionArea` selection without oversized
  atomic boxes (accepting that inline caption links are activated by pointer
  or touch rather than Tab focus).
- **Why:** Selection cannot span `SelectableText` paragraphs. Each also
  owns a scrollable that inherited the bouncing physics, so every
  paragraph dragged on its own; nesting `SelectableText` inside `SelectionArea` broke continuous drag
  selection.
- **Check:** `test/illust_detail_page_test.dart` "two-pane panorama preserves 280dp height, tag block mode shows Done & intercepts back, single tag mute confirms silently on right-click, and TranslationPanel avoids nested SelectableText"
- **Code:** `lib/features/spotlight/spotlight_article_page.dart`, `lib/app/widgets/inline_translation.dart`, `lib/app/widgets/caption_rich_text.dart`, `lib/features/profile/profile_about_tab.dart`, `lib/features/novel/novel_page.dart`, `lib/app/widgets/tag_actions_sheet.dart`

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

### LAYOUT-15 An inline icon button's glyph sits on the content edge
- **Rule:** At the end of a row, the last icon button's glyph, not its
  48dp target, lines up with the text above and below. In a `ListTile`
  wrap the buttons in `EdgeIconButtons`, which moves them into the tile's
  end padding. A custom row ends its padding
  `EdgeIconButtons.glyphInset` short of the margin instead, so the whole
  target stays inside the row. A text button that starts a line under
  start-aligned content takes `startEdgeTextButtonStyle()`: its label or
  icon on the content edge, its target reaching inward.
- **Why:** A button ended 12dp inside the text edge. Moved past a parent's
  bounds by a transform, the outer part of the target stopped taking taps.
  The series pages' and the novel info sheet's text buttons started 12dp
  inside it.
- **Check:** `test/user_profile_test.dart` "profile social links open, report failures, and copy"; `test/novel_series_test.dart` "a series page: its facts, numbered novels past the first page, a restricted one, and reading on from where you left"
- **Code:** `lib/app/widgets/edge_icon_buttons.dart`, `lib/features/profile/user_page.dart`, `lib/features/profile/profile_about_tab.dart`, `lib/features/novel/novel_series_page.dart`, `lib/features/series/illust_series_page.dart`, `lib/features/novel/novel_page.dart`
