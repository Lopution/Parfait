# Quality Guidelines

> Code quality standards for backend development.

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

## Forbidden Patterns

<!-- Patterns that should never be used and why -->

(To be filled by the team)

---

## Required Patterns

<!-- Patterns that must always be used -->

### Secrets stay out of every serialized surface

Established by task `09-01-comment-translation` (translation credentials) and the
account credential store; apply the same shape to any new secret.

- Each secret family gets its own secure-storage namespace and store class:
  account tokens `replica.credentials.v1.` (`lib/core/auth/credential_store.dart`),
  translation credentials `replica.translation.v1.`
  (`lib/core/comments/translation_credentials.dart`). Never share a namespace or
  a store between families.
- `AppSettings` serializes selectors only (e.g. `translateIndex`), never the
  secret. Secrets are read from the store per request (`readBaidu` / `readLlm`
  inside `translate`), not cached in providers or widgets, so clearing them takes
  effect on the next call without a restart.
- The account-transfer envelope carries exactly
  `version / payloadType / payload{accountId, userId, credential{accessToken,
  refreshToken[, cookie]}} / checksum`; adding anything else to it requires a
  design decision, and `test/account_transfer_service_test.dart` pins the key sets.
- `toString` on a credentials class redacts the secret (`secret: <redacted>`);
  no `debugPrint`/`print`/`log` of request bodies that carry credentials.
- Remote credentials go over HTTPS only (`http://` base URLs are rejected before
  any request is built).
- Tests for a new secret family must include: serialization excludes it, transfer
  envelope excludes it, `toString` excludes it, and "not configured" is reported
  once it is cleared.

---

## Testing Requirements

<!-- What level of testing is expected -->

(To be filled by the team)

---

## Code Review Checklist

<!-- What reviewers should check -->

(To be filled by the team)
