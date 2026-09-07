# Quality Guidelines

> Code quality standards for frontend development.

---

## Overview

<!--
Document your project's quality standards here.

Questions to answer:
- What patterns are forbidden?
- What linting rules do you enforce?
- What are your testing requirements?
- What code review standards apply?
-->

(To be filled by the team)

---

## Build Toolchain (Flutter / Android)

- Flutter SDK lives at `/opt/flutter-3.47.2`; Android SDK at `/opt/android-sdk`. Run flutter via `export PATH=/opt/flutter-3.47.2/bin:$PATH`. `/opt/flutter-3.47.0` remains as the rollback SDK.
- The flutter tool regenerates `android/local.properties` (including `sdk.dir`) from its **global** config (`flutter config --android-sdk ...`), not from the file. If builds fail with `LicenceNotAcceptedException` or an unexpected SDK path like `/usr/lib/android-sdk`, fix the global flutter config first — editing `local.properties` alone will be silently overwritten on the next `flutter` invocation.
- Debian's `/usr/lib/android-sdk` exists on this machine but is NOT the project SDK; never let Gradle resolve to it.
- `flutter` prints a root-user warning under this environment; it is expected and safe to continue.

## Forbidden Patterns

<!-- Patterns that should never be used and why -->

- **A second state machine beside a framework one.** Do not re-derive scroll,
  gesture, or animation lifecycle state from notifications when the framework
  already owns it. A threshold, an "is the pointer down" judgement, or a
  progress value must exist in exactly one place. Two measurements of the same
  physical quantity will disagree, and every disagreement is a user-visible
  defect (09-01 U1: pointer-up overscroll re-armed a pull, a wrapper vetoed a
  refresh the framework had already triggered, an indicator stuck on screen —
  all one root cause).
- **Layering a patch on an erroneous guard.** When a guard blocks correct
  behavior, delete or relax it. Do not add a condition in front of it.

---

## Required Patterns

<!-- Patterns that must always be used -->

- **Specs state observable outcomes, not implementation instructions.** Write
  what the user must be able to see happen; do not write which notification to
  listen to or which field to read. A spec containing "how" freezes the
  implementation: 09-01 U1's spec mandated the exact code that caused the bug,
  so fixing it read as violating the spec.
- **When real behavior falsifies a spec clause, revise the spec in the same
  commit as the code.** Never leave a contract that the shipped code
  contradicts, and never keep a falsified implementation just to stay
  spec-compliant.
- **Exhaust the framework's primitives before scaling down a requirement.**
  "The framework cannot do this" is a claim about the primitive you happened to
  reach for, not about the framework. Physics, gesture arenas, layout, and
  status callbacks are separate primitives; a requirement that is impossible
  under one is often the natural behavior of another. Requirements live in the
  PRD and designs live in the design doc — when a design cannot deliver a
  requirement, the design is what changes.
- **"Do not rebuild the framework's state machine" is not "do not read the
  framework's state".** Mirroring an authoritative value (scroll metrics, a
  status callback) to render from creates no second source of truth.
  Accumulating your own copy of it, deciding a threshold from it, or overriding
  the framework's decision does. Conflating the two blocks the only workable
  solutions.

---

## Testing Requirements

<!-- What level of testing is expected -->

### Regression tests must be proven against the defect

A test written alongside a fix is unproven until it has been run against the
unfixed code. Temporarily restore the previous implementation (`git show
HEAD:<path>`), run the new cases, and confirm the ones that encode the defect
fail. Two 09-01 cases were validated this way; without it a regression test
can pass for reasons unrelated to the bug it claims to cover.

### Assert the terminal state, not only the trajectory

Gesture and animation tests must assert what is on screen after the
interaction ends, not just how things moved during it. "Indicator stuck on
screen" passed the old suite because every assertion stopped at the moment of
release.

### A test that cannot fail proves nothing

When a case depends on a condition being reached (an overscroll actually
occurring, a request actually being sent), assert that the condition happened.
Otherwise the case silently degrades into "nothing happened, so nothing broke".

Also check the case takes the same code path a user does. A pull-to-refresh
test that stops short of the arm threshold exercises a different framework
branch than any real pull, so it passes while the shipped behavior is broken.
When a threshold splits behavior in two, name which side the test is on.

### dart:io Loopback Flakiness (WSL environment gotcha)

**Problem**: this WSL/flutter-test VM drops ~20% of `dart:io` loopback connections under full-suite parallel load (verified with a raw HttpClient repro; see 08-26-download-manager-mediastore research). Any test that binds `127.0.0.1:0` or opens real sockets to loopback will intermittently fail or hang the whole-suite run even though single-file runs pass.

**Required pattern**: wrap socket-dependent test bodies in a 3-attempt retry helper (`tolerant()`), reset per-attempt state between attempts, and raise the per-test timeout above worst-case retries:

```dart
// Canonical implementations: test/download_manager_test.dart,
// test/oauth_service_test.dart ('token exchange' group).
Future<void> tolerant(Future<void> Function() body) async {
  Object? lastError;
  for (var attempt = 1; attempt <= 3; attempt++) {
    try {
      await body();
      return;
    } catch (error) {
      lastError = error;
      receivedBodies.clear();   // reset per-attempt state
      responseStatus = 200;
      service.discardSession();
    }
  }
  throw StateError('loopback still failing after retries: $lastError');
}
```

```dart
test('...', () async {
  await tolerant(() async { /* body */ });
}, timeout: const Timeout(Duration(minutes: 2)));
```

**Why retries and not weaker assertions**: deterministic logic failures still fail after all attempts, so retrying only absorbs environment noise without masking bugs. Do NOT delete real-socket integration coverage for this reason.

Symptoms to recognize: `TimeoutException after 0:00:30` from an unrelated-feeling test file while running `flutter test` (full suite); same test green when run alone. Default fix is this pattern, not rerolling the suite.

---

## Code Review Checklist

<!-- What reviewers should check -->

(To be filled by the team)
