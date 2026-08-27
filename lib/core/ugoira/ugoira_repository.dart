import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../download/download_transport.dart';
import '../download/pixiv_download_transport.dart';
import '../network/api_error.dart';
import '../network/pixiv_client_identity.dart';
import '../network/pixiv_http_client.dart';
import 'ugoira_decoder.dart';
import 'ugoira_limits.dart';
import 'ugoira_metadata.dart';
import 'ugoira_zip.dart';

/// A loaded Ugoira archive. The ZIP file and index are owned by this object;
/// [dispose] removes the temporary file and closes all resources.
class UgoiraAsset {
  UgoiraAsset({
    required this.illustId,
    required this.metadata,
    required this.index,
    required this.file,
    this.limits = const UgoiraLimits(),
  });

  final int illustId;
  final UgoiraMetadata metadata;
  final SafeZipIndex index;
  final File file;
  final UgoiraLimits limits;
  bool _disposed = false;

  int get frameCount => metadata.frames.length;

  Future<List<int>> readFrameBytes(int index) {
    _ensureOpen();
    return this.index.readFrameBytes(index);
  }

  Future<UgoiraFrameHeader> inspectFrame(int index) {
    _ensureOpen();
    return this.index.inspectFrame(index);
  }

  Future<ui.Image> decodeFrame(int index) async {
    _ensureOpen();
    final bytes = await readFrameBytes(index);
    return UgoiraFrameDecoder(limits: limits).decode(bytes);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await index.dispose();
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Owned cleanup is best effort after the handle has been closed. The
      // caller still receives the original decode/download failure.
    }
  }

  void _ensureOpen() {
    if (_disposed) throw StateError('ugoira asset is disposed');
  }
}

/// Fetches metadata through the authenticated API and streams the ZIP to an
/// app-owned temporary file. The media transport is injected so later
/// compatibility routing can replace it for API/image/download/WebView as one
/// shared policy rather than creating a second Ugoira-specific route.
class UgoiraRepository {
  UgoiraRepository({
    required PixivHttpClient client,
    required DownloadTransport transport,
    Future<Directory> Function()? temporaryDirectory,
    this.limits = const UgoiraLimits(),
  }) : _client = client,
       _transport = transport,
       _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory;

  final PixivHttpClient _client;
  final DownloadTransport _transport;
  final Future<Directory> Function() _temporaryDirectory;
  final UgoiraLimits limits;

  Future<UgoiraMetadata> fetchMetadata(
    int illustId, {
    CancelToken? cancelToken,
  }) async {
    _validateIllustId(illustId);
    try {
      final json = await _client.getJson(
        Uri(
          scheme: 'https',
          host: PixivClientIdentity.appApiBase.host,
          path: '/v1/ugoira/metadata',
          queryParameters: {'illust_id': '$illustId'},
        ),
        cancelToken: cancelToken,
      );
      return UgoiraMetadata.fromJson(json, limits: limits);
    } on ApiError {
      rethrow;
    } on FormatException catch (error) {
      throw ApiParseError(error);
    }
  }

  Future<UgoiraAsset> load(int illustId, {CancelToken? cancelToken}) async {
    final metadata = await fetchMetadata(illustId, cancelToken: cancelToken);
    final directory = await _temporaryDirectory();
    await directory.create(recursive: true);
    final file = File(
      p.join(
        directory.path,
        '.pixivfunc-ugoira-$illustId-${DateTime.now().microsecondsSinceEpoch}.zip',
      ),
    );
    final transferCancel = DownloadCancelToken();
    final cancellationLink = cancelToken?.whenCancel.then((_) {
      transferCancel.cancel();
    });
    DownloadResponse? response;
    IOSink? sink;
    var completed = false;
    try {
      if (cancelToken?.isCancelled ?? false) {
        throw const ApiCancelled();
      }
      response = await _transport.open(
        metadata.zipUrl,
        headers: {
          'User-Agent': PixivClientIdentity.userAgent,
          'Referer': PixivClientIdentity.downloadReferer.toString(),
        },
        cancelToken: transferCancel,
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw DownloadTransportException(
          'ugoira ZIP returned HTTP ${response.statusCode}',
        );
      }
      final announced = response.contentLength;
      if (announced != null && announced > limits.maxArchiveCompressedBytes) {
        throw const UgoiraArchiveException('archive exceeds compressed limit');
      }
      sink = file.openWrite();
      var received = 0;
      await for (final chunk in response.stream) {
        if (transferCancel.isCancelled || (cancelToken?.isCancelled ?? false)) {
          throw const ApiCancelled();
        }
        if (chunk.length > limits.maxArchiveCompressedBytes - received) {
          throw const UgoiraArchiveException(
            'archive exceeds compressed limit',
          );
        }
        sink.add(chunk);
        received += chunk.length;
      }
      await sink.flush();
      await sink.close();
      sink = null;
      await response.close();
      response = null;
      if (cancelToken?.isCancelled ?? false) {
        throw const ApiCancelled();
      }
      final index = await SafeZipIndex.open(
        file,
        metadata: metadata,
        limits: limits,
      );
      completed = true;
      return UgoiraAsset(
        illustId: illustId,
        metadata: metadata,
        index: index,
        file: file,
        limits: limits,
      );
    } on DownloadCancelledException {
      throw const ApiCancelled();
    } finally {
      if (cancellationLink != null) {
        unawaited(cancellationLink);
      }
      await sink?.close();
      await response?.close();
      if (!completed) {
        try {
          if (await file.exists()) await file.delete();
        } on FileSystemException {
          // Keep the original error visible; cleanup is retried by the OS.
        }
      }
    }
  }

  static void _validateIllustId(int illustId) {
    if (illustId <= 0) {
      throw ArgumentError.value(illustId, 'illustId', 'must be positive');
    }
  }
}
