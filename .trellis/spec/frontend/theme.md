---
prefix: THEME
applies_to:
  - lib/app/theme/**
  - lib/app/widgets/**
  - lib/app/app.dart
reviewed: 2026-10-21
---

# Theme, color and type

## Contents

- [Sources](#sources)
- [Color](#color)
- [Type and spacing](#type-and-spacing)
- [Chrome over artwork](#chrome-over-artwork)

## Sources

### THEME-01 One theme, read from context
- **Rule:** `replicaTheme` builds the only light and dark `ThemeData`.
  Feature code reads colors, text styles and component defaults from
  `Theme.of(context)`; it never builds a second palette or copies a
  component theme locally. `MaterialUiCompatibilityBridge` is installed
  once in the app builder.
- **Why:** Local palettes drifted from the theme and broke dark mode and
  system colors.
- **Check:** manual
- **Code:** `lib/app/theme/replica_theme.dart`, `lib/app/app.dart`

### THEME-02 No bundled font
- **Rule:** Text renders in the platform font with the engine's fallback
  chain. `fontFamilyFallback` exists only for the layout test harness.
- **Why:** The user's ROM font is part of the system look; a bundled family
  overrides it.
- **Check:** `test/architecture/format_and_font_test.dart` "no bundled Montserrat: text uses the platform font"
- **Code:** `lib/app/theme/replica_theme.dart`

### THEME-03 Component text styles derive from the resolved text theme
- **Rule:** AppBar, SnackBar, chip, dialog and rail text styles are set in
  the trailing `copyWith` of `replicaTheme` from the resolved
  `theme.textTheme`, never as a raw `TextStyle` inside `ThemeData(...)`.
- **Why:** Those components install the style wholesale; a raw style drops
  the text theme's letter spacing, line height and fallback chain.
- **Check:** manual
- **Code:** `lib/app/theme/replica_theme.dart`

## Color

### THEME-04 The accent comes from the color scheme
- **Rule:** Everything that paints the accent reads
  `colorScheme.primary` (text, icons, indicators) or
  `FuncSemanticTokens.brand` (fills, THEME-18). `FuncTokens.primary` and
  `FuncTokens.lightAccent` appear only in `func_tokens.dart` and
  `replica_theme.dart`.
- **Why:** With "follow system colors" on, the accent is the system palette;
  the constant would keep painting the brand pink.
- **Check:** `test/architecture/format_and_font_test.dart` "the accent comes from the theme, not the brand constant"
- **Code:** `lib/app/theme/func_tokens.dart`

### THEME-05 System colors replace only the accent roles
- **Rule:** A system palette supplies `primary`, `onPrimary`,
  `primaryContainer`, `onPrimaryContainer`, `inversePrimary` and
  `surfaceTint`; `brand` / `onBrand` become its `primary` / `onPrimary`.
  Neutrals and the surface ladder stay on `FuncTokens`: the app's own
  neutrals, warm grays that carry the brand hue at a very low chroma.
  Status colors and the bookmarked heart stay fixed too.
- **Why:** The surface ladder and text contrast are tuned and tested on the
  app's own neutrals; a wallpaper palette would break them. User decision:
  the cold grays read as foreign next to the pink.
- **Check:** `test/replica_theme_test.dart` "a system palette replaces only the accent roles"
- **Code:** `lib/app/theme/system_colors.dart`, `lib/app/theme/replica_theme.dart`

### THEME-06 Text keeps 4.5:1 on every surface tier
- **Rule:** The six container tiers stay monotonic and distinguishable, and
  `onSurface` / `onSurfaceVariant` keep at least 4.5:1 on each tier in both
  themes. Meta text on a selected row uses `onPrimaryContainer` at alpha
  0.8, not the caption gray. The light theme's text accent (`primary`,
  THEME-18) keeps 4.5:1 on the page and up to `surfaceContainer` (sheets);
  on `surfaceContainerHigh` (dialogs) it measures about 4.3:1 and on the
  highest tier about 4.1:1.
- **Why:** The caption gray measured about 3.9:1 on a selected dark row.
  User decision: a deeper accent that clears every tier read darker than
  the rose chosen, so dialogs and the highest tier are a known shortfall.
- **Check:** `test/replica_theme_test.dart` "text stays >= 4.5:1 on every surface tier in both themes", "the light accent reads at 4.5:1 up to the sheet tier"
- **Code:** `lib/app/theme/func_tokens.dart`, `lib/app/widgets/entity_row.dart`

### THEME-07 Pink is for actions, selection and indicators
- **Rule:** `primary` marks primary actions, selected states and
  indicators only. `secondary` and `secondaryContainer` are neutral grays:
  tonal buttons and progress tracks are not pink. Group titles use
  `onSurfaceVariant`, never `primary`. Selected controls use
  `primaryContainer` / `onPrimaryContainer`. Category tones
  (`categoryTone`) are not the accent: they color only the icon circles
  of top-level entries, by the kind of place each opens, and stay fixed
  under system colors; bookmarks keeps the default accent's hue. Tag
  chips are neutral pills; only keyboard focus rings them in the accent.
  A disabled control takes M3's disabled colors (`onSurface` at 0.38 for
  content, 0.12 for containers), never the accent, even when it is on.
  A bookmarked heart and its burst are `FuncTokens.bookmarked` (#FF4060)
  in both themes and under system colors: a state, not the accent.
- **Why:** User decision: the accent loses its meaning when it decorates.
  A system accent that recolored bookmarks collided with whichever
  category shared its hue. A locked switch drawn in the accent read as
  tappable.
- **Check:** `test/replica_theme_test.dart` "a disabled switch that is on takes no accent"
- **Code:** `lib/app/theme/replica_theme.dart`, `lib/app/theme/category_colors.dart`, `lib/app/widgets/tag_chips.dart`

### THEME-18 The accent is two colors: text and fill
- **Rule:** With the default palette, `colorScheme.primary` paints text,
  small icons, indicators and outlines: #D61C59 on the light theme,
  #FF6289 on the dark. `FuncSemanticTokens.brand` (#FF6289 in both) under
  `onBrand` (white) paints fills: `FilledButton` through
  `filledButtonTheme`, the follow button, the solid `ReplicaButton`.
  `primaryContainer` stays M3's pale container under dark text, for
  selection; it is never the fill. A system palette paints both from its
  `primary`.
- **Why:** The brand pink measured about 2.9:1 as text on the light page.
  User decision: fills keep the brand pink with white text
  (2.85:1, accepted); M3's own deeper tones read as berry red, and a pink
  container under dark text was rejected.
- **Check:** `test/replica_theme_test.dart` "fills are the brand pink under white; selection stays tonal"
- **Code:** `lib/app/theme/replica_theme.dart`, `lib/app/theme/func_tokens.dart`

### THEME-08 Status color goes on the icon, not the text
- **Rule:** In status rows the icon carries the semantic color (success,
  warning, danger); the status text stays `onSurfaceVariant`. The status
  tones are M3's tone 40 on the light theme and tone 80 on the dark; the
  network probe keeps its own fixed literals.
- **Why:** Tinted status text measured below 4.5:1 on `surface`.
- **Check:** manual
- **Code:** `lib/features/settings/pages/download_task_presentation.dart`

### THEME-09 A chip on a same-tier surface needs a hairline
- **Rule:** A chip or action pill whose fill equals the surface it sits on
  draws a hairline border (`divider` token or a tinted outline).
- **Why:** Same-value fills disappear in both themes.
- **Check:** manual
- **Code:** `lib/app/widgets/tag_chips.dart`

### THEME-10 Prompts are inverted chrome
- **Rule:** Prompts use `inverseSurface` / `onInverseSurface` with
  `inversePrimary` actions. Do not restyle them to a container tier.
- **Why:** A container-tier prompt blends into sheets and cards.
- **Check:** manual
- **Code:** `lib/app/widgets/prompt_host.dart`

## Type and spacing

### THEME-11 One type scale
- **Rule:** Text sizes and weights come from the `textTheme` roles set in
  `replicaTheme`, or from a `FuncSemanticTokens` style derived from them.
  A `fontSize:` literal is allowed only for a deliberately fixed size
  (the bottom bar's 12sp label base).
- **Why:** Local sizes formed a second ramp that did not follow the theme.
- **Check:** manual
- **Code:** `lib/app/theme/replica_theme.dart`, `lib/app/theme/func_semantic_tokens.dart`

### THEME-12 Spacing and radii use tokens
- **Rule:** In `lib/app/**` and `lib/features/**` (outside
  `lib/app/theme/**`), numeric `EdgeInsets` and `Radius.circular` values,
  and `SizedBox` gaps between children, use `FuncSpacing` and `FuncShape`.
  Pick the nearest token (6 → `sm`, 10 → `md` for card text indent else
  `sm`, 20 → `xl` for page margins else `lg`, 28 → `xxl`). Exceptions are
  allow-listed per file with a reason and a count.
- **Why:** Hand-picked values drifted page by page.
- **Check:** `test/architecture/spacing_tokens_test.dart`
- **Code:** `lib/app/theme/func_tokens.dart`

### THEME-13 Text fields share one look
- **Rule:** Text fields use the theme's outlined decoration with a
  floating label; call sites do not set `border`. A filter over loaded
  content is a `SearchBar`; the theme's `SearchBarThemeData` makes it flat
  on `surfaceContainerHigh`, and call sites set only its size. A form's
  save is a `FilledButton` at the end of its card (SET-09).
- **Why:** Pages each styled their fields, search bars and save buttons
  differently.
- **Check:** manual
- **Code:** `lib/app/theme/replica_theme.dart`

## Chrome over artwork

### THEME-14 Controls over artwork use ArtworkControls
- **Rule:** Icon controls over artwork (detail top bar, profile banner,
  viewer) use `ArtworkControls`: neutral `onSurface` glyphs (white on the
  viewer) with a surface-colored 1dp outline traced around each glyph,
  over one soft blur. No disc under a control and no gradient scrim over
  the artwork. Pills and counters keep the `FuncTokens.imageControl` /
  `onImageControl` pair. An accent on the always-black viewer stage is
  `brand`, not the light theme's deeper text accent.
- **Why:** A plain glyph washes out on a white artwork; discs and scrims
  were rejected as covering the work. A blurred halo alone stayed a faint
  glow: the glyph vanished on a mid-tone banner of a near hue. An accent
  glyph on every work made the accent decoration (THEME-07).
- **Check:** manual
- **Code:** `lib/app/widgets/artwork_controls.dart`

### THEME-15 Badges over artwork are EntityBadge
- **Rule:** Every marker painted over artwork is an `EntityBadge` on the
  `imageControl` scrim. No badge picks its own color: R-18 and AI differ
  by text, not fill. A ranking position is a title-line label
  (`EntityRankLabel`), not a badge.
- **Why:** Colored badges were illegible on some artworks and read as
  warnings.
- **Check:** `test/illust_card_badges_test.dart`
- **Code:** `lib/app/widgets/entity_row.dart`

### THEME-16 Icons are outlined; filled marks a state
- **Rule:** An action, a destination or a placeholder uses the outlined
  icon. The filled twin only marks a state: a toggle that is on (a
  muted work or author, a work in watch-later) or a status (a download
  task's). One glyph, one meaning: the bookmark is watch-later, the heart
  is a pixiv bookmark, `collections_bookmark` is a series, the library
  stack is following series (`library_books`, toggled with `library_add`
  / `library_add_check`), the circled minus removes from a list,
  `manage_accounts` opens account management. Unmuting is a text
  button: no icon says it.
- **Why:** The same action showed filled on one page and outlined on the
  next; one bookmark glyph meant two features, and an eye read as "view".
- **Check:** `test/architecture/icon_style_test.dart` "a filled icon with an outlined twin marks a state"
- **Code:** `lib/app/widgets/card_actions/illust_card_actions.dart`, `lib/app/widgets/watchlist_toggle.dart`

### THEME-17 Every icon button names its action
- **Rule:** Every `IconButton` has a localized tooltip saying what it
  does, which is also its screen-reader label. A button that labels
  itself through `Semantics` (the bookmark heart, whose long press opens
  the tag picker) is pinned in the check.
- **Why:** An icon alone is a guess, and a screen reader read "button".
- **Check:** `test/architecture/icon_style_test.dart` "every icon button has a tooltip"
- **Code:** `lib/app/widgets/bookmark_switch_button.dart`
