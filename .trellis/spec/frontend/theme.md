---
prefix: THEME
applies_to:
  - lib/app/theme/**
  - lib/app/icons/**
  - lib/app/widgets/**
  - lib/app/app.dart
reviewed: 2026-11-21
---

# Theme, color and type

## Contents

- [Sources](#sources)
- [Color](#color)
- [Type and spacing](#type-and-spacing)
- [Chrome over artwork](#chrome-over-artwork)
- [Expression](#expression)

## Sources

### THEME-01 One theme, read from context
- **Rule:** `replicaTheme` builds the sole light and dark `ThemeData` (`NoSplash.splashFactory` with visible `onSurface` highlight/hover/focus layers; tinted pills place their fill on the outer `Material`, not inside `InkWell.child`). Feature code reads `Theme.of(context)` instead of building local palettes. `MaterialUiCompatibilityBridge` and `ForuiThemeHost` (`foruiThemeFrom`, localized for all four shipped locales with `FHapticFeedback.none()`) bridge `ColorScheme`, `FuncSemanticTokens`, `MotionScope`, and platform typography one-way without bundled fonts.
- **Why:** Local palettes broke dark mode and system colors; transparent `highlightColor` under `NoSplash` left controls without press feedback.
- **Check:** `test/replica_theme_test.dart` "replicaTheme provides visible pressed state feedback for InkWell, ListTile, and buttons" "foruiThemeFrom bridges colors, hairlines, haptics, and keeps platform font" "ForuiThemeHost forwards MotionScope reduce to FAccessibilityMotion.disabled"
- **Code:** `lib/app/theme/replica_theme.dart`, `lib/app/theme/forui_theme_bridge.dart`, `lib/l10n/app_localizations_delegates.dart`, `lib/app/app.dart`

### THEME-02 No bundled font
- **Rule:** Never bundle CJK or Latin UI font assets. Android, iOS, and macOS leave `fontFamilyFallback` null to preserve the user's ROM / PingFang / SF Pro platform typography and engine fallback chain; Windows and Linux resolve a locale-aware system CJK fallback chain via `platformFontFamilyFallback` (overridable by the layout test harness). `replicaTheme` copies overridden text roles from `baseTextTheme` to retain platform family/metrics, and `foruiThemeFrom` never falls back to CSS `'system-ui'`.
- **Why:** Preserves mobile ROM fonts and APK size caps while preventing Windows `SimSun` fallback and Linux JP/bitmap CJK mismatches.
- **Check:** `test/architecture/l10n_and_errors_test.dart` "no bundled Montserrat: text uses the platform font"; `test/replica_theme_test.dart` "platformFontFamilyFallback resolves Windows and Linux locale chains without touching mobile or macOS"
- **Code:** `lib/app/theme/replica_theme.dart`, `lib/app/theme/forui_theme_bridge.dart`, `lib/app/app.dart`

### THEME-03 Component text styles derive from the resolved text theme
- **Rule:** AppBar, SnackBar, chip, dialog, and rail text styles derive from `theme.textTheme` in `replicaTheme`'s trailing `copyWith`, never as raw `TextStyle` literals inside `ThemeData(...)`.
- **Why:** Raw `TextStyle` drops letter spacing, line height, and fallback chain.
- **Check:** manual
- **Code:** `lib/app/theme/replica_theme.dart`

## Color

### THEME-04 The accent comes from the color scheme
- **Rule:** Accent painting reads `colorScheme.primary` (text/icons/indicators) or `FuncSemanticTokens.brand` (fills, THEME-18); raw brand constants live only in `func_tokens.dart` and `replica_theme.dart`.
- **Why:** Direct constants bypassed "follow system colors".
- **Check:** `test/architecture/l10n_and_errors_test.dart` "the accent comes from the theme, not the brand constant"
- **Code:** `lib/app/theme/func_tokens.dart`

### THEME-05 System colors drive accents and the full surface ladder
- **Rule:** When supplied, `systemColors` drives both accent roles (`primary*`, `brand`, `onBrand`) and the full M3 surface/container/neutral ladder (`surface*`, `secondary*`, `onSurface*`, `outline*`, `inverse*`, plus `FuncSemanticTokens` canvas/surface/content/divider). Without a system palette, defaults stay on Mika's warm-sakura `FuncTokens`; status colors and the bookmarked heart stay fixed.
- **Why:** User decision: tinting only accent slots left ~90% of clean-canvas viewports unchanged under dynamic color.
- **Check:** `test/replica_theme_test.dart` "a system palette drives accent, surface ladder, and semantic tokens"
- **Code:** `lib/app/theme/system_colors.dart`, `lib/app/theme/replica_theme.dart`, `lib/app/theme/func_semantic_tokens.dart`

### THEME-21 No system palette is a fallback, not an error
- **Rule:** `systemColorSchemesProvider` treats `MissingPluginException` as "no system palette" and returns null so startup keeps working on platforms without `dynamic_color` (e.g. iOS).
- **Why:** Uncaught channel exceptions left the app unthemed at startup.
- **Check:** `test/replica_theme_test.dart` "a platform without a dynamic colour plugin has no system colours"
- **Code:** `lib/app/theme/system_colors.dart`

### THEME-06 Text keeps 4.5:1 on every surface tier
- **Rule:** The six container tiers stay monotonic and distinguishable; `onSurface`/`onSurfaceVariant` keep >= 4.5:1 on every tier in both themes (selected meta text uses `onPrimaryContainer` at 0.8 alpha). Selection and SnackBar text/actions keep >= 4.5:1; light `primary` keeps >= 4.5:1 through `surfaceContainer` (~4.4:1 on high, ~4.1:1 on highest—accepted user decision) and dark keeps >= 4.5:1 everywhere.
- **Why:** Caption gray fell to ~3.9:1 on selected dark rows.
- **Check:** `test/replica_theme_test.dart` "text stays >= 4.5:1 on every surface tier in both themes" "the accent reads at 4.5:1 up to the sheet tier, on dark on all" "selection and the snackbar action read at 4.5:1 in both themes"
- **Code:** `lib/app/theme/func_tokens.dart`, `lib/app/widgets/entity_row.dart`

### THEME-07 Pink is for actions, selection and indicators
- **Rule:** `primary` marks actions, selection, and indicators only (`secondary*` are neutrals; group titles use `onSurfaceVariant`; Settings/Me entries use monochrome `AppIcons` with no color discs, SET-08; tag chips stay neutral except focus rings; disabled controls use M3 disabled alpha even when on). Bookmarked hearts stay `FuncTokens.bookmarked` (#FF4060); count badges use brand fill; irreversible confirms use `DangerFilledButton` (`error`/`onError`).
- **Why:** User decision: decorative accent and rainbow icons diluted action, selection, and danger semantics.
- **Check:** `test/replica_theme_test.dart` "a disabled switch that is on takes no accent" "text on the error fill reads at 4.5:1 in both themes"
- **Code:** `lib/app/theme/replica_theme.dart`, `lib/app/widgets/settings/settings_tile.dart`, `lib/app/widgets/tag_chips.dart`, `lib/app/widgets/danger_filled_button.dart`, `lib/app/widgets/settings/settings_choice_tile.dart`

### THEME-18 The accent is two colors: text and fill, plus canvas top bars
- **Rule:** Default palette splits `colorScheme.primary` (#B44673 light / #EBA6C6 dark) for text/icons/outlines from `FuncSemanticTokens.brand` (#E077A6 under white `onBrand`) for fills (`FilledButton`, follow, solid `ReplicaButton`), with tonal selection containers. `AppTopBar` uses `FuncSemanticTokens.canvas` across all five platforms, revealing `topBarShadow` + 1dp `brandHairline` in `ScrollEdgeShadow` on scroll (while `FuncBottomNav` draws a continuous 1dp top `brandHairline`). `TextButtonThemeData` and `AppTopBar` leading/actions `IconButtonTheme` keep disabled alpha at 0.48 (>= 0.45); `ProgressIndicatorThemeData` uses `primary` / `brandHairline` / `StrokeCap.round`.
- **Why:** Brand pink measured 2.9:1 as light-mode text; unified canvas headers align all five platforms cleanly.
- **Check:** `test/replica_theme_test.dart` "fills are the brand pink under white; selection stays tonal" "header tokens use clean canvas and keep >= 4.5:1 contrast"; `test/shared_widgets_test.dart` "AppTopBar keeps disabled IconButton and TextButton foreground alpha >= 0.45"
- **Code:** `lib/app/theme/replica_theme.dart`, `lib/app/theme/func_tokens.dart`, `lib/app/theme/func_semantic_tokens.dart`, `lib/app/widgets/app_top_bar.dart`, `lib/app/widgets/func_bottom_nav.dart`

### THEME-08 Status color goes on the icon, not the text
- **Rule:** Status rows apply semantic colors (M3 tone 40 light / tone 80 dark; probe keeps fixed literals) to the icon only, leaving status text on `onSurfaceVariant`.
- **Why:** Tinted status text failed 4.5:1 on `surface`.
- **Check:** manual
- **Code:** `lib/features/settings/pages/download_task_presentation.dart`

### THEME-09 A chip on a same-tier surface needs a hairline
- **Rule:** Chips or action pills matching their host surface tier draw a hairline border (`divider` or tinted outline).
- **Why:** Same-value fills vanish in both themes.
- **Check:** manual
- **Code:** `lib/app/widgets/tag_chips.dart`

### THEME-10 Prompts follow inverted light / elevated dark chrome
- **Rule:** Light prompts use `inverseSurface`/`onInverseSurface`/`inversePrimary`; dark prompts use elevated `surfaceContainerHigh` with `onSurface`, `primary`, and an `outlineVariant` border (`FuncShape.card`, THEME-20).
- **Why:** Avoids blinding white slabs in dark mode while keeping clear separation above sheets and cards.
- **Check:** manual
- **Code:** `lib/app/widgets/prompt_host.dart`

## Type and spacing

### THEME-11 One type scale
- **Rule:** Text sizes and weights come from `replicaTheme`'s `textTheme` or derived `FuncSemanticTokens` styles; raw `fontSize:` literals are restricted to deliberately fixed bases (e.g. bottom bar 12sp).
- **Why:** Prevented ad-hoc type scales drifting from the theme.
- **Check:** manual
- **Code:** `lib/app/theme/replica_theme.dart`, `lib/app/theme/func_semantic_tokens.dart`

### THEME-12 Spacing and radii use tokens
- **Rule:** Outside `lib/app/theme/**`, `EdgeInsets`, `Radius.circular`, and `SizedBox` gaps use `FuncSpacing` and `FuncShape` (`badge` 6, `control` 10, `card` 12, `panel` 16, `dialog` 18, `sheet` top-22, `pill` 999); exceptions require a justified file allowlist entry.
- **Why:** Stopped per-page spacing and radius drift.
- **Check:** `test/architecture/ui_conventions_test.dart` "spacing and radius literals use FuncSpacing/FuncShape"
- **Code:** `lib/app/theme/func_semantic_tokens.dart`, `lib/app/theme/func_tokens.dart`

### THEME-13 Text fields share one look
- **Rule:** Text fields use the theme's outlined floating-label decoration without custom `border`; content filters use `SearchBar` on `surfaceContainerHigh`; form saves use a trailing `FilledButton` (SET-09).
- **Why:** Keeps form inputs and filters visually consistent across pages.
- **Check:** manual
- **Code:** `lib/app/theme/replica_theme.dart`

## Chrome over artwork

### THEME-14 Controls over artwork use ArtworkControls
- **Rule:** Icon controls over artwork (detail bar, profile banner, viewer) use `ArtworkControls` (neutral `onSurface` or viewer white with dual-ring surface outline + dual ambient blur, no disc or gradient scrim; `AppTopBar` applies `overArtwork` to both `iconTheme` and `actionsIconTheme`). Pills/counters use `FuncTokens.imageControl`/`onImageControl`; viewer accents use `brand`.
- **Why:** Bare glyphs washed out on white/busy art while discs obscured the artwork.
- **Check:** manual
- **Code:** `lib/app/widgets/artwork_controls.dart`, `lib/app/widgets/app_top_bar.dart`

### THEME-15 Badges over artwork are EntityBadge
- **Rule:** Over-artwork markers use `EntityBadge` on `imageControl` (differentiated by text, never per-badge fill colors). Ranking positions use tabular `EntityRankLabel` (`rankPodium` for 1–3, `rank` otherwise).
- **Why:** Colored badges lost legibility and read as warnings.
- **Check:** manual — visual inspection of EntityBadge and EntityRankLabel over artwork
- **Code:** `lib/app/widgets/entity_row.dart`

### THEME-16 Icons are unified outlined vector glyphs; filled marks selection or state
- **Rule:** All UI icons come from `AppIcons` (`assets/icon.ttf`, built by `tool/build_icons.py`) or `UiIcons` (`FLucideIcons` bridge with RTL mirroring, horizontal `UiIcons.more`, and `UiIcons.dropdown`); no raw `FLucideIcons.*` or Material icon classes appear outside `lib/app/icons/` (`BackButtonIcon` remains platform-supplied). Outlined glyphs denote actions/unselected states; `*Filled` twins mark selected destinations or active states (bookmark, watch-later, mute, download status). One glyph, one meaning (`watchLater`, `heart`, `series`, `watchlistAdd`/`watchlistAdded`, `motion`/`playCircle`, `accountManage`; unmuting is text-only).
- **Why:** Unified optical stroke weight and consistent semantic iconography across all five platforms.
- **Check:** `test/architecture/ui_conventions_test.dart` "a filled icon with an outlined twin marks a state", `test/icon_font_test.dart` "pubspec registers the iconFont family pointing at assets/icon.ttf"
- **Code:** `lib/app/icons/app_icons.dart`, `lib/app/icons/ui_icons.dart`, `tool/build_icons.py`, `lib/app/widgets/card_actions/illust_card_actions.dart`, `lib/app/widgets/watchlist_toggle.dart`

### THEME-17 Every icon button names its action
- **Rule:** Every `IconButton` sets a localized `tooltip` (also serving as its screen-reader label); buttons self-labelled via `Semantics` (like the bookmark heart) are pinned in the scan.
- **Why:** Prevents unlabelled "button" announcements and guesswork.
- **Check:** `test/architecture/ui_conventions_test.dart` "every icon button has a tooltip"
- **Code:** `lib/app/widgets/bookmark_switch_button.dart`

## Expression

### THEME-19 Ambient light is the subject's tone, around it
- **Rule:** `AmbientWash` blurs a small decode once (`BlurredImage`) and applies `AmbientTone` (page lightness + share of image hue) in the page's own paint pass with page-color gradient fades (no per-frame filter/mask over scrolling or swiping content; only the static welcome glow uses a widget blur). Used on the detail short-image band (rising via `MotionTokens.ambientRise` after Hero landing), wide detail stage, cover-less profile header (from avatar), and first-run `ScrollableFormShell.brandGlow`.
- **Why:** User decision: warm subject-matched framing without muddy tints or Impeller offscreen-layer frame drops during swipes.
- **Check:** `test/replica_theme_test.dart` "ambient light keeps the page lightness and a share of the colour" "a wash draws its image toned, in the page pass", `test/illust_detail_page_test.dart` "a short first image sits a band low; Hero and badge keep to it" "the band lights up from the image once it has landed", `test/user_profile_test.dart` "a profile without a cover lights its header from the avatar"
- **Code:** `lib/app/widgets/ambient_wash.dart`, `lib/features/illust/detail/widgets/page_image.dart`, `lib/features/illust/detail/illust_detail_page.dart`, `lib/features/profile/profile_header_delegate.dart`, `lib/app/widgets/scrollable_form_shell.dart`

### THEME-20 A shadow marks a layer, or content under a bar
- **Rule:** Shadows come only from `FuncSemanticTokens` (`barShadow`/`topBarShadow` over scrolling content, `layerLift` on floating capsules, `cardLift` on standalone author cards) or elevation 6 (`colorScheme.shadow`, cocoa ink on light) + 1dp `brandHairline` on menus, dialogs (`AppAlertDialog`), linear bars (`AppProgressBar`), sheets, popovers, and prompts. Feed artwork cards take no shadow or inner border (pure `ClipRRect(FuncShape.card)`, keeping desktop hover/focus rings in `IllustCard`).
- **Why:** User decision: shadows communicate elevation hierarchy rather than decorating cards, while 1dp `brandHairline` separates overlays across light and dark backdrops.
- **Check:** `test/replica_theme_test.dart` "overlays and progress indicators share brandHairline across themes"
- **Code:** `lib/app/theme/func_tokens.dart`, `lib/app/theme/func_semantic_tokens.dart`, `lib/app/theme/replica_theme.dart`, `lib/app/theme/forui_theme_bridge.dart`, `lib/app/widgets/app_dialog.dart`, `lib/app/widgets/app_progress_bar.dart`, `lib/app/motion/app_overlays.dart`, `lib/app/widgets/app_spinner.dart`, `lib/features/illust/detail/widgets/detail_action_bar.dart`
