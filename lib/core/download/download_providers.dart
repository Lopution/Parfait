import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/media_store_channel.dart';
import '../settings/settings_controller.dart';
import 'download_manager.dart';
import 'download_sink.dart';
import 'pixiv_download_transport.dart';

/// App-scoped manager: shared pooled transport + MediaStore pending sinks.
final downloadManagerProvider = Provider<DownloadManager>((ref) {
  final manager = DownloadManager(
    transport: HttpDownloadTransport(),
    sinkFactory: MediaStoreSinkFactory(const MethodChannelMediaStoreSession()),
    maxConcurrent: ref.read(maxDownloadCountProvider),
  );
  // Keep running jobs intact while applying the new cap to subsequent
  // dispatches. The manager owns the scheduler; settings only supplies the
  // typed configuration value.
  ref.listen<int>(maxDownloadCountProvider, (_, next) {
    manager.maxConcurrent = next;
  });
  ref.onDispose(manager.dispose);
  return manager;
});
