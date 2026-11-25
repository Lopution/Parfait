---
prefix: DL
applies_to:
  - lib/core/download/**
  - lib/features/settings/pages/download_*.dart
reviewed: 2026-11-25
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
  Records are deduplicated by `dedupeKey`, newest first. Recovery writes
  coalesce per microtask via `DownloadPersistenceCoalescer`
  (`upsertAll`/`removeAll`), cache serialized record JSON per id in
  `PreferencesDownloadRecoveryStore`, batch multi-page `submitGroup`
  transitions, and schedule queued jobs in O(1) FIFO order.
- **Why:** Auto-resent downloads surprised users after a crash; a
  finalizing output may already be visible; per-job full-list JSON
  re-encoding caused quadratic I/O stalls on multi-page downloads.
- **Check:** `test/download_recovery_test.dart` "finalizing recovery becomes orphaned instead of retrying post-process" "recovery keeps the newest record for one identity" "submitGroup coalesces initial recovery persistence and change notifications"
- **Code:** `lib/core/download/download_recovery.dart`, `lib/core/download/download_manager.dart`

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

### DL-10 Owner ids fit the platform marker
- **Rule:** Every output owner id matches
  `DownloadOutputOwner.idPattern` (`[A-Za-z0-9_.-]{1,128}`), the ids
  Android's `MediaStoreChannel.beginPending` accepts. `MemorySinkFactory`
  refuses any other, so a producer's id is checked by its own tests.
- **Why:** The caption sidecar's `caption:<id>` was refused by MediaStore;
  the Dart fakes accepted it.
- **Check:** `test/caption_exporter_test.dart` "writes <stem>.txt with the info header"
- **Code:** `lib/core/download/download_recovery.dart`, `lib/core/download/download_sink.dart`

### DL-11 A caption goes only where a text file fits
- **Rule:** On Android a caption sidecar is written only to a folder (SAF)
  destination (`captionFits`): an album is a MediaStore image collection,
  which refuses a text file and keeps non-media files out of `Pictures/`.
  While an album is the destination the caption switch is greyed out and
  says why; the stored choice comes back with a folder.
- **Why:** With an album, every caption export failed and the download
  reported an error.
- **Check:** `test/caption_exporter_test.dart` "on Android only a folder takes the caption", `test/download_settings_page_test.dart` "on Android an album greys the caption switch out"
- **Code:** `lib/core/download/caption_exporter.dart`, `lib/features/settings/pages/download_settings_page.dart`

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
- **Rule:** The snapshot freezes both the resolved display name and any
  relative subdirectory segments (`subdirectories`), re-validated on
  decode (rejecting traversal, separators, control chars, or Windows
  reserved names); a retry writes the stored name and subdirectories
  instead of recomputing them. `NamingRule.resolve` always guarantees
  the resolved filename ends with `.$ext` before trimming, so custom
  naming templates cannot drop or spoof the media extension, and
  optional zero-padding (`padPageNumbers`) pads `{page}`/`{page1}` to
  `totalPages` width and `{series_order}` to `seriesTotal` width.
  Display fields (`thumbnailUrl`, `totalPages`) are presentation only:
  never in `dedupeKey` or owner checks, and records without them still
  recover.
- **Why:** A restored request lacks template inputs (`{author_id}`, `{w}`,
  `{h}`, series order), so a recomputed name or folder chain came out
  with empty segments; a custom template omitting `{ext}` could write
  media bytes under an arbitrary extension such as `.apk` or `.exe`.
- **Check:** `test/download_recovery_test.dart` "retrying a recovered task writes the stored name" "a stored name with traversal segments is rejected" "records without display fields still recover" "recovery round-trips frozen subdirectories and rejects traversal segments", `test/caption_exporter_test.dart` "DownloadRequest.displayName consumes the metadata fields" "padPageNumbers pads page, page1, and series_order to total width" "IllustDownloadCoordinator resolves series metadata, subfolders, and caption routing"
- **Code:** `lib/core/download/download_recovery.dart`, `lib/core/download/download_subfolders.dart`, `lib/core/download/naming_rule.dart`, `lib/core/download/illust_download_coordinator.dart`

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

### DL-12 Desktop download filenames strip Windows/POSIX hazards
- **Rule:** Before opening a staged `.part` file or album subdirectory on
  desktop, sanitize every name segment with `sanitizeDesktopFileName`:
  replace `[<>:"/\\|?*\x00-\x1F]` with `_`, strip trailing dots/spaces,
  substitute `download` (or the default album fallback) for `.`/`..`/empty strings,
  and prefix Windows reserved device stems (`CON`, `PRN`, `AUX`, `NUL`,
  `COM1`–`COM9`, `LPT1`–`LPT9`, case-insensitive) with `_`.
- **Why:** Windows silently strips trailing dots/spaces and opens reserved
  device handles instead of regular files, failing or corrupting writes.
- **Check:** `test/windows_capability_test.dart` "sanitizeDesktopFileName handles reserved names, trailing dots/spaces, and control chars"
- **Code:** `lib/core/platform/desktop_file_sink.dart`

### DL-13 iOS Photo Library commits staged files explicitly
- **Rule:** On iOS (`supportsPhotoLibrary`), downloads stream into an
  isolated temporary `.part` file under a per-album, per-transfer directory
  and commit into `PHPhotoLibrary` via `parfait/ios_photos` (`saveImage`) on
  `finalize()`, cleaning staging files in a `finally` block; permission
  denials or native failures raise an error rather than faking success, and
  `download_manager_adapters` maps `ios_photo_permission_denied` -> `permission`,
  `ios_photo_no_space` -> `noSpace`, and remaining `ios_photo_*` codes ->
  `storage`. When an album name is passed, `IosPhotosBridge` requests
  `.readWrite` photo library authorization, serializes work on `albumQueue`,
  and splits asset creation (`PHAssetCreationRequest`) from named-album
  placement (`PHAssetCollectionChangeRequest`): asset creation runs for both
  `.authorized` and `.limited`, while album lookup/creation runs only under
  full `.authorized` access so `.limited` access saves cleanly into Recents
  instead of rolling back. `DownloadDestinationPage`
  hides the Android SAF folder option on iOS and uses desktop folder/subfolder
  copy on Windows/macOS/Linux. Because `file_selector_ios` requires non-empty
  Apple `uniformTypeIdentifiers` on every filtered `XTypeGroup` and does not
  implement `getDirectoryPath`, `DesktopDocumentPicker` and
  `DesktopReverseImageInputPlatform` supply UTIs, and iOS backup export (user
  decision) stages JSON in app temp storage and shares via `BackupShareExporter`
  (`share_plus` with `sharePositionOrigin`).
- **Why:** iOS does not expose a shared writable Pictures folder or MediaStore
  API; staging keeps chunked writes and resume anchors working without
  leaving half-written assets in the Photos library, splitting asset creation
  from album placement preserves named `"Parfait"` album organization under
  full access while preventing `.limited` permission rollbacks, explicit
  `ios_photo_*` classification surfaces actionable retry/permission feedback,
  and UTIs plus share-sheet export keep iOS import/export and image picking
  from throwing `ArgumentError` / `UnimplementedError`.
- **Check:** `test/windows_capability_test.dart` "IosPhotoLibraryMediaStoreSession stages chunks, commits via channel, and resumes detached .part"; `test/download_manager_test.dart` "a storage failure says what the user can do about it"; `test/settings_test.dart` "DownloadDestinationPage hides SAF on iOS and shows desktop folder copy and macOS bookmark label"; `test/backup_test.dart` "iOS share exporter writes temp JSON, handles cancel and keeps shared file" "DesktopDocumentPicker supplies non-empty Apple UTIs for iOS"; `test/reverse_image_search_test.dart` "DesktopReverseImageInputPlatform supplies Apple UTIs for iOS picker"
- **Code:** `lib/core/platform/ios_photo_library.dart`, `lib/core/download/download_manager_adapters.dart`, `lib/core/platform/desktop_file_sink.dart`, `lib/core/reverse_image/desktop_image_input.dart`, `lib/core/backup/backup_service.dart`, `ios/Runner/AppDelegate.swift`, `ios/Runner/Info.plist`, `lib/features/settings/pages/download_destination_page.dart`, `lib/features/settings/settings_helpers.dart`

### DL-14 macOS sandboxed tree destinations and desktop file actions respect security-scoped bookmarks
- **Rule:** When `supportsSecurityScopedBookmarks` is enabled, picked custom
  directories persist a base64 security-scoped bookmark token (`saveBookmark`)
  as `treeUri`, wrap I/O with reference-counted `startAccess`/`stopAccess`,
  and embed the token in resume locators. Missing or stale/denied bookmarks
  throw an explicit error instead of silently falling back to raw paths.
  `safTreeDisplayName` / `isMacosSecurityBookmark` render a readable localized
  label instead of exposing raw base64 in settings UI. On desktop platforms,
  completed download rows with a local `finalUri` expose "Open file" and
  "Show in folder" actions through `DesktopFileActions`
  (`parfait/desktop_file_actions`), forwarding the task or active destination's
  macOS security-scoped bookmark when present and surfacing missing-file or
  open-failure prompts via `deferAppSnackBar`.
- **Why:** Under macOS App Sandbox, raw paths outside Downloads lose read/write
  access after app restart or outside user-selected single-use sessions, and
  desktop users expect one-click open/reveal on completed downloads with clear
  feedback when a file has been moved or deleted.
- **Check:** `test/windows_capability_test.dart` "MacosBookmarkDirectoryPicker and sink factory require bookmarks and pair startAccess/stopAccess"; `test/settings_test.dart` "DownloadDestinationPage hides SAF on iOS and shows desktop folder copy and macOS bookmark label"; `test/download_tasks_page_test.dart` "desktop succeeded row opens file, reveals in folder with bookmark, and surfaces missing file"
- **Code:** `lib/core/platform/desktop_file_sink.dart`, `lib/core/platform/desktop_file_actions.dart`, `lib/features/settings/pages/download_task_rows.dart`, `macos/Runner/MainFlutterWindow.swift`, `windows/runner/flutter_window.cpp`, `linux/runner/my_application.cc`, `lib/features/settings/saf_tree_name.dart`, `lib/features/settings/pages/download_destination_page.dart`
