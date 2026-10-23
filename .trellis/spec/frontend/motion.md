---
prefix: MOTION
applies_to:
  - lib/app/motion/**
  - lib/app/widgets/**
  - lib/core/platform/native_warmup.dart
  - lib/core/platform/app_root_pipeline_owner.dart
  - lib/core/platform/touch_resampler.dart
  - lib/core/platform/raster_affinity.dart
  - lib/app/navigation/route_animation.dart
  - lib/app/layout/sliver_width_builder.dart
  - lib/app/startup_gate.dart
reviewed: 2026-10-19
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
  `pageTransition` (500 ms, the page slide), and the shared-element and
  component tokens.
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
  an empty hint that replaces the last row is `StateFade.onMount`. A
  `StateFade` paints the new state at alpha 1/255 in the frame it enters
  and starts the fade after that frame, so a long first frame never
  skips the fade's start. A top
  bar that changes mode (its `backgroundColor`, e.g. `selectionAppBar`)
  cross-fades over `MotionTokens.chrome`; a bar the mode replaces slides
  out with `slideChrome` instead of leaving the tree. Small swaps inside
  a control (icon to spinner), selection tints and results refreshed
  while typing stay instant.
- **Why:** Blocks that appeared at once pushed the content under them
  down in one frame; the user picked these groups from an audit and
  kept the small swaps instant, as M3 and the system apps do. A fade
  started inside the content's first frame (15–52 ms) jumped halfway on
  the next frame, the first one that painted the content.
- **Check:** `test/motion_test.dart` "fades in, and fades out before the block leaves" "reduced motion hides at once" "a new state paints in its first frame and fades after it"
- **Code:** `lib/app/motion/reveal.dart`, `lib/app/motion/state_fade.dart`, `lib/app/widgets/app_top_bar.dart`

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

### MOTION-18 Drags take the device's slop; sideways pagers double it
- **Rule:** A hand-built drag recognizer takes
  `MediaQuery.maybeGestureSettingsOf(context)`, and a slop check uses
  `computeHitSlop` with the settings its competing scrollable reads; never
  `kTouchSlop`. A sideways pager (detail pages, viewer pages, tab swipe)
  accepts only past `pagingSlopFactor` times the device slop, as Android's
  ViewPager does: `PagingSlop` wraps the `PageView`, `PagingSlopPage`
  gives each page the device slop back. A page whose pan accepts at twice
  the slop (`InteractiveViewer`) keeps the paging slop while the pager can
  page. A recognizer given the paging slop keeps the device slop as its
  `minFlingDistance`.
- **Why:** Android's slop is 8dp, `kTouchSlop` 18: pull-to-dismiss and a
  panorama lost to the pager, a card stayed pressed while its list
  scrolled. With equal slops a swipe up to 45° off horizontal turned the
  page instead of scrolling the detail. Restored, the viewer image's pan
  tied with the pager and the inner one won.
- **Check:** `test/motion_test.dart` "a scroll takeover releases the pressed scale", `test/illust_detail_pager_test.dart` "scrolls the detail" "a panorama scrolls first and hands the swipe on at its edge", `test/tab_swipe_switcher_test.dart` "leaves the tabs", `test/hero_transition_test.dart` "only the entry page flies back"
- **Code:** `lib/app/scroll_behavior.dart`, `lib/app/motion/drag_to_dismiss.dart`, `lib/app/motion/press_scale.dart`, `lib/app/widgets/tab_swipe_switcher.dart`

### MOTION-20 A released swipe lands from the finger's speed
- **Rule:** A sideways swipe released between tabs or pages lands on a
  spring that starts at the release velocity. `TabSwipeSwitcher` carries
  both the switch and the spring-back on `MotionSpring.spatialDefault`,
  picks the next tab in the release's direction from where the tabs are
  (as ViewPager does), and changes the index once, on landing. A
  `PageView` the user swipes takes `PageSnapPhysics`, which swaps only the
  page snap's spring (about 300 ms to the end of the scroll); the
  overscroll bounce keeps the list physics' spring.
- **Why:** The tab switch ran a fixed 300 ms ease and the spring-back
  started at rest, so a fast fling slowed down on release and a
  spring-back stalled before turning. The framework's page spring ended
  the scroll after about 0.7 s, and the detail pager builds a page's
  content and its neighbours only then.
- **Check:** `test/tab_swipe_switcher_test.dart` "from the finger's speed", `test/scroll_behavior_test.dart` "ends its page snap in about 300 ms"
- **Code:** `lib/app/widgets/tab_swipe_switcher.dart`, `lib/app/scroll_behavior.dart`, `lib/features/illust/detail/illust_detail_pager_page.dart`, `lib/features/illust/viewer/image_viewer_page.dart`

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
  timer requests the frame that sends the last change. Route transitions,
  home branch switches and scrolls hold the push (`holdSemantics`); every
  app scroll behavior wraps its overscroll indicator in
  `ScrollSemanticsHold`, whose hold follows the scroll position (released
  when it stops scrolling, is replaced by a stopped one, or unmounts).
  After the last hold the push waits an interval, then for a frame after
  which no animation is ticking. `kSemanticsHoldLimit` (2 s), counted from
  the first hold to the push, bounds both waits. Tests that read semantics
  right after an interaction keep the default test binding; only the
  throttle's own test installs this owner.
- **Why:** Flutter pushed every changed node each frame, and the embedding
  sent two accessibility events per push. With a service on, a scrolling
  feed spent about 2 ms of each frame there and missed about one frame in
  every two seconds of fling; a native client pulls nodes on demand and
  throttles its events. A transition pushed the new page's tree during
  its first frames, up to 11.6 ms of one. Even throttled, a fling pushed
  every ~108 ms at 7.5–11 ms each, and a push 100 ms after a transition
  landed inside image and content fades (device traces; user decision:
  no pushes while scrolling or animating, at most 2 s late).
- **Check:** `test/semantics_push_throttle_test.dart`
- **Code:** `lib/core/platform/app_root_pipeline_owner.dart`, `lib/app/scroll_behavior.dart`, `lib/app/motion/page_transitions.dart`, `lib/app/widgets/home_branch_stack.dart`

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

### MOTION-22 Raster threads run on every core of a chip without little cores
- **Rule:** At launch on Android, `freeRasterThreads` sets every
  `*.raster` thread to all cores when no core's `cpu_capacity` is under
  half of the fastest. With a little core, or with no or equal readings,
  it keeps the engine's set: it only ever widens it.
- **Why:** The engine pins the raster thread to the cores with more than
  the lowest top frequency. On the Snapdragon 8 Elite family (two prime
  and six performance cores) that left the two prime cores, idling at
  883 MHz; freed, raster frames took a sixth less time. Excluding every
  core under half would narrow the engine's set on a chip with two tiers
  above its little cores.
- **Check:** `test/raster_affinity_test.dart` "frees every core only when none is little" "sets only the raster threads, from a full capacity table"
- **Code:** `lib/core/platform/raster_affinity.dart`, `lib/main.dart`

### MOTION-19 Touch moves reach the app once per frame, resampled
- **Rule:** `_ParfaitBinding` hands every pointer event to
  `TouchResampler`: a finger's moves go out at the start of each frame,
  real samples up to 10 ms before its vsync and one move interpolated to
  that time when a later sample is in, also on a frame that took no new
  sample. The vsync is `handleBeginFrame`'s stamp minus one refresh
  period: the engine stamps a frame with its vsync target
  (`GetVsyncTargetTime()`). It never predicts past the newest sample.
  Every other event goes out at once, after the queued moves. An
  interpolated move is `synthesized`, and code that measures a finger's
  speed skips synthesized moves as recognizers do.
- **Why:** Flutter's embedding dispatches each touch as it arrives and a
  frame takes the newest, so per-frame movement went uneven while every
  frame was on time. Android also predicts up to 8 ms, but Flutter
  recognizers take each move as an observation: a predicted point bent a
  pinch's scale velocity (`ScaleGestureRecognizer` tracks synthesized
  moves), and a real sample arriving behind a prediction either stepped
  the finger back or went missing from the fling speed. Taking the stamp
  for the vsync sampled 1.7 ms early at 120 Hz and interpolated almost
  never: slow drags alternated still and double-step frames.
- **Check:** `test/touch_resampler_test.dart` "a frame shows where the finger was 10 ms before its vsync" "a frame between two samples moves on without a new one" "leaves at the speed of its real samples"
- **Code:** `lib/core/platform/touch_resampler.dart`, `lib/main.dart`, `lib/core/debug/trace_marks.dart`

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

### MOTION-21 Work ahead of the user waits for a still screen
- **Rule:** Building ahead (neighbour tabs, unvisited home branches, the
  detail pager's neighbours) goes through `StillWork`: one piece per frame
  with the screen visible, no finger down, no tracked scroll, no
  foreground image load in flight (unless the work opts out) and no
  animation (waited for at most 60 frames); never `transientCallbackCount`
  alone. A swipe or tap that gets there first builds at once. A branch
  built ahead is under `ExcludeFocus` until shown, and a page never shown
  saves no setting.
- **Why:** Neighbour tabs built in a swipe's first frame and their data
  landed mid-snap (29–38 ms frames, 10-15 trace); a held finger keeps no
  ticker. An off-screen branch Navigator took the search field's focus.
- **Check:** `test/tab_swipe_switcher_test.dart` "the tabs either side build one per still frame, next first" "a loading image and a held finger hold the tabs back", `test/home_branch_stack_test.dart` "the other branches build one per still frame, after the first" "a switch before its turn builds the branch at once", `test/illust_detail_pager_test.dart` "neighbours build after the push transition, one per frame"
- **Code:** `lib/app/motion/still_work.dart`, `lib/app/widgets/tab_swipe_switcher.dart`, `lib/app/widgets/home_branch_stack.dart`, `lib/app/navigation/routes.dart`, `lib/features/illust/detail/illust_detail_pager_page.dart`, `lib/core/image/image_worker.dart`, `lib/features/ranking/ranking_tabs.dart`
