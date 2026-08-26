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

(To be filled by the team)

---

## Code Review Checklist

<!-- What reviewers should check -->

(To be filled by the team)
