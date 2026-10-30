---
prefix: TEST
applies_to:
  - test/**
  - tool/test_shards.py
  - tool/test_budget.py
  - tool/test_budget.json
  - dart_test.yaml
reviewed: 2026-10-30
---

# Tests

## Contents

- [What a test proves](#what-a-test-proves)
- [Volume](#volume)
- [Test environment traps](#test-environment-traps)

## What a test proves

### TEST-01 A regression test fails on the defect and sits with its behaviour
- **Rule:** Before trusting a test written with a fix, restore the old
  implementation (`git show HEAD:<path>`), run the new cases and confirm
  the ones encoding the defect fail. The kept test is the case its
  behaviour was missing: a table row or a case beside that behaviour's
  tests, named after the behaviour, with the issue number, if any, in a
  comment. A new group only when the behaviour has no tests.
- **Why:** Regression tests passed for reasons unrelated to the bug. Cases
  named after incidents piled up apart from the behaviour they test, one
  per instance of the same defect.
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

### TEST-12 Refactors and optimisations add no tests
- **Rule:** A refactor or performance change keeps the existing tests and
  adds a case only for a contract a user can observe (a blurred cover
  never paints sharp first; an original nobody wants stops downloading).
  How it gets there (what builds in which frame, how far a cache grows,
  which widgets rebuild) is not asserted. A test that breaks on such a
  change while the behaviour still holds pinned the implementation:
  rewrite it against the behaviour. A broken behaviour is fixed in the
  code.
- **Why:** Optimisation commits pinned their mechanism in new cases, which
  the next optimisation had to rewrite.
- **Check:** manual
- **Code:** `test`

## Volume

### TEST-05 The suite stays within its budget
- **Rule:** User decision: `test/` holds at most `ratio` × `lib/` Dart code
  lines (`tool/test_budget.json`, 0.652; blank and comment lines excluded;
  `test/review/` and `test/fixtures/` not counted, nor the localizations
  `flutter gen-l10n` writes into `lib/l10n/`), so tests grow with the code
  but not faster. Only the user changes the ratio; an agent asks and
  never edits it without that consent. A change whose `test/` growth exceeds the
  ratio × its `lib/` growth (none when `lib/` shrinks) by more than
  `growth_warning` (400) code lines gets a CI warning, never a failure:
  table-drive or prune before adding more. A change that needs room makes
  it in this order: dedupe or table-drive repeated cases; drop UI tests of
  colour, spacing, order or copy; drop tests of removed code; drop a
  duplicated layer; prune under TEST-13. Coverage of core logic, fixed bugs
  and security is never given up for room. A UI change ships one or two tests of its key behaviour; layout,
  colour, spacing and copy are checked with review screenshots. No
  per-locale or per-variant copies of a case. Core logic (network,
  credentials, downloads, paging, parsing, persistence) and every fixed bug
  keep thorough coverage. A file over 1500 lines is split by feature, with
  shared fakes in `test/helpers/`. A test file is named after the `lib/`
  module it covers; a file of one or two cases joins its feature's file
  unless it is the only test of its module.
- **Why:** The suite doubled in a month, mostly with parameter assertions
  and duplicated layers; dozens of one-case files each cost a compile;
  test/lib rose from 0.41 to 0.81. Under a fixed 60,000-line cap the
  suite grew in step with `lib/` (about 0.55 test lines per new lib
  line) and met the cap again within a week; a ratio keeps the alarm for
  tests outgrowing the code without a wall every few days. The cap alone
  showed growth only at the wall; the warning shows it in the change that
  adds it (400 would have flagged about 4% of past PRs). Generated
  localizations grow with every string, not with the code tests cover.
- **Check:** `tool/test_budget.py`, `test/architecture/test_hygiene_test.dart` "test files stay under"
- **Code:** `test`

### TEST-13 A passing test may be pruned; a failing one is never weakened
- **Rule:** User decision: a failing test is never deleted, skipped or
  loosened to get green; the code is fixed, or the test changes in the
  commit that changes or removes the behaviour it asserts (TEST-04). A
  passing test of a behaviour that stays may be pruned when the confidence
  it gives is kept: another case or a scan covers the same condition, or
  it repeats another case. A merge keeps each case's starting state as well
  as its checks: cases that start from different states test different
  conditions. A test that pins implementation (TEST-03,
  TEST-12) is rewritten against the behaviour it guards, or pruned when
  that behaviour is covered or not observable by a user. Prunes get their
  own commit whose message names, for each, the reason and the covering
  case, or TEST-12 for a mechanism; the PR lists them. A change that edits
  a test file also prunes that file's redundant cases, and no other
  file's.
- **Why:** The suite only grew: fixes and optimisations never removed a
  case, and removals came only from deleted code or slimming passes.
  Agents add tests readily, and deleting a failing test is how an agent
  cheats; whether the test was failing separates pruning from cheating.
  Two merges in a slimming pass kept every check yet lost the condition:
  one re-tapped a tab after a switch instead of the tab the page opened on,
  the other sent a reply instead of a top-level comment.
- **Check:** manual
- **Code:** `test`

### TEST-14 A recurring defect class becomes a scan
- **Rule:** When a defect class is fixed for the second or third time, a
  scan under `test/architecture/` fails on new instances, the existing
  instances are fixed, and the per-instance cases fold into the scan under
  TEST-13. A scan that cannot avoid flagging correct code is not added;
  the cases stay.
- **Why:** Each instance of a class got its own regression test while
  nothing stopped the next instance. Stale async results (a page gone, an
  account switched, a retry overtaking) stay cases: a scan inside one
  function sees about half of the past page-gone instances and flagged only
  correct code on the current tree, and a late write after an account
  switch or an overtaking retry has no syntactic mark.
- **Check:** manual
- **Code:** `test/architecture`

### TEST-10 A test double is defined once
- **Rule:** Look in `test/helpers/` before writing a fake, stub, recorder,
  fixture server, scripted response, wait loop or widget harness. One that a
  second file needs moves to `test/helpers/` and both import it; a small
  difference becomes a parameter of the shared one. A double that behaves
  differently gets a name that says how (`_ThrowAfterWriteSink`, not a
  second `_FailingSink`) and a body that is mostly its own: a class sharing
  80% of its lines with a class in another file is a copy, whatever its
  name.
- **Why:** Eight copies of one account stub drifted apart, and a fix to
  one copy left the others asserting the old behaviour. Renamed copies
  (`_Resolver`, `_ScriptedResolver`, `StubResolver` beside `FakeResolver`)
  passed a name-only check; a third of the suite sat outside any case.
  Inline response scripts, polling loops and app scaffolds made the
  average case about 31 lines.
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
  gives each test file its own default databases directory. Under
  `flutter test` an app database opened at its default path uses the
  no-isolate FFI factory and an in-memory database of its own; a test that
  needs the file, as one that reads or writes history does, injects the
  database with a per-test `databasePath`. A case that owns a database its
  pages open closes it in its body, after the pages are gone.
- **Why:** The WSL test VM drops about one in five loopback connections
  under full-suite load. Pages that open an app database at its default
  path shared one FFI directory across parallel files and failed with
  `database is locked` whenever CI sharding put two of them together.
  Opened by a page inside `testWidgets`, the isolate's replies never
  reached the case, and the isolate went on creating the file after it:
  the file's tear-down failed to delete the directory (`Directory not
  empty`). The sqflite factory hands every opener of `:memory:` the first
  one's database unless `singleInstance` is off, so the second in-memory
  database of a case had none of its tables. Awaited in a tear-down, out
  of the fake-async zone that opened the database, a close never returned.
- **Check:** `test/oauth_service_test.dart`,
  `test/architecture/test_hygiene_test.dart` "socket tests carry the socket tag",
  `test/watch_later_store_test.dart` "default watch-later and history databases answer in a widget test",
  `test/navigation_restoration_test.dart` "a restored pager opens the work it settled on"
- **Code:** `test/flutter_test_config.dart`,
  `test/helpers/history_world.dart`, `dart_test.yaml`,
  `lib/core/watchlater/watch_later_database.dart`,
  `lib/core/history/history_database.dart`,
  `lib/core/paging/feed_database.dart`,
  `lib/core/localnovel/local_novel_database.dart`

### TEST-08 Riverpod providers that dispose or retry
- **Rule:** Before awaiting an `autoDispose` provider's `.future`, hold a
  listener (`container.listen`). The same trap exists in pages: subscribe
  (`ref.watch` or `ref.listenManual`) before `ref.read(...notifier).load()`.
  A failing `AsyncNotifier.build` retries forever, so assert its
  `AsyncError` state instead of awaiting `.future`. A test that pumps a
  second container keys its `UncontrolledProviderScope` by the container,
  as the helpers do.
- **Why:** A zero-listener notifier was disposed mid-load and left a
  permanent spinner; awaiting a failing build hung until dispose. A scope
  registers with its container only at mount: the second container's
  disposals fell back to a timer still pending when the test ended.
- **Check:** manual
- **Code:** `lib/features/profile/profile_edit_page.dart`, `test/helpers/localized_app.dart`

### TEST-09 Widget test harness traps
- **Rule:** Import `package:material_ui/material_ui.dart`, not
  `flutter/material.dart`, and pump its `MaterialApp` with
  `promptHostBuilder` when prompts show. Non-latin-1 HTTP fixtures use
  `http.Response.bytes(utf8.encode(...))` with a charset. Pages building
  `InAppWebView` set a fake `InAppWebViewPlatform.instance`. Read
  `SystemChrome.latestStyle` only after a `pump`. Record haptics with
  `recordHaptics()`, not a platform-channel mock. Wrap motion subjects in
  `MotionScope(reduce:, speed:)`. Every case starts with empty in-memory
  preferences from its directory's `flutter_test_config.dart`; no file
  adds its own empty reset. Accounts and settings go through the app's
  repositories (`seedAccounts`, `seedSettings`, `stored…()`), other values
  through `installMemoryPreferences(data)`; a slow or full disk is
  `GatedPreferences`.
- **Why:** Each trap made a correct implementation look broken: finders
  matched nothing, fixtures threw on construction, styles were read before
  the frame applied them. The missing preferences plugin was worked around
  by 146 copies of one reset in `setUp` blocks and world builders.
  Repository fakes held states no store can hold (a templateless custom
  naming rule, a bare `ja` tag).
- **Check:** manual
- **Code:** `test/flutter_test_config.dart`, `test/helpers/test_preferences.dart`, `test/helpers/fake_account.dart`, `test/helpers/fake_settings.dart`, `test/helpers/prompt_host.dart`, `test/helpers/recording_haptics.dart`

### TEST-11 Waits use fake time
- **Rule:** No `sleep`. Advance time with `fakeAsync` or
  `tester.pump(duration)`. A real-clock `Future.delayed` belongs only
  inside `tester.runAsync` for real IO, in a bounded loop. The loop ends on
  a condition, not a round count: database calls a widget made in the fake
  zone advance one round trip per pump, so wait for a probe queued behind
  them on the database lock (`settleHistory`). Condition waits come from
  `test/helpers/waits.dart` (`turnUntil`, `pollUntil`, `pumpUntil`,
  `pumpIoUntil`), which fail when the condition never holds.
- **Why:** A real wait makes a case slow on a fast machine and flaky on a
  loaded one, and `sleep` also blocks the isolate the test drives. Two
  fixed rounds left a history query waiting for the lock on a loaded CI
  runner, and its lock-warning timer outlived the test. Local wait loops
  that gave up silently hid a condition that never held: a download test
  waited for progress the throttle never showed.
- **Check:** `test/architecture/test_hygiene_test.dart` "no real sleeps"
- **Code:** `test/helpers/waits.dart`, `test/helpers/history_world.dart`

### TEST-15 Widget tests fail on what they leave undisposed
- **Rule:** Every test file tracks leaks (`enableLeakTracking()` in each
  `testExecutable`): a file fails when a widget test leaves a notifier,
  controller, layer, image frame (`ImageInfo`) or animation undisposed. A
  leak from `lib/` is fixed in `lib/` (QUAL-06); a test disposes what it
  creates, through `addTearDown` or a helper that does (`pixivRouter`,
  `stalledImageWorker`). A leak nobody here can fix is ignored by class,
  with its reason: in `test/helpers/leak_tracking.dart` for one that comes
  from a package or Flutter everywhere or lives as long as the app, at the
  top of a file's `main` for one only that file meets
  (`ignoreOctoImageFades`, the modal sheet's drag curve, the `paints`
  matcher's layers). Each case ends with an empty image cache, live
  entries included: loads the fakes never answer stay pending, so a
  listener left on an image stream is not caught. A bare `ui.Image` is not
  tracked either: Flutter drops a frame whose decode outlives its
  completer, in whichever case runs then, so one the app makes itself
  (`toImageSync`) has only its owner's `dispose`.
- **Why:** Nothing reported an undisposed object. The image worker never
  disposed its load count, the novel reader's bars built an animation on
  every build, the viewer's zoom curve and every page's removal controller
  outlived their pages, and the image progress listener dropped the frame
  it was handed without disposing it. Filtering out objects created by
  test helpers needs a creation stack for every tracked object, more than
  the full suite's 8G memory cap holds. A dropped frame fails whichever
  case it lands in, which depends on the machine's speed.
- **Check:** `test/flutter_test_config.dart` "enableLeakTracking();", `test/locale_layout/flutter_test_config.dart` "enableLeakTracking();", `test/helpers/leak_tracking.dart` "LeakTesting.enable" "clearLiveImages"
- **Code:** `test/helpers/leak_tracking.dart`, `test/flutter_test_config.dart`, `test/locale_layout/flutter_test_config.dart`
