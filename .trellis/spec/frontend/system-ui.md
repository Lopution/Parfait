---
prefix: SYS
applies_to:
  - lib/app/system_ui.dart
  - lib/app/widgets/app_top_bar.dart
  - lib/features/novel/**
  - lib/features/illust/viewer/**
  - lib/features/profile/profile_header_delegate.dart
reviewed: 2026-11-28
---

# System bars and immersive pages

### SYS-01 system_ui.dart is the only system UI owner
- **Rule:** Only `lib/app/system_ui.dart` mentions `SystemChrome.`,
  `SystemUiOverlayStyle(` or `AnnotatedRegion<SystemUiOverlayStyle>`.
  Other code uses `FuncSystemBars`, `funcSystemBarsStyle` and
  `setSystemUiMode`.
- **Why:** Scattered calls left pages with the wrong bar icons after a
  theme switch or a pop.
- **Check:** `test/architecture/ui_conventions_test.dart` "system UI has exactly one owner"
- **Code:** `lib/app/system_ui.dart`

### SYS-03 Immersive pages restore the bars on pop and when covered
- **Rule:** A page that hides the system bars enters `immersiveSticky` in
  `initState`, shows `edgeToEdge` while its chrome is shown, subscribes to
  `RouteObserverScope` (`RouteAware`) so pushing a covering route restores
  `edgeToEdge` (`didPushNext`) and returning re-applies `immersiveSticky` when
  chrome is still hidden (`didPopNext` and after covering route transition
  dismissal), and restores `edgeToEdge` in `onPopInvokedWithResult` when
  `didPop` is true and again in `dispose`. Every call is `unawaited` through
  `setSystemUiMode`, which logs a platform failure instead of throwing.
- **Why:** Covered pages (such as `[[jumpuri]]` destinations) must never inherit
  hidden bars, returning from an immersive illustration viewer must restore the
  reader's hidden bars after the viewer disposes, and the page below needs its
  status bar while the pop animation is on screen.
- **Check:** `test/system_ui_test.dart` "the viewer hides to immersiveSticky and exits to edgeToEdge" "novel reader restores edgeToEdge when covered and re-enters immersiveSticky on pop"
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

### SYS-06 Status-bar icons contrast with the cover under them
- **Rule:** While a profile cover sits behind the toolbar, the status-bar
  icons take the brightness of the cover rows under the status bar at the
  current scroll offset, read from a 64px-wide decode of the cover
  (`BannerSample`, split at the equal-contrast luminance). Before that
  decode lands, if it fails, once collapsed and without a cover they follow
  the page. The header keeps one tree shape in every case.
- **Why:** Light icons over a light surface were unreadable, and fixed
  light icons were unreadable over a white cover.
- **Check:** `test/banner_sample_test.dart` "the status bar takes the brightness of the cover rows under it"
- **Code:** `lib/features/profile/profile_header_delegate.dart`, `lib/features/profile/banner_sample.dart`
