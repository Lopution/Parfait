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
reviewed: 2026-11-28
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
- **Check:** `test/architecture/ui_conventions_test.dart` "duration tokens are read through MotionTokens.resolve" "motion durations live only in MotionTokens (pinned census)"
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
- **Rule:** Each tappable element uses one press style: surface ink highlight (`THEME-01`) for rows/tiles/menus/buttons/chips/bottom bar, or `PressScale` for cards (0.97) and pills (0.96); cards pairing `PressScale` with `InkWell` for hover/focus silence press ink via `NoSplash.splashFactory` + `pressScaleInkOverlay`; cards holding inner buttons (`PersonCard`, `IllustSeriesSection`) use surface highlight; `TagChip` omits ink because its 48dp target exceeds the pill; disabled controls show no press.
- **Why:** Combining ripple and scale read as double-presses, and raw pointer scaling shrank cards when inner buttons were tapped.
- **Check:** `test/motion_test.dart` "inside a scrollable a swipe never shows the press" "the press-feedback setting turns the scale off"; `test/spotlight_feed_test.dart` "spotlight feed page lists articles, switches category, opens article" "SpotlightListSkeleton renders bones, AppChoiceChip omits PressScale, and UserPreviewRow mounts Hero without press ink"
- **Code:** `lib/app/motion/press_scale.dart`, `lib/app/widgets/app_choice_chip.dart`, `lib/features/illust/detail/widgets/illust_series_section.dart`

### MOTION-18 Drags take the device's slop; sideways pagers judge the angle
- **Rule:** Custom drag recognizers read `MediaQuery.maybeGestureSettingsOf(context)` and `computeHitSlop` (never hard-coded `kTouchSlop`). Viewer pagers use `PagingSlop` / `PagingSlopPage` (`minFlingDistance` stays device slop); detail pagers inside `SelectionArea` judge angle at 1x device slop (excluding mouse) so `SelectableRegion`'s 18px recognizer cannot steal touch swipes; tab/branch swipes (`SwipePagingRecognizer`) require `<= swipePagingMaxDegrees` (40 deg) off horizontal.
- **Why:** Hard-coded 18px slop caused pagers, dismiss drags, and `SelectionArea` to fight touch gestures on 8dp-slop Android screens.
- **Check:** `test/motion_test.dart` "a scroll takeover releases the pressed scale"
- **Code:** `lib/app/scroll_behavior.dart`, `lib/app/motion/drag_to_dismiss.dart`, `lib/app/motion/press_scale.dart`, `lib/app/motion/swipe_paging.dart`, `lib/features/illust/detail/illust_detail_pager_page.dart`, `lib/features/illust/detail/widgets/detail_image_pager.dart`

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

### MOTION-12 Slow first channel calls are warmed up
- **Rule:** Channels with heavy first-call main-thread latency warm sequentially in `androidChannelWarmupSteps`, each waiting for a 300 ms idle gap.
- **Why:** Eliminated first-use jank without triggering during active interaction.
- **Check:** manual
- **Code:** `lib/core/platform/native_warmup.dart`

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

### MOTION-16 Repeated parts of a page get their own ticker notifier
- **Rule:** Feed cards, card rows, and detail pages/sections sit inside `TickerPartition`; uniform wrapper lists hold no conditional entries.
- **Why:** Removing hundreds of listeners from one shared route notifier took 43% of detail unmount frames.
- **Check:** `test/motion_test.dart` "a ticker partition mutes with its ancestor"
- **Code:** `lib/app/motion/motion_tokens.dart`, `lib/app/widgets/feed/feed_grid.dart`, `lib/app/layout/card_columns.dart`, `lib/features/illust/detail/illust_detail_shells.dart`

### MOTION-21 Work ahead of the user waits for a still screen
- **Rule:** Pre-building neighbour tabs, branches, and detail pages goes through `StillWork` (one piece per still frame with no active touch, scroll, foreground image load, or animation—capped at 60 frames per run); direct navigation builds immediately; off-screen branches sit under `ExcludeFocus` and never persist settings.
- **Why:** Building ahead mid-swipe caused 29–38 ms frames and off-screen navigators stole focus.
- **Check:** `test/home_branch_stack_test.dart` "a branch built ahead and never shown saves no setting on leaving" "a switch before its turn builds the branch at once", `test/motion_test.dart` "work ahead waits for a running animation to end" "work ahead behind a looping indicator waits once a run, not once a piece"
- **Code:** `lib/app/motion/still_work.dart`, `lib/app/widgets/tab_swipe_switcher.dart`, `lib/app/widgets/home_branch_stack.dart`, `lib/app/navigation/routes.dart`, `lib/features/illust/detail/illust_detail_pager_page.dart`, `lib/core/image/image_worker.dart`, `lib/features/ranking/ranking_tabs.dart`
