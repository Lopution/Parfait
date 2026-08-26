import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/media_store_channel.dart';
import 'download_manager.dart';
import 'download_sink.dart';
import 'pixiv_download_transport.dart';

/// App-scoped manager: shared pooled transport + MediaStore pending sinks.
final downloadManagerProvider = Provider<DownloadManager>((ref) {
  final manager = DownloadManager(
    transport: HttpDownloadTransport(),
    sinkFactory: MediaStoreSinkFactory(const MethodChannelMediaStoreSession()),
  );
  ref.onDispose(manager.dispose);
  return manager;
});
