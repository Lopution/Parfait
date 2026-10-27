---
prefix: TEST
applies_to:
  - test/**
  - tool/test_shards.py
  - dart_test.yaml
reviewed: 2026-10-13
---

# Tests

## Contents

- [What a test proves](#what-a-test-proves)
- [Volume](#volume)
- [Test environment traps](#test-environment-traps)

## What a test proves

### TEST-01 A regression test is run against the defect
- **Rule:** Before trusting a test written with a fix, restore the old
  implementation (`git show HEAD:<path>`), run the new cases and confirm
  the ones encoding the defect fail.
- **Why:** Regression tests passed for reasons unrelated to the bug.
- **Check:** manual
- **Code:** `test`

### TEST-02 Assert the end state and that the condition happened
- **Rule:** Gesture and animation tests assert what is on screen after the
  interaction ends. A case that depends on a condition (an overscroll, a
  sent request) asserts the condition occurred, and names which side of a
  threshold it exercises.
- **Why:** "Indicator stuck on screen" passed because every assertion
  stopped at release; a pull short of the arm threshold took a branch no
  real pull takes.
- **Check:** manual
- **Code:** `test`

### TEST-03 Assert observable behaviour, at the lowest layer
- **Rule:** Tests assert rendered output, semantics, navigation and state
  changes, not framework or third-party constructor parameters
  (`tester.widget<T>(…).param`). The exception is a parameter that is
  itself the contract; comment which. One behaviour is covered at one
  layer: the lowest that reproduces it. A regression test is a widget
  test only when the defect lives in interaction or layout; a logic
  defect found through the UI gets a unit test of that logic.
- **Why:** Parameter assertions failed in bulk on every refactor. A widget
  case averages 27 lines against a unit case's 18, and covers more
  incidental code that breaks it.
- **Check:** manual
- **Code:** `test`

### TEST-04 Removing a guard removes the tests that froze it
- **Rule:** Tests encoding a removed or relaxed guard's wrong behaviour
  are deleted in the same commit; no `skip:`. A replaced implementation's
  tests are rewritten in the same PR.
- **Why:** Skipped tests kept asserting the old defect.
- **Check:** `test/architecture/test_hygiene_test.dart` "no skipped cases"
- **Code:** `test`

## Volume

### TEST-05 The suite stays within its budget
- **Rule:** User decision: `test/` holds at most `ratio` × `lib/` Dart
  code lines (`tool/test_budget.json`, 0.607; blank and comment lines
  excluded; `test/review/` and `test/fixtures/` not counted), so tests
  grow with the code but not faster. Only the user changes the ratio; an
  agent asks and never edits it. A change that needs room makes it in this order: dedupe or
  table-drive repeated cases; drop UI tests of colour, spacing, order or
  copy; drop tests of removed code; drop a duplicated layer. Tests of
  core logic, fixed bugs and security are never deleted for room. A UI
  change ships one or two tests of its key behaviour; layout, colour,
  spacing and copy are checked with review screenshots. No per-locale or
  per-variant copies of a case. Core logic (network, credentials,
  downloads, paging, parsing, persistence) and every fixed bug keep
  thorough coverage. A file over 1500 lines is split by feature, with
  shared fakes in `test/helpers/`. A test file is named after the `lib/`
  module it covers; a file of one or two cases joins its feature's file
  unless it is the only test of its module.
- **Why:** The suite doubled in a month, mostly with parameter assertions
  and duplicated layers; dozens of one-case files each cost a compile;
  test/lib rose from 0.41 to 0.81. Under a fixed 60,000-line cap the
  suite grew in step with `lib/` (about 0.55 test lines per new lib
  line) and met the cap again within a week; a ratio keeps the alarm for
  tests outgrowing the code without a wall every few days.
- **Check:** `tool/test_budget.py`, `test/architecture/test_hygiene_test.dart` "test files stay under"
- **Code:** `test`

### TEST-10 A test double is defined once
- **Rule:** Look in `test/helpers/` before writing a fake, stub, recorder
  or fixture server. A double a second file needs moves to `test/helpers/`
  and both import it; a small difference becomes a parameter of the
  shared one. A double that behaves differently gets a name that says how
  (`_ThrowAfterWriteSink`, not a second `_FailingSink`) and a body that
  is mostly its own: a class sharing 80% of its lines with a class in
  another file is a copy, whatever its name.
- **Why:** Eight copies of one account stub drifted apart, and a fix to
  one copy left the others asserting the old behaviour. Renamed copies
  (`_Resolver`, `_ScriptedResolver`, `StubResolver` beside `FakeResolver`)
  passed a name-only check; a third of the suite sat outside any case.
- **Check:** `test/architecture/test_hygiene_test.dart` "each test double is defined once" "no test double is copied into a second file"
- **Code:** `test/helpers`

## Test environment traps

### TEST-06 CI shards whole files
- **Rule:** CI gives each shard whole test files through
  `tool/test_shards.py`; never use `flutter test --total-shards`. Every
  file under `test/` ending in `_test.dart` lands in exactly one shard. A
  case still sets up its own state, so `--plain-name` runs it alone.
- **Why:** `--total-shards` splits cases inside every file, so each shard
  compiled and loaded almost the whole suite and extra shards bought
  little; case-level splitting also broke cases that relied on an earlier
  one.
- **Check:** `tool/test_shards.py`
- **Code:** `tool/test_shards.py`, `.github/workflows/ci.yml`

### TEST-07 Loopback sockets retry; databases get their own path
- **Rule:** A test that binds or connects to `127.0.0.1` wraps its body in
  a three-attempt `tolerant()` helper that resets per-attempt state, with
  a raised timeout, and its file is tagged `@Tags(['socket'])` so
  `flutter test -x socket` can leave it out. `test/flutter_test_config.dart`
  gives each test file its own default databases directory; a test that
  reads or writes history still injects `HistoryDatabase` with a per-test
  `databasePath`.
- **Why:** The WSL test VM drops about one in five loopback connections
  under full-suite load. Pages that open an app database at its default
  path shared one FFI directory across parallel files and failed with
  `database is locked` whenever CI sharding put two of them together.
- **Check:** `test/oauth_service_test.dart`,
  `test/architecture/test_hygiene_test.dart` "socket tests carry the socket tag"
- **Code:** `test/flutter_test_config.dart`,
  `test/helpers/history_world.dart`, `dart_test.yaml`

### TEST-08 Riverpod providers that dispose or retry
- **Rule:** Before awaiting an `autoDispose` provider's `.future`, hold a
  listener (`container.listen`). The same trap exists in pages: subscribe
  (`ref.watch` or `ref.listenManual`) before `ref.read(...notifier).load()`.
  A failing `AsyncNotifier.build` retries forever, so assert its
  `AsyncError` state instead of awaiting `.future`.
- **Why:** A zero-listener notifier was disposed mid-load and left a
  permanent spinner; awaiting a failing build hung until dispose.
- **Check:** manual
- **Code:** `lib/features/profile/profile_edit_page.dart`

### TEST-09 Widget test harness traps
- **Rule:** Import `package:material_ui/material_ui.dart`, not
  `flutter/material.dart`, and pump its `MaterialApp` with
  `promptHostBuilder` when prompts show. Non-latin-1 HTTP fixtures use
  `http.Response.bytes(utf8.encode(...))` with a charset. Pages building
  `InAppWebView` set a fake `InAppWebViewPlatform.instance`. Read
  `SystemChrome.latestStyle` only after a `pump`. Record haptics with
  `recordHaptics()`, not a platform-channel mock. Wrap motion subjects in
  `MotionScope(reduce:, speed:)`.
- **Why:** Each trap made a correct implementation look broken: finders
  matched nothing, fixtures threw on construction, styles were read before
  the frame applied them.
- **Check:** manual
- **Code:** `test/helpers/prompt_host.dart`, `test/helpers/recording_haptics.dart`

### TEST-11 Waits use fake time
- **Rule:** No `sleep`. Advance time with `fakeAsync` or
  `tester.pump(duration)`. A real-clock `Future.delayed` belongs only
  inside `tester.runAsync` for real IO, in a bounded loop. The loop ends on
  a condition, not a round count: database calls a widget made in the fake
  zone advance one round trip per pump, so wait for a probe queued behind
  them on the database lock (`settleHistory`).
- **Why:** A real wait makes a case slow on a fast machine and flaky on a
  loaded one, and `sleep` also blocks the isolate the test drives. Two
  fixed rounds left a history query waiting for the lock on a loaded CI
  runner, and its lock-warning timer outlived the test.
- **Check:** `test/architecture/test_hygiene_test.dart` "no real sleeps"
- **Code:** `test`, `test/helpers/history_world.dart`
