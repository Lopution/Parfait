---
prefix: QUAL
applies_to:
  - lib/**
  - analysis_options.yaml
reviewed: 2026-10-12
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
