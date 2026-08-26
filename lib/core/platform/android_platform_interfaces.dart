// Platform interfaces for MediaStore streaming writes and AndroidX WebKit
// capability queries (android-platform-parity R6/R7).
//
// Concrete MethodChannel implementations land with the download task; the
// contracts here are final so consumers can be written against them now.

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

  /// Whether service-worker control APIs are available.
  Future<bool> get supportsServiceWorkerController;
}
