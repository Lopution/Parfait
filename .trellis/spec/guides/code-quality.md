---
prefix: QUAL
applies_to:
  - lib/**
  - analysis_options.yaml
reviewed: 2026-10-30
---

# Code quality

### QUAL-01 Suppressions carry a reason
- **Rule:** `flutter analyze` stays at zero issues. An `// ignore:` has its
  reason on the same line or in the comment directly above it.
- **Why:** Without a reason nobody can tell whether the ignore still
  applies after the analyzer or the code around it changes.
- **Check:** manual
- **Code:** `analysis_options.yaml`

### QUAL-02 No second state machine beside the framework's
- **Rule:** A threshold, a "pointer is down" judgement or a progress value
  exists in one place. Mirroring an authoritative framework value to render
  from is fine; accumulating a private copy, deciding a threshold from it
  or overriding the framework's decision is not.
- **Why:** A pull-to-refresh wrapper that re-derived scroll state re-armed
  pulls on pointer up, vetoed refreshes the framework had started and left
  the indicator stuck on screen, all from one duplicated measurement.
- **Check:** manual
- **Code:** `lib/app/widgets/feed`

### QUAL-03 Remove a wrong guard instead of patching in front of it
- **Rule:** When a guard blocks correct behaviour, delete or relax it; do
  not add a condition before it. When the framework seems unable to deliver
  a requirement, try its other primitives (physics, gesture arena, layout,
  status callbacks) and change the design, not the requirement.
- **Why:** Stacked guards and scaled-down requirements kept the defect and
  added code.
- **Check:** manual
- **Code:** `lib`

### QUAL-04 Never wait for animations with a `Priority.idle` task
- **Rule:** Work that must wait for animations to finish re-checks from
  post-frame callbacks with a frame cap.
- **Why:** While transient callbacks exist the scheduler re-queues an idle
  task in a tight loop; under fake async `flutter_tester` grew about
  160 MB/s until the host ran out of memory.
- **Check:** manual
- **Code:** `lib/features/illust/detail/illust_detail_pager_page.dart`

### QUAL-05 Scenes worth timing go through FrameProbe
- **Rule:** A scene that jank may be pinned on (a transition, a branch
  switch, a Hero, a decode) is bracketed with `FrameProbe.enter`/`exit` or
  noted with `FrameProbe.mark`, never a raw `Timeline` call. Both reach the
  in-app probe and, outside release, the system trace as `parfait` marks
  beside the page and pointer marks of `TraceMarks`. The page mark names
  the router's top match (`matchedLocation`), pushed routes included;
  `AppTabBar` marks each tab switched to, since tabs share their route.
  Release attaches nothing. Work on another isolate, where the probe does
  not live (the data worker), times itself with `Timeline.timeSync`.
- **Why:** A trace held only touch delivery times, so a janky frame from
  a free session on a device could not be placed on a page or a gesture.
  go_router's `uri` leaves out pushed routes: the first device recording
  showed no page at all while a detail page opened and closed, and the
  janky "users" tab of the recommended page read as the whole page.
- **Check:** `test/trace_marks_test.dart` "a tap and a fling are marked down and up, the fling fast" "a route change marks the page and the scene it plays" "a tab switched to is marked, the first tab is not"
- **Code:** `lib/core/debug/trace_marks.dart`, `lib/core/debug/frame_probe.dart`, `lib/app/widgets/app_tab_bar.dart`

### QUAL-06 A future, sink or subscription ends on purpose
- **Rule:** A future started from synchronous code is awaited, or passed to
  `unawaited` when its errors are handled where it runs (a loader's own
  `catch`, a navigation push); one whose errors nobody handles gets a
  handler first, and an rhttp cancel calls `.ignore()` (NET-18). Its owner
  closes a `StreamController` and cancels a subscription; one left open on
  purpose says why above its `// ignore:` (QUAL-01). The analyzer enforces
  this. Likewise its owner disposes a notifier, controller or animation;
  a `build` curves with a `CurveTween`, which holds nothing, not a new
  `CurvedAnimation`, and an image stream listener disposes the `ImageInfo`
  it is handed. Leak tracking (TEST-15) fails a widget test that leaves one.
- **Why:** A dropped future's error reaches the zone and the crash log with
  no handler, and nothing told a deliberate fire-and-forget from a
  forgotten `await`.
- **Check:** `analysis_options.yaml` "discarded_futures" "close_sinks" "cancel_subscriptions" "avoid_void_async"
- **Code:** `analysis_options.yaml`

### QUAL-07 A `!` rests on what the reader sees
- **Rule:** A null assertion follows a check on the same value with nothing
  async in between, or rests on a contract of the type or the framework: a
  const map over every enum value, a regex group that is not optional, a
  laid-out child's geometry, a `NOT NULL` column. When the guarantee lives
  elsewhere (a field set and cleared with another, a value no await can
  clear), a pattern or a local carries it, else a comment names it.
- **Why:** An assertion whose guarantee lives in another method breaks
  without a sign when that method changes, and a reader cannot tell it
  from one that is a crash waiting to happen.
- **Check:** manual
- **Code:** `lib`
