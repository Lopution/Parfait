---
prefix: DL
applies_to:
  - lib/core/download/**
  - lib/features/settings/pages/download_*.dart
reviewed: 2026-10-26
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
  Cleanup failures stay visible. The production routing factory exposes
  MediaStore's pending-row scan and cleanup. Only a live resume anchor
  keeps its row; a canceled record's leftover anchor does not. A scan
  never touches the rows of jobs alive in the process, nor a superseded
  record's row whose marker a newer attempt carries; liveness is checked
  again after every await, since the user may retry mid-scan.
- **Why:** A blind cleanup would delete files other apps or older versions
  were writing. The routing factory once hid the scan, so no pending row
  was ever cleaned in the app.
- **Check:** `test/download_recovery_test.dart` "restart scan cleans only recorded owners and reports unknown rows" "recovery reports a platform owner-cleanup refusal", `test/download_sink_test.dart` "DestinationAwareSinkFactory exposes MediaStore pending rows", `test/download_resume_test.dart` "an anchored record keeps its pending row; plain and canceled ones do not" "a later scan leaves running and paused output alone" "a scan that a retry overtakes keeps its hands off"
- **Code:** `lib/core/download/download_recovery.dart`, `lib/core/download/download_sink.dart`

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
  Cancel deletes the output even on a resumable sink: a cancel before a
  pause lands wins over the pause, even while the pause (or a network
  failure) is already keeping the bytes, and cancelling a paused task
  deletes its kept bytes. Disposing the manager is no cancel: a paused
  task stays retryable with its bytes.
- **Why:** Appending to a mismatched file produced corrupt images. A
  cancel racing a pause kept the bytes and left the task stuck.
- **Check:** `test/download_resume_test.dart` "retry sends Range and appends on 206" "416 discards the anchor and reopens without Range" "mismatched platform byte count discards anchor, no Range sent" "still deletes output on a resumable sink" "a cancel while a pause keeps the bytes still deletes them" "a cancel during a network failure still deletes the bytes" "a paused task outlives its manager" "cancelling a paused task deletes its kept bytes"
- **Code:** `lib/core/download/download_manager.dart`

### DL-09 Kept output keeps its first owner marker
- **Rule:** An attempt that takes over kept output (a retry, or a new
  submission replacing a terminal one) uses the previous attempt's owner
  marker with its own job id; the platform reopens a pending row only
  under the marker it was created with. Only an attempt with the same
  account and destination takes it over; any other starts a new file and
  the old bytes are dropped. An attempt opens its output only after every
  pending drop in the process has finished, a rebuilt manager's included.
- **Why:** A retry minted a new marker, MediaStore refused the resume, and
  every resumed download restarted from zero. Taking over across accounts
  would write into the old account's album. A desktop `.part` file is
  named after the download, so a late drop deleted the new attempt's file.
- **Check:** `test/download_resume_test.dart` "retry sends Range and appends on 206" "network failure preserves bytes; retry resumes" "a retry under another account starts a new file" "a new manager waits for the old one"
- **Code:** `lib/core/download/download_manager.dart`
