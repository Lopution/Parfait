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
reviewed: 2026-11-23
---

# Motion, press feedback and the rebuild budget

## Contents

- [Durations and springs](#durations-and-springs)
- [Press and removal](#press-and-removal)
- [Rebuild and semantics budget](#rebuild-and-semantics-budget)

## Durations and springs

### MOTION-01 UI durations come from MotionTokens.resolve
- **Rule:** Every UI animation duration comes from `MotionTokens.resolve(context, token)` (`resolveWith` above `MotionScope`), applying speed settings and returning zero under reduced motion. Data timings (debounces/throttles) are not tokens; tokens name semantic movements (`stateFade`, `chrome`, `spatial`, `scrollToTop`, `themeChange`, `sheetExit`, `pageTransition`, etc.).
- **Why:** Hard-coded durations ignored speed and reduced-motion preferences and mismatched movement scale.
- **Check:** `test/architecture/ui_conventions_test.dart` "duration tokens are read through MotionTokens.resolve" "motion durations live only in MotionTokens (pinned census)", `test/home_branch_stack_test.dart` "a re-tap from"
- **Code:** `lib/app/motion/motion_tokens.dart`

### MOTION-02 Reduced motion removes the flight, not the state
- **Rule:** Under reduced motion end states still apply immediately (`turnPage(context, controller, page)` jumps instead of `animateToPage`). Every new motion ships a `MotionScope(reduce: true)` test.
- **Why:** `animateToPage` asserts non-zero duration and skipped animations previously dropped state updates.
- **Check:** `test/motion_test.dart` "reduced motion and ids off screen complete at once" "reduced motion resizes at once"
- **Code:** `lib/app/motion/motion_tokens.dart`

### MOTION-03 Spatial springs move, effects springs fade
- **Rule:** Read `MotionSpring` tokens only via `MotionTokens.spring` (null under reduced motion) or `MotionTokens.springCurve`. Spatial springs drive position/scale/size; effects springs drive opacity/color; never swap families or keep unused tokens. Press/size/sheet motion uses standard non-overshooting springs; expressive `SpringPop` fires only on user-triggered state flips (bookmark, follow, `StateIconSwitcher`), never rebuilds or initial mounts.
- **Why:** Effects springs overshot layout changes and pervasive bounces felt wobbly.
- **Check:** `test/architecture/ui_conventions_test.dart` "spring tokens are read through MotionTokens.spring", `test/motion_test.dart` "a swap pops the new icon past its size and back"
- **Code:** `lib/app/motion/motion_tokens.dart`, `lib/app/motion/spring_pop.dart`

### MOTION-04 Physical springs snap to their end
- **Rule:** Every widget-driving `SpringSimulation` sets `snapToEnd: true`.
- **Why:** Without snapping, transforms settled at 0.9998 and kept non-identity layers alive.
- **Check:** `test/motion_test.dart` "a spring curve starts at 0 and ends exactly at 1"
- **Code:** `lib/app/motion/press_scale.dart`, `lib/app/motion/drag_to_dismiss.dart`

### MOTION-05 Size changes go through SpringSize
- **Rule:** Expanding/collapsing sections use `SpringSize` (returning `child` directly under reduced motion).
- **Why:** Zero-duration `AnimatedSize` asserts during layout.
- **Check:** `test/motion_test.dart` "opening and closing animate the height" "reduced motion resizes at once"
- **Code:** `lib/app/motion/spring_size.dart`

### MOTION-14 A state change that moves content animates
- **Rule:** User-toggled blocks use `Reveal` (enter via `SpringSize` + fade; exit fades non-tappably then closes); same-size view swaps use `StateFade(kind:)` (painting 1/255 alpha on frame 0 and starting the fade next frame so heavy first frames never skip fade-in); mode-changing top bars cross-fade on `MotionTokens.chrome`, while bars replaced by a mode slide out via `slideChrome`. Small inline control swaps, selection tints, and live typing results stay instant.
- **Why:** Avoided jarring layout pops and skipped fades while keeping micro-interactions crisp.
- **Check:** `test/motion_test.dart` "fades in, and fades out before the block leaves" "reduced motion hides at once" "a new state paints in its first frame and fades after it"
- **Code:** `lib/app/motion/reveal.dart`, `lib/app/motion/state_fade.dart`, `lib/app/widgets/app_top_bar.dart`

## Press and removal

### MOTION-06 One kind of press feedback per element
- **Rule:** Each tappable element uses one press style: surface ink highlight (`THEME-01`) for rows/tiles/menus/buttons/bottom bar, or `PressScale` for cards (0.97) and pills (0.96); cards holding inner buttons (`PersonCard`) use surface highlight; `TagChip` omits ink because its 48dp target exceeds the pill; disabled controls show no press.
- **Why:** Combining ripple and scale read as double-presses, and raw pointer scaling shrank cards when inner buttons were tapped.
- **Check:** `test/motion_test.dart` "inside a scrollable a swipe never shows the press" "the press-feedback setting turns the scale off"; `test/spotlight_feed_test.dart` "spotlight feed page lists articles, switches category, opens article"
- **Code:** `lib/app/motion/press_scale.dart`

### MOTION-18 Drags take the device's slop; sideways pagers judge the angle
- **Rule:** Custom drag recognizers read `MediaQuery.maybeGestureSettingsOf(context)` and `computeHitSlop` (never hard-coded `kTouchSlop`). Viewer pagers use `PagingSlop` / `PagingSlopPage` (`minFlingDistance` stays device slop); detail pagers inside `SelectionArea` judge angle at 1x device slop (excluding mouse) so `SelectableRegion`'s 18px recognizer cannot steal touch swipes; tab/branch swipes (`SwipePagingRecognizer`) require `<= swipePagingMaxDegrees` (40 deg) off horizontal.
- **Why:** Hard-coded 18px slop caused pagers, dismiss drags, and `SelectionArea` to fight touch gestures on 8dp-slop Android screens.
- **Check:** `test/motion_test.dart` "a scroll takeover releases the pressed scale", `test/illust_detail_pager_test.dart` "scrolls the detail" "a panorama scrolls first and hands the swipe on at its edge", `test/tab_swipe_switcher_test.dart` "moves the tabs" "leaves the tabs", `test/hero_transition_test.dart` "only the entry page flies back"
- **Code:** `lib/app/scroll_behavior.dart`, `lib/app/motion/drag_to_dismiss.dart`, `lib/app/motion/press_scale.dart`, `lib/app/motion/swipe_paging.dart`, `lib/features/illust/detail/illust_detail_pager_page.dart`, `lib/features/illust/detail/widgets/detail_image_pager.dart`

### MOTION-20 A released swipe lands from the finger's speed
- **Rule:** Sideways swipes land on velocity-preserving springs (`SwipePaging` uses `MotionSpring.spatialDefault`, changing index once on landing unless dragged a full page, with `BouncingScrollPhysics` at ends and semantics held mid-motion; `PageView` uses `PageSnapPhysics` for ~300 ms snap while keeping list overscroll physics).
- **Why:** Fixed-duration curves stalled flings and framework 0.7 s snaps delayed neighbour builds.
- **Check:** `test/tab_swipe_switcher_test.dart` "from the finger's speed" "a slow drag" "the index waits for the landing" "past the first tab the body pulls on a rubber band", `test/scroll_behavior_test.dart` "ends its page snap in about 300 ms"
- **Code:** `lib/app/motion/swipe_paging.dart`, `lib/app/widgets/tab_swipe_switcher.dart`, `lib/app/scroll_behavior.dart`, `lib/features/illust/detail/illust_detail_pager_page.dart`, `lib/features/illust/viewer/image_viewer_page.dart`

### MOTION-07 Feed cards land in place
- **Rule:** Grid cards have no entrance animation or `StateFade` wrapper; only images fade (TRANS-16).
- **Why:** Card entrances stacked on image fades and replayed on recycled slots.
- **Check:** manual
- **Code:** `lib/app/widgets/feed/feed_grid.dart`

### MOTION-08 Removal plays the exit, then commits
- **Rule:** Capture stores/actions upfront, `await controller.playExit(ids)` via `RemovalController` (`RemovalScope.of`), then commit (calling `restore(ids)` on failure); position-styled containers exclude `controller.leaving` from frame 0.
- **Why:** Committing first cut rows out abruptly; reading context post-await hit disposed widgets.
- **Check:** `test/motion_test.dart` "restore brings a row back after a failed commit" "a row disposed mid-exit does not leave the exit hanging", `test/watchlater_page_test.dart` "a page closed during the exit still removes the works"
- **Code:** `lib/app/motion/removal.dart`

### MOTION-09 Grow-in rows are few and marked on insert
- **Rule:** `Removable(animateIn: true)` applies only to a bounded count of rows newly inserted by a user action on that frame.
- **Why:** Zero-height grow-in rows forced lazy lists to build every marked row eagerly.
- **Check:** `test/motion_test.dart` "an inserted row grows in and fades from zero"
- **Code:** `lib/app/motion/removal.dart`

## Rebuild and semantics budget

### MOTION-10 Per-card widgets keep narrow dependencies
- **Rule:** Repeated card/image widgets read `MediaQuery` only through aspect getters (`sizeOf`, `maybeDisableAnimationsOf`), mix in `TickerModeWatch` instead of `TickerMode.valuesOf`, and read route animations from `RouteAnimationScope.of` instead of `ModalRoute.of(context)?.animation`.
- **Why:** Broad subscriptions rebuilt entire feeds on inset or `isCurrent` changes, saturating Android's main thread and accessibility services.
- **Check:** manual — rebuilds are not asserted (TEST-12)
- **Code:** `lib/app/motion/motion_tokens.dart`, `lib/app/motion/press_scale.dart`, `lib/app/pixiv_image.dart`, `lib/app/navigation/route_animation.dart`

### MOTION-11 Fades keep semantics; progress moves in steps
- **Rule:** Opacity entrances pass `alwaysIncludeSemantics: true`; progress semantics step in 10% increments while drawn rings stay continuous.
- **Why:** Prevents semantics churn on every progress frame and keeps faded content discoverable.
- **Check:** `test/image_load_progress_test.dart` "a slow load shows its percentage, then the ring goes"
- **Code:** `lib/app/motion/state_fade.dart`, `lib/app/widgets/image_load_progress.dart`

### MOTION-12 Slow first channel calls are warmed up
- **Rule:** Channels with heavy first-call main-thread latency warm sequentially in `androidChannelWarmupSteps`, each waiting for a 300 ms idle gap.
- **Why:** Eliminated first-use jank without triggering during active interaction.
- **Check:** manual
- **Code:** `lib/core/platform/native_warmup.dart`

### MOTION-13 Semantics reach the platform at most every 100 ms
- **Rule:** The root pipeline owner throttles semantics flushes to `kSemanticsPushInterval` (100 ms); route transitions, branch switches, and scrolls (`ScrollSemanticsHold`) hold pushes up to `kSemanticsHoldLimit` (2 s), flushing after an interval and an idle frame. Widget tests keep the default binding outside the throttle's own suite.
- **Why:** User decision: per-frame semantics pushes cost 7–11 ms under active accessibility services during scrolls and transitions.
- **Check:** `test/semantics_push_throttle_test.dart` "a scrolling feed pushes semantics at most once per interval and the last state arrives once it stops" "a hold keeps changes back until an interval after its release, and gives way at its limit"
- **Code:** `lib/core/platform/app_root_pipeline_owner.dart`, `lib/app/scroll_behavior.dart`, `lib/app/motion/page_transitions.dart`, `lib/app/widgets/home_branch_stack.dart`

### MOTION-17 GPU pipelines a first use would compile are warmed at start
- **Rule:** `PipelineWarmup` paints offscreen clipped/transformed image and rounded-rect press-highlight layers during the first three frames while keeping `widget.child` mounted as its stable first `Stack` child.
- **Why:** First Hero flights dropped frames on cold pipeline compilation, and unwrapping the `Stack` after warmup remounted the app.
- **Check:** `test/startup_gate_test.dart` "the warm-up runs offscreen layers and keeps the app mounted"
- **Code:** `lib/app/startup_gate.dart`

### MOTION-22 Raster threads run on every core of a chip without little cores
- **Rule:** On Android startup, `freeRasterThreads` widens `*.raster` CPU affinity to all cores only when every core's `cpu_capacity` is at least half the fastest; otherwise keeps the engine default.
- **Why:** Prevented prime cores from idling on big-only SoCs while avoiding little cores on heterogeneous chips.
- **Check:** `test/raster_affinity_test.dart` "frees every core only when none is little" "sets only the raster threads, from a full capacity table"
- **Code:** `lib/core/platform/raster_affinity.dart`, `lib/main.dart`

### MOTION-19 Touch moves reach the app once per frame, resampled
- **Rule:** The app binding routes pointer events through `TouchResampler`, emitting interpolated moves at `vsync - 10 ms` (using `handleBeginFrame` minus one refresh period, never extrapolating past the latest sample) tagged `synthesized`; velocity trackers ignore synthesized moves.
- **Why:** Eliminated uneven per-frame touch steps and Android prediction artefacts during slow drags and pinches.
- **Check:** `test/touch_resampler_test.dart` "a frame shows where the finger was 10 ms before its vsync" "a frame between two samples moves on without a new one" "leaves at the speed of its real samples"
- **Code:** `lib/core/platform/touch_resampler.dart`, `lib/main.dart`, `lib/core/debug/trace_marks.dart`

### MOTION-15 Width-dependent slivers rebuild only on a width change
- **Rule:** Use `SliverWidthBuilder` instead of `SliverLayoutBuilder`; cache repeated formatters, spring curves, and label widths (`AppFormat`, `MotionTokens.springCurve`, `LabelFit.measureLabel`).
- **Why:** `SliverLayoutBuilder` rebuilt every visible row on every scroll offset, costing up to 6 ms/frame with accessibility on.
- **Check:** `test/responsive_layout_test.dart` "a width-built sliver takes taps after a scroll and follows a"
- **Code:** `lib/app/layout/sliver_width_builder.dart`, `lib/app/format/app_format.dart`, `lib/app/motion/motion_tokens.dart`, `lib/app/widgets/fit_label.dart`

### MOTION-16 Repeated parts of a page get their own ticker notifier
- **Rule:** Feed cards, card rows, and detail pages/sections sit inside `TickerPartition`; uniform wrapper lists hold no conditional entries.
- **Why:** Removing hundreds of listeners from one shared route notifier took 43% of detail unmount frames.
- **Check:** `test/motion_test.dart` "a ticker partition mutes with its ancestor"
- **Code:** `lib/app/motion/motion_tokens.dart`, `lib/app/widgets/feed/feed_grid.dart`, `lib/app/layout/card_columns.dart`, `lib/features/illust/detail/illust_detail_shells.dart`

### MOTION-21 Work ahead of the user waits for a still screen
- **Rule:** Pre-building neighbour tabs, branches, and detail pages goes through `StillWork` (one piece per still frame with no active touch, scroll, foreground image load, or animation—capped at 60 frames per run); direct navigation builds immediately; off-screen branches sit under `ExcludeFocus` and never persist settings.
- **Why:** Building ahead mid-swipe caused 29–38 ms frames and off-screen navigators stole focus.
- **Check:** `test/home_branch_stack_test.dart` "a branch built ahead and never shown saves no setting" "a switch before its turn builds the branch at once", `test/motion_test.dart` "work ahead waits for a running animation to end" "work ahead behind a looping indicator waits once a run"
- **Code:** `lib/app/motion/still_work.dart`, `lib/app/widgets/tab_swipe_switcher.dart`, `lib/app/widgets/home_branch_stack.dart`, `lib/app/navigation/routes.dart`, `lib/features/illust/detail/illust_detail_pager_page.dart`, `lib/core/image/image_worker.dart`, `lib/features/ranking/ranking_tabs.dart`

### MOTION-23 Pointer input removes touch press delay, eases wheel reversal and shortens branch travel
- **Rule:** Under `InputModality.pointer`, `PressScale` skips the 100 ms scroll delay; `HomeBranchStack` over `ShellRail` switches branches with 150 ms `MotionTokens.desktopPageTransition` fade + 12dp slide (cut under reduced motion); `SmoothWheelScroll` animates discrete wheel ticks over `MotionTokens.wheelScroll` (240 ms, jumping directly with `Duration.zero` under reduced motion), discarding queued travel and emitting `dispatchWheelUserScroll` immediately on direction reversal so `ScrollHide` bars respond on the first reverse tick.
- **Why:** Touch tap delays, full-width slides, and stale forward wheel targets feel sluggish with a mouse.
- **Check:** `test/motion_test.dart` "Pointer mode skips PressScale 100ms delay and SmoothWheelScroll jumps instantly"; `test/smooth_wheel_scroll_test.dart` "reversing wheel direction mid-scroll resets queued target and notifies reversal immediately"; `test/home_branch_stack_test.dart` "desktop ShellRail animates branch switch with 150ms fade+slide"
- **Code:** `lib/app/motion/press_scale.dart`, `lib/app/motion/motion_tokens.dart`, `lib/app/motion/scroll_hide.dart`, `lib/app/widgets/home_branch_stack.dart`, `lib/app/widgets/smooth_wheel_scroll.dart`

### MOTION-24 Frosted card menu and drag-to-dismiss suppress displacement under reduced motion
- **Rule:** Under reduced motion (`!MotionTokens.enabled(context)`), `IosCardContextMenu`, `DragToDismiss`, and iOS `FuncPage` shared-element dismiss suppress translation, scaling, and corner rounding while preserving backdrop fade and threshold completion.
- **Why:** Spatial scaling/translation triggers motion discomfort under reduced-motion settings.
- **Check:** `test/card_action_test.dart` "iOS card context menu respects reduced motion without scaling", `test/func_page_test.dart` "iOS sharedElement canvas dismiss disables scale and displacement under reduced motion"
- **Code:** `lib/app/widgets/card_actions/ios_card_context_menu.dart`, `lib/app/motion/drag_to_dismiss.dart`, `lib/app/navigation/func_page.dart`, `lib/app/motion/motion_tokens.dart`
