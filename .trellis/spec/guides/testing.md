---
prefix: TEST
applies_to:
  - test/**
  - tool/test_shards.py
  - tool/affected_tests.py
  - tool/test_budget.py
  - tool/test_budget.json
  - dart_test.yaml
reviewed: 2026-11-27
---

# Tests

## Contents

- [What a test proves](#what-a-test-proves)
- [Volume](#volume)
- [Test environment traps](#test-environment-traps)

## What a test proves

### TEST-01 A regression test fails on the defect and sits with its behaviour
- **Rule:** Confirm new regression cases fail against the old code (`git show <pre-fix-ref>:<path>`) before trusting them. Place each case beside the behaviour it belongs to (named for the behaviour, issue number in a comment); add a new group only when none exists.
- **Why:** Regression tests otherwise passed for unrelated reasons and piled up in incident-named grab bags.
- **Check:** manual
- **Code:** `test`

### TEST-02 Assert the end state and that the condition happened
- **Rule:** Gesture and animation tests assert the post-interaction on-screen state, verify triggering conditions actually occurred, and state which side of a threshold they exercise.
- **Why:** Assertions stopping at pointer-up missed stuck indicators and unexercised branches.
- **Check:** manual
- **Code:** `test`

### TEST-03 Assert observable behaviour, at the lowest layer
- **Rule:** Assert rendered output, semantics, navigation, and state changes—not constructor parameters (`tester.widget<T>(...).param`) unless the parameter is itself the contract. Cover each behaviour at the lowest layer that reproduces it (unit test for logic, widget test only for layout/interaction).
- **Why:** Parameter assertions break across refactors and widget tests cost more to run and maintain than unit tests.
- **Check:** manual
- **Code:** `test`

### TEST-04 Removing a guard removes the tests that froze it
- **Rule:** Delete tests encoding removed/relaxed behaviour in the same commit; never use `skip:`. Rewrite replaced implementations' tests in the same PR.
- **Why:** Skipped tests froze stale defects in the suite.
- **Check:** `test/architecture/layering_and_hygiene_test.dart` "no skipped cases"
- **Code:** `test`

### TEST-12 Refactors and optimisations add no tests
- **Rule:** Refactors and optimisations keep existing tests and add cases only for user-observable contracts, never internal frame/cache/rebuild mechanics. Rewrite mechanism-pinning tests against observable behaviour.
- **Why:** Mechanism-pinned cases forced churn on every subsequent optimisation.
- **Check:** manual
- **Code:** `test`

## Volume

### TEST-05 Each change keeps its tests in step with its code
- **Rule:** User decision: a change may add at most `ratio` x gross added `lib/` code lines plus `change_tolerance` `test/` code lines (`tool/test_budget.json`: 0.657, 150); exceeding fails CI. Using gross added `lib/` lines prevents refactors that delete duplicate `lib/` code from penalising needed tests. Every run prints test/lib (soft warning above `trend_warning` 0.68), unit vs `testWidgets` share, and unrecorded `tool/test_durations.json` files. Only the user changes budget numbers. Counted lines exclude blanks, comments, `test/review/`, `test/fixtures/`, and generated `lib/l10n/`. Make room by deduplicating, dropping styling/copy/removed-code/duplicate-layer tests, and pruning under TEST-13—never by sacrificing core logic, bug-fix, or security coverage. Keep test files <= 1500 lines, named after the `lib/` module (never roadmap phases like `phase*`, `matrix_gate`, `p0_p1`, or `*_audit`), and fold 1–2 case fragments into their feature suite.
- **Why:** Unchecked widget/parameter tests doubled the suite and bloated compile times; per-change gross-added gating preserves discipline without punishing code cleanup.
- **Check:** `tool/test_budget.py`, `test/architecture/layering_and_hygiene_test.dart` "test files stay under" "no roadmap-phase test filenames"
- **Code:** `test`

### TEST-13 A passing test may be pruned; a failing one is never weakened
- **Rule:** User decision: never delete, skip, or loosen a failing test to turn green—fix the code or update the test with an intentional behaviour change (TEST-04). Passing tests may be pruned only when coverage is preserved by another case or scan (preserving distinct starting states when merging) or when pinning unobservable implementation (TEST-03/TEST-12). Document each prune's reason and covering case/rule in its commit and PR.
- **Why:** Distinguishes disciplined suite slimming from weakening tests to hide regressions.
- **Check:** manual
- **Code:** `test`

### TEST-14 A recurring defect class becomes a scan
- **Rule:** On a defect class's second or third occurrence, add a static scan under `test/architecture/` (when it can avoid false positives), fix existing instances, and fold per-instance tests under TEST-13.
- **Why:** Per-instance tests did not prevent new instances of structural mistakes.
- **Check:** manual
- **Code:** `test/architecture`

### TEST-10 A test double stands at a boundary and is defined once
- **Rule:** Doubles stand in only for external boundaries (network, platform channels, keystore, clock); app repositories run real (App API via `PixivApi` routes checking HTTP method via `appApiTakes`). Shared doubles/helpers live in `test/helpers/` with distinct names and bodies (< 80% line overlap with any other double).
- **Why:** Copied stubs drifted apart and repository fakes hid real endpoint contracts and HTTP method bugs.
- **Check:** `test/architecture/layering_and_hygiene_test.dart` "each test double is defined once" "no test double is copied into a second file" "no test double stands in for an app repository"
- **Code:** `test/helpers`

## Test environment traps

### TEST-06 CI shards whole files; two-tier PR vs Nightly matrix; local gate resolves the Dart import graph
- **Rule:** CI shards whole PR-tier `*_test.dart` files (excluding file-level `@Tags(['matrix'])`) via `tool/test_shards.py` and runs `-x matrix`, keeping core `ru/compact` layout checks, core `zh/regular` route smokes, and router coverage on every PR. Full `matrix` runs in `.github/workflows/nightly-matrix.yml` nightly, on demand, and on PRs touching `lib/l10n/**`, `lib/app/navigation/route*.dart`, `lib/app/theme/**`, `test/locale_layout/**`, `test/helpers/locale_layout.dart`, `test/helpers/route_smoke.dart`, `test/review/**`, `dart_test.yaml`, or `.github/workflows/nightly-matrix.yml`. Real-process OS E2E runs Linux Xvfb smoke in `.github/workflows/linux.yml` and path-filtered Android KVM AVD smoke plus nightly full OS E2E in `.github/workflows/os-e2e.yml`, while `tool/dev_workbench/verify_catalog.py` checks the 3D coverage matrix in `analyze` and `tool/gate.sh`. `tool/test_shards.py --check` warns above 10 unrecorded files in `tool/test_durations.json` and fails above 20. `dev` pushes run fast affected tests; `main` relies on the strict PR gate. Locally `tool/gate.sh` uses `tool/affected_tests.py` (tracing `import`, `export`, `part`/`part of`, subdirectory `flutter_test_config.dart`, `.arb`, `assets/icon.ttf`, and `test/fixtures/**`, skipping Dart on pure docs/tooling diffs) under `GATE_TEST_CONCURRENCY` (default 4 under 4G, 6 under 8G); `--fast` skips fan-out, `--full` runs `-x matrix`, `--matrix` runs `-t matrix`.
- **Why:** `--total-shards` recompiled the whole suite per shard; naive grep missed `part of`/helper edges; running 700+ matrix cells on unrelated PRs wasted CI; uncapped `-j` caused silent `frontend_server` OOMs.
- **Check:** `tool/test_shards.py`, `tool/affected_tests.py`, `tool/dev_workbench/verify_catalog.py`
- **Code:** `tool/test_shards.py`, `tool/affected_tests.py`, `tool/dev_workbench/verify_catalog.py`, `tool/gate.sh`, `.github/workflows/ci.yml`, `.github/workflows/nightly-matrix.yml`, `.github/workflows/os-e2e.yml`, `dart_test.yaml`

### TEST-07 Loopback sockets retry; databases get their own path
- **Rule:** Tests binding/connecting `127.0.0.1` wrap bodies in three-attempt `tolerant()` with raised timeout and file-level `@Tags(['socket'])`. Under `flutter test`, default app databases use `databaseFactoryFfiNoIsolate` with isolated `:memory:` (`singleInstance: false`); disk-persistence tests inject a unique per-test `databasePath` and close databases before teardown.
- **Why:** WSL drops loopback sockets under load; shared FFI directories caused `database is locked`; isolate-backed SQLite inside `testWidgets` deadlocked or outlived teardown.
- **Check:** `test/oauth_service_test.dart` "exact pixiv://account?code=... is accepted", `test/architecture/layering_and_hygiene_test.dart` "socket tests carry the socket tag" "no raw databaseFactoryFfi in widget tests", `test/watch_later_store_test.dart` "default watch-later and history databases answer in a widget test", `test/navigation_restoration_test.dart` "a restored pager opens the work it settled on"
- **Code:** `test/flutter_test_config.dart`, `test/helpers/history_world.dart`, `dart_test.yaml`, `lib/core/watchlater/watch_later_database.dart`, `lib/core/history/history_database.dart`, `lib/core/paging/feed_database.dart`, `lib/core/localnovel/local_novel_database.dart`

### TEST-08 Riverpod providers that dispose or retry
- **Rule:** Hold a listener (`container.listen` / `ref.watch` / `ref.listenManual`) before awaiting an `autoDispose` provider's `.future`. Assert `AsyncError` rather than awaiting `.future` on failing `AsyncNotifier.build` (which retries indefinitely). Key `UncontrolledProviderScope` by its container when pumping a second container.
- **Why:** Zero-listener notifiers disposed mid-load, failing builds hung until dispose, and unkeyed scopes leaked disposal timers.
- **Check:** manual
- **Code:** `lib/features/profile/profile_edit_page.dart`, `test/helpers/localized_app.dart`

### TEST-09 Widget test harness traps
- **Rule:** Import `package:material_ui/material_ui.dart` (not `flutter/material.dart`); include `promptHostBuilder` when prompts show; use `http.Response.bytes(utf8.encode(...))` for non-Latin-1 fixtures; fake `InAppWebViewPlatform.instance` for WebView pages; read `SystemChrome.latestStyle` after `pump`; use `recordHaptics()` and `MotionScope(reduce:, speed:)`. Rely on `flutter_test_config.dart`'s empty in-memory preferences (never reset per file); seed via `seedAccounts`, `seedSettings`, `installMemoryPreferences`, or `installPreferencesForTest`.
- **Why:** Bypassing these helpers produced silent finder misses, encoding crashes, duplicate preference resets, and impossible repository states.
- **Check:** `test/architecture/layering_and_hygiene_test.dart` "no file sets empty preferences of its own"
- **Code:** `test/flutter_test_config.dart`, `test/helpers/test_preferences.dart`, `test/helpers/fake_account.dart`, `test/helpers/fake_settings.dart`, `test/helpers/prompt_host.dart`, `test/helpers/recording_haptics.dart`

### TEST-11 Waits use fake time
- **Rule:** Never call `sleep`; advance time with `fakeAsync` or `tester.pump(duration)`. Real-clock `Future.delayed` belongs only inside `tester.runAsync` for real IO in bounded condition-driven loops (`turnUntil`, `pollUntil`, `pumpUntil`, `pumpIoUntil`, `settleHistory`), failing loudly on timeout.
- **Why:** Fixed sleeps and round counts made tests slow locally, flaky on CI, and masked unmet conditions.
- **Check:** `test/architecture/layering_and_hygiene_test.dart` "no real sleeps" "no fixed-round Future.delayed polling loops"
- **Code:** `test/helpers/waits.dart`, `test/helpers/history_world.dart`

### TEST-15 Widget tests fail on what they leave undisposed
- **Rule:** The root and `locale_layout` `flutter_test_config.dart` files enable `enableLeakTracking()`, failing on undisposed notifiers, controllers, layers, `ImageInfo`, or animations (`architecture` and `review` configs intentionally bypass it). Fix `lib/` leaks in `lib/` (QUAL-06); dispose test-owned objects via `addTearDown`; document unavoidable framework/package exemptions in `test/helpers/leak_tracking.dart` or file top. Each case clears live image cache entries (`clearLiveImages`).
- **Why:** Catches leaked controllers, animations, and decoded frames automatically without high-memory creation stacks.
- **Check:** `test/flutter_test_config.dart` "enableLeakTracking();", `test/locale_layout/flutter_test_config.dart` "enableLeakTracking();", `test/helpers/leak_tracking.dart` "LeakTesting.enable" "clearLiveImages"
- **Code:** `test/helpers/leak_tracking.dart`, `test/flutter_test_config.dart`, `test/locale_layout/flutter_test_config.dart`
