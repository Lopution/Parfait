# Quality Guidelines

> Code quality standards for backend development.

---

## Overview


Core services keep ownership at the domain boundary and expose typed models,
repositories, and provider-managed resources. Quality evidence is collected
with `flutter analyze --no-pub`, focused tests, the full Flutter test suite,
and the native/plugin checks named by the owning spec. CI uses committed
lockfiles and does not treat a local-only build as release evidence.

---

## Forbidden Patterns

- Do not construct an HTTP client, database connection, or platform channel
  inline in a production consumer when an owning provider/factory exists.
- Do not move feature widgets into `lib/core/`, let core import `app` or
  `features`, or make a repository present UI feedback.
- Do not store request bodies, credentials, full API JSON, or arbitrary URLs
  in durable recovery/history records.
- Do not hand-edit generated bindings or lockfiles; use the package's
  generation or dependency workflow.

---

## Required Patterns

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

When a guard is removed, delete the tests that froze the wrong behaviour in
the same commit (no leftover `skip:`). The full rule lives in
`.trellis/spec/frontend/quality-guidelines.md`
（删除 guard 时，同步删除固化该错误行为的测试）.

---

## Code Review Checklist

- Classify API, parser, storage, and platform failures at their owning
  boundary and preserve the type through the controller state.
- Keep account, cancellation, cursor, and database ownership explicit in
  repository APIs and tests.
- Keep Android channel payloads and Rust/FRB versions synchronized with their
  executable contracts.
- Run the relevant focused tests before the full suite, and include the
  changed-layer analyzer/build evidence in review.
