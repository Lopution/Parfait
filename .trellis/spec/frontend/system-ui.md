---
prefix: SYS
applies_to:
  - lib/app/system_ui.dart
  - lib/features/novel/**
  - lib/features/illust/viewer/**
  - lib/features/profile/profile_header_delegate.dart
reviewed: 2026-10-14
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

### SYS-06 Status-bar icons contrast with the cover under them
- **Rule:** While a profile cover sits behind the toolbar, the status-bar
  icons take the brightness of the cover rows under the status bar at the
  current scroll offset, read from a 64px-wide decode of the cover
  (`BannerSample`, split at the equal-contrast luminance). Before that
  decode lands, if it fails, once collapsed and without a cover they follow
  the page. The header keeps one tree shape in every case.
- **Why:** Light icons over a light surface were unreadable, and fixed
  light icons were unreadable over a white cover.
- **Check:** `test/banner_sample_test.dart`
- **Code:** `lib/features/profile/profile_header_delegate.dart`, `lib/features/profile/banner_sample.dart`

### SYS-07 Pages out of sight keep the insets they last saw
- **Rule:** Every page route wraps its page in `FrozenWhileHidden`: while
  its `TickerMode` is off (covered by an opaque route, in a hidden
  branch, or the branch a switch leaves), the page keeps the
  `MediaQueryData` and `HomeShellChrome` it last saw, and takes the
  current ones in the build of the frame it shows again. The covered
  shell bar keeps its last widget and media the same way. Skeleton text
  bones look their line height up by style, scaler and direction.
- **Why:** Covered and hidden subtrees stay attached and still build and
  lay out. Each reader bar toggle and each keyboard frame rebuilt the
  scaffolds under the top page and measured 64 skeleton lines in the
  hidden branches (9–15 ms toggle frames on device).
- **Check:** `test/func_page_test.dart` "the media and shell chrome it saw until it shows again", `test/shared_widgets_test.dart` "a text bone is as tall as a line of its style"
- **Code:** `lib/app/navigation/frozen_while_hidden.dart`, `lib/app/navigation/func_page.dart`, `lib/app/widgets/func_bottom_nav.dart`, `lib/app/widgets/skeleton/func_skeleton.dart`
