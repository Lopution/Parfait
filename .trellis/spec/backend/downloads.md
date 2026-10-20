---
prefix: DL
applies_to:
  - lib/core/download/**
  - lib/features/settings/pages/download_*.dart
reviewed: 2026-10-12
---

# Downloads and recovery

## Contents

- [Ownership and recovery](#ownership-and-recovery)
- [Output and transport](#output-and-transport)

## Ownership and recovery

### DL-01 A download is a job owned by account and destination
- **Rule:** Every submission captures an immutable snapshot of account,
  destination, work, page and format; the recovery owner is
  `accountId + DownloadDestination.identity`, without the credential
  revision. A product submission needs a usable account. Owner checks run
  before output creation, before each write and while streaming.
- **Why:** A token refresh orphaned in-flight tasks; an account switch
  wrote into the old account's destination.
- **Check:** `test/download_recovery_test.dart` "recovery only exposes same-owner pending work as retryable" "legacy Pictures/Parfait destination migrates to the builtin owner"
- **Code:** `lib/core/download/download_manager.dart`, `lib/core/download/download_recovery.dart`

### DL-02 Recovery never starts work by itself
- **Rule:** On launch, only a record whose job, owner, account and
  destination match exactly is restored, as `retryable`; the user retries
  from the download tasks page. Anything else becomes a visible `orphaned`
  record. A crash seen in `finalizing` is `orphaned`, never retried.
  Records are deduplicated by `dedupeKey`, newest first.
- **Why:** Auto-resent downloads surprised users after a crash; a
  finalizing output may already be visible.
- **Check:** `test/download_recovery_test.dart` "finalizing recovery becomes orphaned instead of retrying post-process" "recovery keeps the newest record for one identity"
- **Code:** `lib/core/download/download_recovery.dart`

### DL-03 Pending rows are cleaned only by their exact owner
- **Rule:** Pending MediaStore rows and SAF documents are cleaned only
  through an exact owner match; unknown rows are reported, never deleted.
  Cleanup failures stay visible.
- **Why:** A blind cleanup would delete files other apps or older versions
  were writing.
- **Check:** `test/download_recovery_test.dart` "restart scan cleans only recorded owners and reports unknown rows" "recovery reports a platform owner-cleanup refusal"
- **Code:** `lib/core/download/download_recovery.dart`

### DL-04 Job and group ids are unique across launches
- **Rule:** Job and group ids carry a random per-launch token next to the
  in-process sequence. A task belongs to the group of its submission; the
  last child leaving removes the group; a retry after an account change
  never joins the old group.
- **Why:** Sequence-only ids made every launch's first download join the
  same recovered group.
- **Check:** `test/download_recovery_test.dart` "a group made after a restart never joins a recovered one", `test/download_manager_test.dart` "replacing a completed group task removes the old group"
- **Code:** `lib/core/download/download_manager.dart`

### DL-05 The file name is frozen at submission
- **Rule:** The snapshot freezes the resolved display name, re-validated on
  decode; a retry writes the stored name instead of recomputing it. Display
  fields (`thumbnailUrl`, `totalPages`) are presentation only: never in
  `dedupeKey` or owner checks, and records without them still recover.
- **Why:** A restored request lacks template inputs (`{author_id}`, `{w}`,
  `{h}`), so a recomputed name came out with empty segments.
- **Check:** `test/download_recovery_test.dart` "retrying a recovered task writes the stored name" "a stored name with traversal segments is rejected" "records without display fields still recover"
- **Code:** `lib/core/download/download_recovery.dart`

## Output and transport

### DL-06 Output becomes visible exactly once
- **Rule:** Writes go to a pending row; finalize makes it visible once,
  and a second finalize throws. Abort and cleanup are idempotent and never
  throw through cleanup. A sink failure aborts and never finalizes.
- **Why:** Duplicate callbacks published half-written files.
- **Check:** `test/download_manager_test.dart` "finalize makes visible exactly once; second finalize throws" "abort is idempotent and never throws through cleanup" "sink failures abort the pending item, never finalize"
- **Code:** `lib/core/download/download_sink.dart`

### DL-07 Download URLs stay on allowlisted HTTPS hosts
- **Rule:** Download URLs must be HTTPS on an allowlisted host without
  ports or userinfo; redirects follow only to allowlisted HTTPS hosts.
- **Why:** A redirect to another host would leak the Referer and fetch
  arbitrary content into the gallery.
- **Check:** `test/download_manager_test.dart` "URL validation rejects foreign hosts, ports and userinfo (R7)" "refuses cross-host redirects and URLs outside the policy"
- **Code:** `lib/core/download/pixiv_download_transport.dart`

### DL-08 Resume trusts only a matching 206
- **Rule:** A retry with a stored anchor sends `Range` and appends only on
  a 206. A 200 discards the stale bytes and starts fresh; a 416 or a
  platform byte count that differs from the anchor discards the anchor.
  Cancel deletes the output even on a resumable sink.
- **Why:** Appending to a mismatched file produced corrupt images.
- **Check:** `test/download_resume_test.dart` "retry sends Range and appends on 206" "416 discards the anchor and reopens without Range" "mismatched platform byte count discards anchor, no Range sent"
- **Code:** `lib/core/download/download_manager.dart`
