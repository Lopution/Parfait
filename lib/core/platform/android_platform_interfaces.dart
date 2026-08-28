// Platform interfaces for MediaStore streaming writes and AndroidX WebKit
// capability queries (android-platform-parity R6/R7).
//
// Concrete MethodChannel implementations stay behind these contracts so
// consumers can remain independent of Android channel details.

import '../download/download_recovery.dart';

/// A pending MediaStore insert. Writes go through [handle] and the item only
/// becomes visible after [MediaStoreSession.finalize]; [abort] removes it.
abstract class MediaStoreSession {
  /// Opens a pending item in Pictures/PixivFunc with the given display name
  /// and MIME type.
  Future<MediaStoreHandle> begin({
    required String displayName,
    required String mimeType,
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

/// Capability probe for the AndroidX WebKit stack (ProxyController etc.).
///
/// Consumers must fail safely when a capability is absent; no fallback may
/// widen the proxy surface (compat-network task contract).
abstract class WebKitCapabilities {
  /// Whether the current WebView supports the WebViewProxyController needed
  /// by the compatibility network mode.
  Future<bool> get supportsProxyController;

  /// Whether the current WebView supports the reverse-bypass contract needed
  /// to scope a proxy override to the approved Pixiv destinations.
  Future<bool> get supportsProxyReverseBypass;

  /// Whether service-worker control APIs are available.
  Future<bool> get supportsServiceWorkerController;
}
