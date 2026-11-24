import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../log.dart';
import 'platform_caps.dart';

/// Event channel broadcasting OS file drag-and-drop events from desktop runners.
const String kDesktopFileDropEventChannelName = 'parfait/file_drop/events';

/// Lifecycle event emitted when files are dragged over or dropped onto the
/// desktop window.
sealed class DesktopFileDropEvent {
  const DesktopFileDropEvent();
}

final class DesktopFileDropEntered extends DesktopFileDropEvent {
  const DesktopFileDropEntered();
}

final class DesktopFileDropExited extends DesktopFileDropEvent {
  const DesktopFileDropExited();
}

final class DesktopFileDropped extends DesktopFileDropEvent {
  const DesktopFileDropped(this.paths);

  final List<String> paths;
}

/// Source of OS-level file drag-and-drop events for desktop platforms.
abstract class DesktopFileDropSource {
  Stream<DesktopFileDropEvent> get events;
}

/// EventChannel-backed [DesktopFileDropSource] talking to Win32 / AppKit / GTK.
///
/// Speaks the standard Flutter `EventChannel` wire protocol (`listen`/`cancel`
/// plus envelope messages) while silently ignoring `MissingPluginException`
/// when no native desktop runner is attached (e.g. headless widget tests).
class EventChannelDesktopFileDropSource implements DesktopFileDropSource {
  EventChannelDesktopFileDropSource({
    String channelName = kDesktopFileDropEventChannelName,
    MethodCodec codec = const StandardMethodCodec(),
  }) : _channelName = channelName,
       _codec = codec,
       _methodChannel = MethodChannel(channelName, codec) {
    _controller = StreamController<DesktopFileDropEvent>.broadcast(
      onListen: _onListen,
      onCancel: _onCancel,
    );
  }

  final String _channelName;
  final MethodCodec _codec;
  final MethodChannel _methodChannel;
  late final StreamController<DesktopFileDropEvent> _controller;

  void _onListen() {
    ServicesBinding.instance.defaultBinaryMessenger.setMessageHandler(
      _channelName,
      (ByteData? reply) async {
        if (reply == null) return null;
        try {
          final decoded = _codec.decodeEnvelope(reply);
          final parsed = _parseEvent(decoded);
          if (parsed != null && !_controller.isClosed) {
            _controller.add(parsed);
          }
        } on PlatformException catch (error) {
          log('desktop_file_drop event decode error: $error');
        }
        return null;
      },
    );
    unawaited(_activate());
  }

  void _onCancel() {
    ServicesBinding.instance.defaultBinaryMessenger.setMessageHandler(
      _channelName,
      null,
    );
    unawaited(_deactivate());
  }

  void dispose() {
    ServicesBinding.instance.defaultBinaryMessenger.setMessageHandler(
      _channelName,
      null,
    );
    unawaited(_controller.close());
  }

  @override
  Stream<DesktopFileDropEvent> get events => _controller.stream;

  Future<void> _activate() async {
    try {
      await _methodChannel.invokeMethod<void>('listen');
    } on MissingPluginException {
      // Unregistered in headless widget tests or non-desktop targets.
    } on PlatformException catch (error) {
      log('desktop_file_drop listen failed: $error');
    }
  }

  Future<void> _deactivate() async {
    try {
      await _methodChannel.invokeMethod<void>('cancel');
    } on MissingPluginException {
      // Unregistered in headless widget tests or non-desktop targets.
    } on PlatformException catch (error) {
      log('desktop_file_drop cancel failed: $error');
    }
  }

  static DesktopFileDropEvent? _parseEvent(Object? raw) {
    if (raw is! Map<Object?, Object?>) return null;
    final type = raw['type'];
    if (type == 'entered') return const DesktopFileDropEntered();
    if (type == 'exited') return const DesktopFileDropExited();
    if (type == 'dropped') {
      final rawPaths = raw['paths'];
      if (rawPaths is List<Object?>) {
        final paths = [
          for (final entry in rawPaths)
            if (entry is String && entry.isNotEmpty) entry,
        ];
        if (paths.isNotEmpty) {
          return DesktopFileDropped(List<String>.unmodifiable(paths));
        }
      }
    }
    return null;
  }
}

/// Empty [DesktopFileDropSource] for non-desktop platforms and headless tests.
class NoopDesktopFileDropSource implements DesktopFileDropSource {
  const NoopDesktopFileDropSource();

  @override
  Stream<DesktopFileDropEvent> get events =>
      const Stream<DesktopFileDropEvent>.empty();
}

final desktopFileDropSourceProvider = Provider<DesktopFileDropSource>((ref) {
  final caps = ref.watch(platformCapsProvider);
  if (caps.isDesktop && !kIsWeb) {
    final source = EventChannelDesktopFileDropSource();
    ref.onDispose(source.dispose);
    return source;
  }
  return const NoopDesktopFileDropSource();
});
