/// Typed Dart contracts for Android MediaStore, SAF, and platform boundaries.
/// Implementations own channel details; domain consumers depend on these
/// interfaces. See `backend/android-channels.md`.
library;

// Platform interfaces for MediaStore streaming writes
// (android-platform-parity R6/R7).
//
// Concrete MethodChannel implementations stay behind these contracts so
// consumers can remain independent of Android channel details.

import '../download/download_recovery.dart';
import '../download/resume_anchor.dart';

/// A pending MediaStore insert. Writes go through [handle] and the item only
/// becomes visible after [MediaStoreSession.finalize]; [abort] removes it.
abstract class MediaStoreSession {
  /// Opens a pending item under [relativePath] (defaults to the built-in
  /// `Pictures/PixivFunc`) with the given display name and MIME type.
  Future<MediaStoreHandle> begin({
    required String displayName,
    required String mimeType,
    String? relativePath,
  });
}

/// Optional owner-aware extension. Existing platform adapters can continue to
/// implement [MediaStoreSession]; the download manager will retain its own
/// metadata fence when this extension is unavailable.
abstract interface class OwnedMediaStoreSession {
  Future<MediaStoreHandle> beginOwned({
    required String displayName,
    required String mimeType,
    required DownloadOutputOwner owner,
    String? relativePath,
  });
}

/// Metadata returned by a platform pending-row scan. It intentionally omits
/// filesystem paths and content; only an opaque owner marker is exposed.
class PendingMediaStoreItem {
  const PendingMediaStoreItem({
    required this.id,
    required this.ownerId,
    required this.displayName,
  });

  final int id;
  final String? ownerId;
  final String displayName;
}

/// Optional process-restart cleanup extension for API 29+ MediaStore.
abstract interface class RecoverableMediaStoreSession {
  Future<List<PendingMediaStoreItem>> listPending();

  /// Deletes only the pending row carrying this exact opaque owner marker.
  /// The platform must treat a missing or mismatched marker as a safe refusal.
  Future<bool> abortPending(int id, {required String ownerId});
}

/// Streaming write handle for one pending MediaStore item.
abstract class MediaStoreHandle {
  int get id;

  /// Appends bytes. Callers stream chunks; no full-file buffers.
  Future<void> write(List<int> bytes);

  /// Makes the item visible in MediaStore. Returns the final content URI.
  Future<Uri> finalize();

  /// Removes the pending item after a failure or cancellation. Safe to call
  /// twice; must never throw through cleanup paths.
  Future<void> abort();
}

/// Result of reopening a detached pending output for appending (D8):
/// the write handle plus the platform-reported durable byte count, which
/// the caller must compare against the durable [ResumeAnchor] record.
class ResumedPendingItem {
  const ResumedPendingItem({required this.handle, required this.storedBytes});

  final MediaStoreHandle handle;
  final int storedBytes;
}

/// Optional handle capability: the pending output can be detached — the
/// write stream closes while the pending row keeps its committed bytes so
/// a later attempt appends instead of restarting.
abstract interface class ResumableMediaStoreHandle implements MediaStoreHandle {
  /// Which [ResumeAnchor] kind this handle produces.
  ResumeAnchorKind get anchorKind;

  /// Closes the stream preserving pending bytes; returns the locator a
  /// later resume call will need (MediaStore row id, or a `.part` file
  /// path on desktop).
  Future<String> detach();
}

/// Optional session capability: reopen a detached pending row in append
/// mode ("wa") under an owner marker (D8).
abstract interface class ResumableMediaStoreSession {
  /// Returns null when the row is missing or carries a different owner
  /// marker — a safe refusal, never a delete.
  Future<ResumedPendingItem?> resumePending(int id, {required String ownerId});
}

/// Optional desktop capability: reopen a detached staged `.part` file by
/// path (D8). Kept separate from [ResumableMediaStoreSession] because the
/// desktop locator is a filesystem path, not a MediaStore row id.
abstract interface class ResumableFileMediaStoreSession {
  /// Returns null when the staged file is missing or not a `.part`.
  Future<ResumedPendingItem?> resumePendingPath(String path);
}
