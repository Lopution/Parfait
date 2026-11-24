import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../download/download_destination.dart';
import '../download/download_task.dart';
import '../log.dart';
import 'desktop_file_sink.dart';
import 'platform_caps.dart';

/// Method channel bridging native desktop file open / reveal-in-folder actions.
const String kDesktopFileActionsChannelName = 'parfait/desktop_file_actions';

/// Outcome reported by [DesktopFileActions].
enum DesktopFileActionResult { opened, notFound, failed }

/// Resolves a local filesystem path from a stored download [Uri].
///
/// Supports `file://` URIs and absolute paths without a scheme; non-local URIs
/// such as Android `content://` return null.
String? resolveLocalFilePathFromUri(Uri? uri) {
  if (uri == null) return null;
  if (uri.scheme == 'file') {
    try {
      final path = uri.toFilePath();
      return path.isEmpty ? null : path;
    } on UnsupportedError {
      return null;
    }
  }
  if (!uri.hasScheme) {
    final raw = uri.path;
    if (raw.isEmpty) return null;
    if (raw.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(raw)) {
      return raw;
    }
  }
  return null;
}

/// Resolves an optional macOS security-scoped bookmark token for accessing a
/// downloaded file under App Sandbox (`DL-14`).
String? resolveDownloadMacosBookmark(
  DownloadTaskSnapshot task,
  DownloadDestination fallbackDestination,
) {
  final submitted = task.submission?.destination.safTreeUri;
  if (submitted != null && isMacosSecurityBookmark(submitted)) {
    return submitted;
  }
  final current = fallbackDestination.safTreeUri;
  if (current != null && isMacosSecurityBookmark(current)) {
    return current;
  }
  return null;
}

/// Port for opening a downloaded file or revealing it in the OS file manager.
abstract class DesktopFileActions {
  Future<DesktopFileActionResult> openFile(
    String path, {
    String? macosBookmark,
  });

  Future<DesktopFileActionResult> showInFolder(
    String path, {
    String? macosBookmark,
  });
}

/// MethodChannel-backed [DesktopFileActions] talking to Win32 / AppKit / GIO.
class MethodChannelDesktopFileActions implements DesktopFileActions {
  const MethodChannelDesktopFileActions({
    MethodChannel channel = const MethodChannel(kDesktopFileActionsChannelName),
  }) : _channel = channel;

  final MethodChannel _channel;

  @override
  Future<DesktopFileActionResult> openFile(
    String path, {
    String? macosBookmark,
  }) => _invoke('openFile', path: path, macosBookmark: macosBookmark);

  @override
  Future<DesktopFileActionResult> showInFolder(
    String path, {
    String? macosBookmark,
  }) => _invoke('showInFolder', path: path, macosBookmark: macosBookmark);

  Future<DesktopFileActionResult> _invoke(
    String method, {
    required String path,
    String? macosBookmark,
  }) async {
    if (path.isEmpty) return DesktopFileActionResult.failed;
    try {
      final args = <String, Object>{
        'path': path,
        if (macosBookmark != null && macosBookmark.isNotEmpty)
          'bookmark': macosBookmark,
      };
      final raw = await _channel.invokeMethod<String>(method, args);
      return switch (raw) {
        'opened' => DesktopFileActionResult.opened,
        'notFound' => DesktopFileActionResult.notFound,
        _ => DesktopFileActionResult.failed,
      };
    } on MissingPluginException {
      return DesktopFileActionResult.failed;
    } on PlatformException catch (error) {
      log('desktop_file_actions $method failed: $error');
      return DesktopFileActionResult.failed;
    }
  }
}

/// No-op [DesktopFileActions] for mobile / web platforms.
class NoopDesktopFileActions implements DesktopFileActions {
  const NoopDesktopFileActions();

  @override
  Future<DesktopFileActionResult> openFile(
    String path, {
    String? macosBookmark,
  }) async => DesktopFileActionResult.failed;

  @override
  Future<DesktopFileActionResult> showInFolder(
    String path, {
    String? macosBookmark,
  }) async => DesktopFileActionResult.failed;
}

final desktopFileActionsProvider = Provider<DesktopFileActions>((ref) {
  final caps = ref.watch(platformCapsProvider);
  if (caps.isDesktop &&
      !kIsWeb &&
      (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
    return const MethodChannelDesktopFileActions();
  }
  return const NoopDesktopFileActions();
});
