---
prefix: MOTION
applies_to:
  - lib/app/motion/**
  - lib/app/widgets/**
  - lib/core/platform/native_warmup.dart
  - lib/core/platform/app_root_pipeline_owner.dart
  - lib/app/navigation/route_animation.dart
  - lib/app/layout/sliver_width_builder.dart
  - lib/app/startup_gate.dart
reviewed: 2026-10-17
---

# Motion, press feedback and the rebuild budget

## Contents

- [Durations and springs](#durations-and-springs)
- [Press and removal](#press-and-removal)
- [Rebuild and semantics budget](#rebuild-and-semantics-budget)

## Durations and springs

### MOTION-01 UI durations come from MotionTokens.resolve
- **Rule:** Every UI animation length is a `MotionTokens` token read
  through `MotionTokens.resolve(context, token)`, which applies the speed
  setting and returns zero under reduced motion (platform
  `disableAnimations`, platform `reduceMotion`, or the in-app setting).
  Code above `MotionScope` uses `resolveWith`. Data timings (debounce,
  throttles) are not tokens. A token names what moves, never a general
  speed: `stateFade` (150 ms, a small element's fade), `chrome` (200 ms,
  bars showing and hiding), `spatial` (300 ms on
  `Cubic(0.3, 0, 0.2, 1)`, a surface moving in place),
  `MotionTokens.scrollToTop` (300 to 500 ms by distance, jumping to a
  screen from the top first when farther), `themeChange`, `sheetExit`,
  and the page, shared-element and component tokens.
- **Why:** Hard-coded durations ignored the speed and reduced-motion
  settings. Two general tokens 20 ms apart ran a page counter fade, a
  zoom and a scroll home alike (user feedback); M3 sizes a duration by
  the area and distance that move, effects shorter than movement.
- **Check:** `test/architecture/motion_census_test.dart` "duration tokens are read through MotionTokens.resolve", `test/architecture/feedback_channels_test.dart` "motion durations live only in MotionTokens (pinned census)", `test/home_branch_stack_test.dart` "a re-tap from"
- **Code:** `lib/app/motion/motion_tokens.dart`

### MOTION-02 Reduced motion removes the flight, not the state
- **Rule:** Under reduced motion the end state still appears, at once.
  Programmatic page turns go through `turnPage(context, controller,
  page)`, which jumps instead of animating. Every new motion has a test
  under `MotionScope(reduce: true)`.
- **Why:** `animateToPage` asserts a non-zero duration; widgets that
  skipped the animation also skipped the state change.
- **Check:** `test/motion_test.dart` "reduced motion and ids off screen complete at once" "reduced motion resizes at once"
- **Code:** `lib/app/motion/motion_tokens.dart`

### MOTION-03 Spatial springs move, effects springs fade
- **Rule:** `MotionSpring` tokens are read only through
  `MotionTokens.spring` (null under reduced motion) or
  `MotionTokens.springCurve` (for duration-and-curve APIs). Spatial
  springs drive position, scale and size; effects springs drive opacity
  and colour. Never swap them. A token is listed only when something uses
  it. Press, size and sheet motion stays on the standard springs, which
  hardly overshoot; the expressive bounce is only for a state the user
  just switched: `SpringPop` kicks the element past its size and back
  (the bookmark heart, the follow button on a follow, every
  `StateIconSwitcher` swap), never on a rebuild, refresh or first build.
- **Why:** Material 3 tunes the two families differently; an effects
  spring on a size change overshot. User decision: the bookmark's pop was
  the one feedback that felt right, and a bounce on every press or
  expand would wobble.
- **Check:** `test/architecture/motion_census_test.dart` "spring tokens are read through MotionTokens.spring", `test/motion_test.dart` "a swap pops the new icon past its size and back"
- **Code:** `lib/app/motion/motion_tokens.dart`, `lib/app/motion/spring_pop.dart`

### MOTION-04 Physical springs snap to their end
- **Rule:** A `SpringSimulation` driving a widget passes
  `snapToEnd: true`.
- **Why:** Without it the value rests inside the tolerance (0.9998) and
  leaves a permanent non-identity transform.
- **Check:** `test/motion_test.dart` "a spring curve starts at 0 and ends exactly at 1"
- **Code:** `lib/app/motion/press_scale.dart`, `lib/app/motion/drag_to_dismiss.dart`

### MOTION-05 Size changes go through SpringSize
- **Rule:** Sections that open and close use `SpringSize`, which returns
  its child as-is under reduced motion.
- **Why:** A zero-duration `AnimatedSize` asserts during its own layout.
- **Check:** `test/motion_test.dart` "opening and closing animate the height" "reduced motion resizes at once"
- **Code:** `lib/app/motion/spring_size.dart`

### MOTION-14 A state change that moves content animates
- **Rule:** A block that a user action shows or hides in place (a note,
  a banner, a status line, a settings group) is a `Reveal`: the space
  opens on `SpringSize` while the block fades in; on the way out the
  block fades, taking no taps, then the space closes. A view that swaps for another of
  the same size (an edit mode) is `StateFade(kind:)` inside `SpringSize`;
  an empty hint that replaces the last row is `StateFade.onMount`. A top
  bar that changes mode (its `backgroundColor`, e.g. `selectionAppBar`)
  cross-fades over `MotionTokens.chrome`; a bar the mode replaces slides
  out with `slideChrome` instead of leaving the tree. Small swaps inside
  a control (icon to spinner), selection tints and results refreshed
  while typing stay instant.
- **Why:** Blocks that appeared at once pushed the content under them
  down in one frame; the user picked these groups from an audit and
  kept the small swaps instant, as M3 and the system apps do.
- **Check:** `test/motion_test.dart` "fades in, and fades out before the block leaves" "reduced motion hides at once"
- **Code:** `lib/app/motion/reveal.dart`, `lib/app/widgets/app_top_bar.dart`

## Press and removal

### MOTION-06 One kind of press feedback per element
- **Rule:** Every tappable element shows a press, and only one kind: a
  ripple where ink fits the visible shape (rows, tiles, menu items,
  buttons, the bottom bar), `PressScale` on cards (0.97) and pills (0.96).
  `TagChip` has no ink because its 48dp target is larger than the pill. A
  disabled element gets no press. Small targets reach 48dp without growing
  the visible shape, and neighbouring targets touch.
- **Why:** Ripple plus scale on one card read as two presses; ink filling
  an invisible margin looked like a misfire.
- **Check:** `test/motion_test.dart` "inside a scrollable a swipe never shows the press" "the press-feedback setting turns the scale off"
- **Code:** `lib/app/motion/press_scale.dart`

### MOTION-07 Feed cards land in place
- **Rule:** Grid content has no entrance animation and no `StateFade`
  around it; only images fade (TRANS-16).
- **Why:** A card entrance stacked on the image fade and replayed on every
  recycled slot.
- **Check:** manual
- **Code:** `lib/app/widgets/feed/feed_grid.dart`

### MOTION-08 Removal plays the exit, then commits
- **Rule:** Lists stay driven by their provider. To delete, read the
  stores and actions you need, `await controller.playExit(ids)` on the
  page's `RemovalController`, then commit; on failure call
  `controller.restore(ids)`. Rows read the controller with
  `RemovalScope.of`. A container that shapes rows by position lays out
  without `controller.leaving` from the exit's first frame.
- **Why:** Committing first rebuilt the list and cut the row out; reads
  after the await hit a disposed widget.
- **Check:** `test/motion_test.dart` "restore brings a row back after a failed commit" "a row disposed mid-exit does not leave the exit hanging"
- **Code:** `lib/app/motion/removal.dart`

### MOTION-09 Grow-in rows are few and marked on insert
- **Rule:** `Removable(animateIn: true)` marks only the rows a user action
  inserted on that frame, with a cap on their number.
- **Why:** A growing row starts at zero height, so a lazy list built every
  marked row at once.
- **Check:** `test/motion_test.dart` "an inserted row grows in and fades from zero"
- **Code:** `lib/app/motion/removal.dart`

## Rebuild and semantics budget

### MOTION-10 Per-card widgets keep narrow dependencies
- **Rule:** Widgets repeated per card or image read `MediaQuery` through
  aspect getters (`sizeOf`, `maybeDisableAnimationsOf`, …), never
  `MediaQuery.of`. They do not depend on `TickerMode.valuesOf`; they mix in
  `TickerModeWatch` and rebuild in `didChangeTickerMode` only when their
  output changes. A widget that only listens to its route's transition
  takes the animation from `RouteAnimationScope.of`, never
  `ModalRoute.of(context)?.animation`.
- **Why:** Dart runs on the Android main thread, and with an accessibility
  service on (the user runs one permanently) every semantics change is
  re-read there. Whole-object dependencies rebuilt every card on each
  inset change or route cover. `ModalRoute.of` rebuilds its caller whenever
  `isCurrent` flips: a leaving detail page and both neighbours rebuilt in
  full in the first frame of every back transition.
- **Check:** `test/motion_test.dart` "does not rebuild on unrelated MediaQuery changes"; `test/func_page_test.dart` "a page reading its route animation is not rebuilt as its route is covered, uncovered or popped"
- **Code:** `lib/app/motion/motion_tokens.dart`, `lib/app/motion/press_scale.dart`, `lib/app/pixiv_image.dart`, `lib/app/navigation/route_animation.dart`

### MOTION-11 Fades keep semantics; progress moves in steps
- **Rule:** Opacity-driven entrances pass `alwaysIncludeSemantics: true`.
  Progress semantics values move in 10% steps while the drawn indicator
  stays continuous.
- **Why:** Content joined the semantics tree only when the fade crossed
  zero; a per-frame progress value re-sent the tree every frame.
- **Check:** `test/image_load_progress_test.dart`
- **Code:** `lib/app/motion/state_fade.dart`, `lib/app/widgets/image_load_progress.dart`

### MOTION-12 Slow first channel calls are warmed up
- **Rule:** A platform channel whose first call blocks the main thread for
  tens of milliseconds is warmed in `androidChannelWarmupSteps`, each step
  waiting for a 300 ms still.
- **Why:** A device trace showed first calls stalling active use; a
  one-second still threshold never fired.
- **Check:** manual
- **Code:** `lib/core/platform/native_warmup.dart`

### MOTION-13 Semantics reach the platform at most every 100 ms
- **Rule:** The root pipeline owner pushes semantics at most once per
  `kSemanticsPushInterval` (100 ms, Android's interval for recurring
  accessibility events). A frame inside the interval skips the flush and a
  timer requests the frame that sends the last change. Route transitions
  and home branch switches hold the push (`holdSemantics`) until an
  interval after the last one ends; a hold gives way after
  `kSemanticsHoldLimit` (2 s). Tests that read semantics right after an
  interaction keep the default test binding; only the throttle's own test
  installs this owner.
- **Why:** Flutter pushed every changed node each frame, and the embedding
  sent two accessibility events per push. With a service on, a scrolling
  feed spent about 2 ms of each frame there and missed about one frame in
  every two seconds of fling; a native client pulls nodes on demand and
  throttles its events. A transition pushed the new page's tree during
  its first frames, up to 11.6 ms of one.
- **Check:** `test/semantics_push_throttle_test.dart`
- **Code:** `lib/core/platform/app_root_pipeline_owner.dart`, `lib/app/motion/page_transitions.dart`, `lib/app/widgets/home_branch_stack.dart`

### MOTION-17 GPU pipelines a first use would compile are warmed at start
- **Rule:** `PipelineWarmup` paints, in the app's first frames, what
  compiles a pipeline on first use: the Hero flight's clipped and
  transformed image, and under an `InkSparkle` theme the ripple shader,
  drawn transparent inside a rounded clip as a ripple draws it. It keeps
  the shader's program for the process, so `InkSparkle` gets the same
  one. The content stays its first child throughout.
- **Why:** The first back flight dropped frames, and the first tap spent
  16 ms of a raster frame compiling the ripple. Unwrapping the content
  when the warm-up ended remounted the app.
- **Check:** `test/startup_gate_test.dart` "the warm-up draws the ripple and keeps the app mounted"
- **Code:** `lib/app/startup_gate.dart`

### MOTION-15 Width-dependent slivers rebuild only on a width change
- **Rule:** A sliver built from its width uses `SliverWidthBuilder`, never
  `SliverLayoutBuilder`. Formatters, spring curves and label widths that
  repeated widgets need in every build are made once and reused
  (`AppFormat`, `MotionTokens.springCurve`, `LabelFit.measureLabel`).
- **Why:** `SliverLayoutBuilder` reruns its builder on every scroll
  offset, so each scroll frame rebuilt every visible row, and with an
  accessibility service on every rebuilt `Semantics` re-sent its node:
  up to 6 ms of each scroll frame on device.
- **Check:** `test/responsive_layout_test.dart` "a width-built sliver rebuilds on a width change, not a scroll"
- **Code:** `lib/app/layout/sliver_width_builder.dart`, `lib/app/format/app_format.dart`, `lib/app/motion/motion_tokens.dart`, `lib/app/widgets/fit_label.dart`

### MOTION-16 Repeated parts of a page get their own ticker notifier
- **Rule:** Feed cards, card rows, and the detail page's image pages and
  sections each sit in a `TickerPartition`. A list of uniform wrappers
  holds no conditional entry.
- **Why:** Every ticker, implicit animation and `TickerModeWatch` on a
  route listened to one notifier, and each removal searched and shifted
  it: 43% of the 7–11 ms unmount frame after closing a detail page. A
  conditional entry among uniform wrappers moves every later child to a
  different wrapper, remounting it.
- **Check:** `test/motion_test.dart` "a ticker partition mutes with its ancestor on its own notifier"
- **Code:** `lib/app/motion/motion_tokens.dart`, `lib/app/widgets/feed/feed_grid.dart`, `lib/app/layout/card_columns.dart`, `lib/features/illust/detail/illust_detail_page.dart`
