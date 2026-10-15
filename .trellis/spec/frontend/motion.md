---
prefix: MOTION
applies_to:
  - lib/app/motion/**
  - lib/app/widgets/**
  - lib/core/platform/native_warmup.dart
  - lib/core/platform/app_root_pipeline_owner.dart
  - lib/app/navigation/route_animation.dart
reviewed: 2026-10-12
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
  throttles) are not tokens.
- **Why:** Hard-coded durations ignored the speed and reduced-motion
  settings.
- **Check:** `test/architecture/motion_census_test.dart` "duration tokens are read through MotionTokens.resolve", `test/architecture/feedback_channels_test.dart` "motion durations live only in MotionTokens (pinned census)"
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
  it.
- **Why:** Material 3 tunes the two families differently; an effects
  spring on a size change overshot.
- **Check:** `test/architecture/motion_census_test.dart` "spring tokens are read through MotionTokens.spring"
- **Code:** `lib/app/motion/motion_tokens.dart`

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
  timer requests the frame that sends the last change. Tests that read
  semantics right after an interaction keep the default test binding; only
  the throttle's own test installs this owner.
- **Why:** Flutter pushed every changed node each frame, and the embedding
  sent two accessibility events per push. With a service on, a scrolling
  feed spent about 2 ms of each frame there and missed about one frame in
  every two seconds of fling; a native client pulls nodes on demand and
  throttles its events.
- **Check:** `test/semantics_push_throttle_test.dart`
- **Code:** `lib/core/platform/app_root_pipeline_owner.dart`
