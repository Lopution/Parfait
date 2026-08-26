/// Platform facade for Android contracts (android-platform-parity).
///
/// Re-exports the stable interfaces; MethodChannel implementations arrive
/// with their consumer tasks (downloads, compat network).
library;

export 'android_platform_interfaces.dart'
    show MediaStoreHandle, MediaStoreSession, WebKitCapabilities;
