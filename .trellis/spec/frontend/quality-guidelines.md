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

- Flutter SDK lives at `/opt/flutter-3.47.0`; Android SDK at `/opt/android-sdk`. Run flutter via `export PATH=/opt/flutter-3.47.0/bin:$PATH`.
- The flutter tool regenerates `android/local.properties` (including `sdk.dir`) from its **global** config (`flutter config --android-sdk ...`), not from the file. If builds fail with `LicenceNotAcceptedException` or an unexpected SDK path like `/usr/lib/android-sdk`, fix the global flutter config first — editing `local.properties` alone will be silently overwritten on the next `flutter` invocation.
- Debian's `/usr/lib/android-sdk` exists on this machine but is NOT the project SDK; never let Gradle resolve to it.
- `flutter` prints a root-user warning under this environment; it is expected and safe to continue.

## Forbidden Patterns

<!-- Patterns that should never be used and why -->

(To be filled by the team)

---

## Required Patterns

<!-- Patterns that must always be used -->

(To be filled by the team)

---

## Testing Requirements

<!-- What level of testing is expected -->

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
