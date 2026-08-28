import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pixiv_func/core/download/download_recovery.dart';
import 'package:pixiv_func/core/download/download_sink.dart';
import 'package:pixiv_func/core/network/compat/network_contracts.dart';
import 'package:pixiv_func/core/ugoira/ugoira_cache.dart';
import 'package:pixiv_func/core/ugoira/ugoira_decoder.dart';
import 'package:pixiv_func/core/ugoira/ugoira_export.dart';
import 'package:pixiv_func/core/ugoira/ugoira_limits.dart';
import 'package:pixiv_func/core/ugoira/ugoira_metadata.dart';
import 'package:pixiv_func/core/ugoira/ugoira_repository.dart';
import 'package:pixiv_func/core/ugoira/ugoira_scheduler.dart';
import 'package:pixiv_func/core/ugoira/ugoira_zip.dart';

void main() {
  group('UgoiraMetadata', () {
    test('parses ordered frames and rejects duplicate or unsafe names', () {
      final metadata = UgoiraMetadata.fromJson(
        _metadataJson([
          {'file': '000000.jpg', 'delay': 80},
          {'file': '000001.jpg', 'delay': 120},
        ]),
      );

      expect(metadata.frames.map((frame) => frame.file), [
        '000000.jpg',
        '000001.jpg',
      ]);
      expect(metadata.frames.map((frame) => frame.delayMs), [80, 120]);

      expect(
        () => UgoiraMetadata.fromJson(
          _metadataJson([
            {'file': '000000.jpg', 'delay': 80},
            {'file': '000000.jpg', 'delay': 80},
          ]),
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => UgoiraMetadata.fromJson(<String, dynamic>{
          'ugoira_metadata': <Object, dynamic>{1: 'not a string key'},
        }),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => UgoiraMetadata.fromJson(
          _metadataJson([
            {'file': '../000000.jpg', 'delay': 80},
          ]),
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('SafeZipIndex', () {
    test('indexes only metadata frames and reads the exact stored entry', () {
      final metadata = UgoiraMetadata.fromJson(
        _metadataJson([
          {'file': '000000.png', 'delay': 80},
        ]),
      );
      final bytes = _zip({'000000.png': _onePixelPng()});

      final index = SafeZipIndex.fromBytes(
        bytes,
        metadata: metadata,
        limits: const UgoiraLimitsForTest(),
      );
      addTearDown(index.dispose);

      expect(index.entries, hasLength(1));
      expect(index.entries.single.name, '000000.png');
      expect(index.readFrameBytes(0), completion(_onePixelPng()));
    });

    test('orders entries by metadata rather than central-directory order', () {
      final metadata = UgoiraMetadata.fromJson(
        _metadataJson([
          {'file': '000000.jpg', 'delay': 80},
          {'file': '000001.jpg', 'delay': 120},
        ]),
      );
      final index = SafeZipIndex.fromBytes(
        _zip({
          '000001.jpg': [2],
          '000000.jpg': [1],
        }),
        metadata: metadata,
      );
      addTearDown(index.dispose);

      expect(index.entries.map((entry) => entry.name), [
        '000000.jpg',
        '000001.jpg',
      ]);
      expect(index.readFrameBytes(0), completion([1]));
      expect(index.readFrameBytes(1), completion([2]));
    });

    test('rejects unknown entries and excessive compression ratio', () {
      final metadata = UgoiraMetadata.fromJson(
        _metadataJson([
          {'file': '000000.jpg', 'delay': 80},
        ]),
      );
      final bytes = _zip({
        '000000.jpg': List<int>.filled(4096, 0),
        'unexpected.txt': [1, 2, 3],
      });

      expect(
        () => SafeZipIndex.fromBytes(
          bytes,
          metadata: metadata,
          limits: const UgoiraLimitsForTest(maxCompressionRatio: 2),
        ),
        throwsA(isA<UgoiraArchiveException>()),
      );

      final ratioBytes = _zip({'000000.jpg': List<int>.filled(4096, 0)});
      expect(
        () => SafeZipIndex.fromBytes(
          ratioBytes,
          metadata: metadata,
          limits: const UgoiraLimitsForTest(maxCompressionRatio: 2),
        ),
        throwsA(isA<UgoiraArchiveException>()),
      );
    });

    test('rejects metadata count mismatch and forged local sizes', () {
      final metadata = UgoiraMetadata.fromJson(
        _metadataJson([
          {'file': '000000.png', 'delay': 80},
          {'file': '000001.png', 'delay': 80},
        ]),
      );
      final bytes = _zip({'000000.png': _onePixelPng()});

      expect(
        () => SafeZipIndex.fromBytes(
          bytes,
          metadata: metadata,
          limits: const UgoiraLimitsForTest(),
        ),
        throwsA(isA<UgoiraArchiveException>()),
      );

      final singleMetadata = UgoiraMetadata.fromJson(
        _metadataJson([
          {'file': '000000.png', 'delay': 80},
        ]),
      );
      final forged = Uint8List.fromList(_zip({'000000.png': _onePixelPng()}));
      // Local header uncompressed-size field. The central directory remains
      // intact, so a parser that trusts only the central directory must fail.
      forged[22] = 0xff;
      forged[23] = 0xff;
      expect(
        () => SafeZipIndex.fromBytes(
          forged,
          metadata: singleMetadata,
          limits: const UgoiraLimitsForTest(),
        ),
        throwsA(isA<UgoiraArchiveException>()),
      );
    });

    test('parses dimensions before a decoder can allocate pixels', () {
      final header = UgoiraFrameHeader.parse(_onePixelPng());

      expect(header.format, UgoiraImageFormat.png);
      expect(header.width, 1);
      expect(header.height, 1);
      expect(header.pixelCount, 1);
    });

    test(
      'rejects oversized dimensions before creating a Flutter codec',
      () async {
        final oversized = Uint8List.fromList(_onePixelPng())
          ..[18] = 0x10
          ..[19] = 0x00
          ..[22] = 0x10
          ..[23] = 0x00;
        await expectLater(
          const UgoiraFrameDecoder(
            limits: UgoiraLimits(maxFrameDimension: 32),
          ).decode(oversized),
          throwsA(isA<UgoiraArchiveException>()),
        );
      },
    );

    test('decodes a valid frame only after the header gate', () async {
      final image = await const UgoiraFrameDecoder().decode(
        _validOnePixelPng(),
      );
      expect((image.width, image.height), (1, 1));
      image.dispose();
    });
  });

  group('UgoiraFrameCache', () {
    test('evicts the least recently used frame and disposes it', () {
      final disposed = <String>[];
      final cache = UgoiraFrameCache<_FakeFrame>(
        maxBytes: 10,
        sizeOf: (frame) => frame.bytes,
        dispose: (frame) => disposed.add(frame.id),
      );
      final first = _FakeFrame('first', 6);
      final second = _FakeFrame('second', 6);

      cache.put(0, first);
      cache.put(1, second);

      expect(cache.get(0), isNull);
      expect(cache.get(1), same(second));
      expect(disposed, ['first']);
      expect(cache.residentBytes, 6);
    });
  });

  group('UgoiraScheduler', () {
    test('uses accumulated deadlines and catches up after a jank interval', () {
      final frames = <int>[];
      final scheduler = UgoiraScheduler(
        delays: const [
          Duration(milliseconds: 80),
          Duration(milliseconds: 120),
          Duration(milliseconds: 40),
        ],
        onFrame: frames.add,
        autoTick: false,
      );

      scheduler.play();
      scheduler.advance(const Duration(milliseconds: 250));

      expect(frames, [1, 2, 0]);
      expect(scheduler.currentIndex, 0);
      expect(scheduler.isPlaying, isTrue);
    });

    test('pause and visibility stop preserve the current frame and intent', () {
      final scheduler = UgoiraScheduler(
        delays: const [Duration(milliseconds: 80), Duration(milliseconds: 80)],
        onFrame: (_) {},
        autoTick: false,
      );

      scheduler.play();
      scheduler.advance(const Duration(milliseconds: 90));
      scheduler.stop();
      expect(scheduler.currentIndex, 1);
      expect(scheduler.isPlaying, isTrue);
      expect(scheduler.isActive, isFalse);

      scheduler.start();
      scheduler.advance(const Duration(milliseconds: 80));
      expect(scheduler.currentIndex, 0);

      scheduler.pause();
      scheduler.start();
      scheduler.advance(const Duration(seconds: 1));
      expect(scheduler.currentIndex, 0);
      expect(scheduler.isPlaying, isFalse);
    });
  });

  group('UgoiraExportJob', () {
    test(
      'GIF quantization runs through the bounded worker and is decodable',
      () async {
        final image = await const UgoiraFrameDecoder().decode(
          _validOnePixelPng(),
        );
        final encoder = ImagePackageUgoiraGifEncoder(
          limits: const UgoiraLimitsForTest(),
        );
        try {
          await encoder.addFrame(
            image,
            delay: const Duration(milliseconds: 80),
          );
          final bytes = await encoder.finish();
          expect(bytes.sublist(0, 6), 'GIF89a'.codeUnits);
          expect(img.GifDecoder().decode(Uint8List.fromList(bytes)), isNotNull);
        } finally {
          image.dispose();
          await encoder.dispose();
        }
      },
    );

    test('cancellation aborts only the owned pending output', () async {
      final metadata = UgoiraMetadata.fromJson(
        _metadataJson([
          {'file': '000000.png', 'delay': 80},
        ]),
      );
      final index = SafeZipIndex.fromBytes(
        _zip({'000000.png': _validOnePixelPng()}),
        metadata: metadata,
      );
      final asset = UgoiraAsset(
        illustId: 43,
        metadata: metadata,
        index: index,
        file: File('/tmp/pixiv-func-test-ugoira-cancel.zip'),
      );
      final sinks = MemorySinkFactory();
      final job = UgoiraExportJob(
        asset: asset,
        sinkFactory: sinks,
        encoderFactory: (_) => _BlockingGifEncoder(),
      );
      final resultFuture = job.start();
      await Future<void>.delayed(Duration.zero);
      job.cancel();

      final result = await resultFuture;
      expect(result.status, UgoiraExportStatus.canceled);
      expect(sinks.sinks.single.aborted, isTrue);
      expect(sinks.sinks.single.finalized, isFalse);
      await job.dispose();
      await asset.dispose();
    });

    test('logout provider invalidates the captured export owner', () async {
      final metadata = UgoiraMetadata.fromJson(
        _metadataJson([
          {'file': '000000.png', 'delay': 80},
        ]),
      );
      final index = SafeZipIndex.fromBytes(
        _zip({'000000.png': _validOnePixelPng()}),
        metadata: metadata,
      );
      final asset = UgoiraAsset(
        illustId: 44,
        metadata: metadata,
        index: index,
        file: File('/tmp/pixiv-func-test-ugoira-owner.zip'),
      );
      final sinks = MemorySinkFactory();
      final job = UgoiraExportJob(
        asset: asset,
        sinkFactory: sinks,
        submissionContext: const DownloadSubmissionContext(
          accountId: 'account-a',
          credentialRevision: 1,
          networkRevision: NetworkRevision(2, networkIdentity: 'wifi'),
        ),
        submissionContextProvider: () => null,
        encoderFactory: (_) => _FakeGifEncoder(),
      );

      final result = await job.start();

      expect(result.status, UgoiraExportStatus.failed);
      expect(result.error, contains('UgoiraExportOwnershipException'));
      expect(sinks.sinks, isEmpty);
      await job.dispose();
      await asset.dispose();
    });

    test(
      'writes a post-process output and emits one terminal success',
      () async {
        final metadata = UgoiraMetadata.fromJson(
          _metadataJson([
            {'file': '000000.png', 'delay': 80},
            {'file': '000001.png', 'delay': 120},
          ]),
        );
        final index = SafeZipIndex.fromBytes(
          _zip({
            '000000.png': _validOnePixelPng(),
            '000001.png': _validOnePixelPng(),
          }),
          metadata: metadata,
          limits: const UgoiraLimitsForTest(),
        );
        final asset = UgoiraAsset(
          illustId: 42,
          metadata: metadata,
          index: index,
          file: File('/tmp/pixiv-func-test-ugoira.zip'),
        );
        final sinks = MemorySinkFactory();
        final recoveryStore = MemoryDownloadRecoveryStore();
        final job = UgoiraExportJob(
          asset: asset,
          sinkFactory: sinks,
          encoderFactory: (_) => _FakeGifEncoder(),
          recoveryStore: recoveryStore,
        );
        final events = <UgoiraExportSnapshot>[];
        final subscription = job.events.listen(events.add);

        final result = await job.start();
        await Future<void>.delayed(Duration.zero);

        expect(result.status, UgoiraExportStatus.succeeded);
        expect(sinks.sinks, hasLength(1));
        expect(sinks.sinks.single.finalized, isTrue);
        expect(sinks.sinks.single.aborted, isFalse);
        expect(
          events.where((event) => event.status == UgoiraExportStatus.succeeded),
          hasLength(1),
        );
        expect(
          events.any((event) => event.status == UgoiraExportStatus.finalizing),
          isTrue,
        );
        final recoveryRecord = (await recoveryStore.load()).single;
        expect(recoveryRecord.status, DownloadStatus.succeeded);
        expect(recoveryRecord.pendingMediaStoreId, isNull);
        expect(recoveryRecord.snapshot.illustId, 42);
        await subscription.cancel();
        await job.dispose();
        await asset.dispose();
      },
    );
  });
}

Map<String, dynamic> _metadataJson(List<Map<String, dynamic>> frames) => {
  'ugoira_metadata': {
    'zip_urls': {'medium': 'https://i.pximg.net/img-zip-ugoira/42.zip'},
    'frames': frames,
  },
};

List<int> _zip(Map<String, List<int>> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  return ZipEncoder().encode(archive)!;
}

List<int> _onePixelPng() => Uint8List.fromList([
  0x89,
  0x50,
  0x4e,
  0x47,
  0x0d,
  0x0a,
  0x1a,
  0x0a,
  0x00,
  0x00,
  0x00,
  0x0d,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1f,
  0x15,
  0xc4,
  0x89,
]);

List<int> _validOnePixelPng() => base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);

class UgoiraLimitsForTest extends UgoiraLimits {
  const UgoiraLimitsForTest({super.maxCompressionRatio = 200});
}

class _FakeFrame {
  const _FakeFrame(this.id, this.bytes);

  final String id;
  final int bytes;
}

class _FakeGifEncoder implements UgoiraGifEncoder {
  @override
  Future<void> addFrame(ui.Image image, {required Duration delay}) async {}

  @override
  Future<List<int>> finish() async => [0x47, 0x49, 0x46, 0x38, 0x39, 0x61];

  @override
  Future<void> dispose() async {}
}

class _BlockingGifEncoder implements UgoiraGifEncoder {
  final _gate = Completer<void>();

  @override
  Future<void> addFrame(ui.Image image, {required Duration delay}) =>
      _gate.future;

  @override
  Future<List<int>> finish() async => const [];

  @override
  Future<void> dispose() async {
    if (!_gate.isCompleted) _gate.complete();
  }
}
