---
prefix: SYS
applies_to:
  - lib/app/system_ui.dart
  - lib/features/novel/**
  - lib/features/illust/viewer/**
  - lib/features/profile/profile_header_delegate.dart
reviewed: 2026-10-12
---

# System bars and immersive pages

### SYS-01 system_ui.dart is the only system UI owner
- **Rule:** Only `lib/app/system_ui.dart` mentions `SystemChrome.`,
  `SystemUiOverlayStyle(` or `AnnotatedRegion<SystemUiOverlayStyle>`.
  Other code uses `FuncSystemBars`, `funcSystemBarsStyle` and
  `setSystemUiMode`.
- **Why:** Scattered calls left pages with the wrong bar icons after a
  theme switch or a pop.
- **Check:** `test/architecture/feedback_channels_test.dart` "system UI has exactly one owner"
- **Code:** `lib/app/system_ui.dart`

### SYS-02 Override bar style by wrapping, never by resetting
- **Rule:** A page needing another bar style wraps itself in
  `FuncSystemBars(background:)`; unmounting restores the root style on the
  next frame. A sheet opened over such a page wraps itself too, so a light
  sheet over a dark reader flips the navigation-bar icons while it covers
  them.
- **Why:** Imperative resets missed pop paths and left light icons on a
  light page.
- **Check:** `test/system_ui_test.dart` "a scoped FuncSystemBars overrides the root and restores"
- **Code:** `lib/app/system_ui.dart`

### SYS-03 Immersive pages restore the bars on the successful pop
- **Rule:** A page that hides the system bars enters `immersiveSticky` in
  `initState`, shows `edgeToEdge` while its chrome is shown, and restores
  `edgeToEdge` in `onPopInvokedWithResult` when `didPop` is true, and again
  in `dispose`. Every call is `unawaited` through `setSystemUiMode`, which
  logs a platform failure instead of throwing.
- **Why:** The page below needs its status bar while the pop animation is
  still on screen; `dispose` catches pops that never notify.
- **Check:** `test/system_ui_test.dart` "the viewer hides to immersiveSticky and exits to edgeToEdge"
- **Code:** `lib/app/system_ui.dart`, `lib/features/novel/novel_reader_stage.dart`

### SYS-04 Lay out from stable insets while the bars hide
- **Rule:** A page that hides the system bars does not lay out from live
  `MediaQuery` padding. It keeps each edge's largest with-bars
  `viewPadding` and reseeds only when the screen size changes.
- **Why:** Hidden bars report zero insets; the novel reader repaginated on
  every chrome toggle.
- **Check:** manual — rotating while immersive adjusts the body once on
  the first chrome reveal; the reader's commit gate keeps the anchor.
- **Code:** `lib/features/novel/novel_reader_stage.dart`

### SYS-05 SafeArea goes inside edge-to-edge chrome
- **Rule:** Bars drawn to the screen edge (bottom bar, reader bars, card
  sheet) paint their `Material` through the system inset and put
  `SafeArea` inside it to lift the controls.
- **Why:** An outer `SafeArea` moved the reader chrome's background off the
  edge and left a bare strip.
- **Check:** manual
- **Code:** `lib/app/widgets/func_bottom_nav.dart`, `lib/features/novel/novel_reader_stage.dart`

### SYS-06 Light icons only over real artwork
- **Rule:** The profile header uses light status-bar icons only while a
  cover image sits behind the toolbar; collapsed or without a cover it
  falls back to the root style.
- **Why:** Light icons over a light surface were unreadable.
- **Check:** `test/user_profile_test.dart`
- **Code:** `lib/features/profile/profile_header_delegate.dart`
