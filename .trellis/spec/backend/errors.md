---
prefix: ERR
applies_to:
  - lib/core/network/api_error.dart
  - lib/core/entity/json_read.dart
  - lib/core/errors/**
  - lib/core/logging/**
  - lib/core/log.dart
  - lib/app/widgets/errors/**
  - lib/l10n/*.arb
  - lib/features/settings/pages/download_task_presentation.dart
reviewed: 2026-10-12
---

# Errors, user-facing failure copy and logging

### ERR-01 Failures keep their type; malformed data is never an empty success
- **Rule:** Repositories classify transport, HTTP, auth, rate-limit and
  parse failures into the sealed `ApiError` family (or their domain
  exception) at the boundary that knows the cause; controllers keep that
  type in their state. A malformed payload, cursor or stored record raises
  `ApiParseError` or the storage exception, never an empty list or default
  entity. Required wire fields go through the `require*` readers in
  `json_read.dart`.
- **Why:** An empty feed on a parse failure reads as "no works" and hides
  an API change.
- **Check:** `test/illust_store_test.dart` "page parse errors surface as ApiParseError, not empty success", `test/related_illust_repository_test.dart` "malformed envelope raises ApiParseError"
- **Code:** `lib/core/network/api_error.dart`, `lib/core/entity/json_read.dart`

### ERR-02 Users never see raw exception text
- **Rule:** Visible failure copy is a localized category or a hand-written
  message; the technical text lives behind `ErrorDetails` or in `CrashLog`.
  The scanner's allowlist holds only surfaces whose purpose is diagnostic.
- **Why:** Raw `toString()` output leaked hosts, status bodies and Dart
  type names into SnackBars.
- **Check:** `test/architecture/raw_error_text_test.dart` "no raw error text reaches user-facing surfaces"
- **Code:** `lib/app/widgets/errors/error_details.dart`

### ERR-03 One classifier, one error SnackBar
- **Rule:** `categorizeError` and `categorizeDownloadFailure` in
  `error_category.dart` are the only classification; call sites never
  re-classify or branch on `toString()` substrings. Error SnackBars go
  through `showErrorSnackBar`, which records the original error to
  `CrashLog` with `CrashLog.report` (its header reads `reported: <action>`,
  apart from crashes) and shows `action: category`.
- **Why:** Per-page classification disagreed about the same failure and
  left no durable trace for support. Unlabelled, five 503 SnackBars read
  as five crashes in a user's crash.log (10-26).
- **Check:** `test/error_category_test.dart` "categorizeError puts each error in its category", `test/error_details_test.dart` "shows action + category and records the raw error"
- **Code:** `lib/core/errors/error_category.dart`, `lib/core/logging/crash_log.dart`

### ERR-04 Download rows read their failure from `failureKind`
- **Rule:** A failed download's visible copy comes from `failureKind`, not
  the persisted raw `error` string. Canceled and paused tasks are not
  failures and never get failure styling. A `retryable` task with no kind
  was interrupted by process death and shows `downloadFailureInterrupted`.
- **Why:** Interrupted tasks showed "unknown error" and cancelled ones
  looked failed.
- **Check:** `test/download_task_presentation_test.dart` "every failureKind maps to its localized reason"
- **Code:** `lib/features/settings/pages/download_task_presentation.dart`, `lib/features/settings/pages/download_tasks_page.dart`

### ERR-05 Localized copy never interpolates a diagnostic
- **Rule:** An arb message takes no `{error}`/`{reason}`-style text
  placeholder carrying diagnostics; pass those to `ErrorDetails` or
  `CrashLog`. Any text placeholder is allow-listed with a reason. Every arb
  key is defined once. When a headline already names the problem, omit the
  category sentence under it.
- **Why:** Placeholders smuggled raw errors past ERR-02; a duplicated key
  silently overrides the first; a redundant "unknown error" line reads as
  a second failure.
- **Check:** `test/architecture/l10n_placeholders_test.dart` "text placeholders are allow-listed with a reason" "arb files define every key once"
- **Code:** `lib/l10n`

### ERR-06 Logs carry metadata, never secrets
- **Rule:** Diagnostics go through `log()` from `lib/core/log.dart` (a
  no-op in release) with an owner prefix; no new logger and no direct
  `print`/`debugPrint`. Never log tokens, cookies, secure-storage payloads,
  translation credentials, request or response bodies, transfer envelopes
  or URLs carrying credentials; log host, status, error type and outcome.
- **Why:** Debug output is pasted into bug reports.
- **Check:** `test/architecture/feedback_channels_test.dart` "diagnostics go through log()"; the secrets part is manual.
- **Code:** `lib/core/log.dart`
