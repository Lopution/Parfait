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

### TEST-03 Assert observable behaviour, at one layer
- **Rule:** Tests assert rendered output, semantics, navigation and state
  changes, not framework or third-party constructor parameters
  (`tester.widget<T>(…).param`). The exception is a parameter that is
  itself the contract; comment which. One behaviour is covered at one
  layer.
- **Why:** Parameter assertions failed in bulk on every refactor.
- **Check:** manual
- **Code:** `test`

### TEST-04 Removing a guard removes the tests that froze it
- **Rule:** Tests encoding a removed or relaxed guard's wrong behaviour
  are deleted in the same commit; no `skip:`. A replaced implementation's
  tests are rewritten in the same PR.
- **Why:** Skipped tests kept asserting the old defect.
- **Check:** manual
- **Code:** `test`

## Volume

### TEST-05 The suite stays within its budget
- **Rule:** User decision: `test/` holds at most 60,000 Dart code lines
  (blank and comment lines excluded; `test/review/` and `test/fixtures/`
  not counted). Raising the cap needs the user's consent. A UI change
  ships one or two tests of its key behaviour; layout, colour, spacing and
  copy are checked with review screenshots. No per-locale or per-variant
  copies of a case. Core logic (network, credentials, downloads, paging,
  parsing, persistence) and every fixed bug keep thorough coverage. A file
  over 1500 lines is split by feature, with shared fakes in
  `test/helpers/`.
- **Why:** The suite doubled in a month, mostly with parameter assertions
  and duplicated layers.
- **Check:** manual
- **Code:** `test`

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
  a raised timeout. A test reaching the history database injects
  `HistoryDatabase` with a per-test `databasePath`.
- **Why:** The WSL test VM drops about one in five loopback connections
  under full-suite load; the shared FFI default path produced
  `database is locked` between parallel files.
- **Check:** `test/oauth_service_test.dart`
- **Code:** `test/helpers/history_world.dart`

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
