import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:parfait/core/download/caption_exporter.dart';
import 'package:parfait/core/download/download_destination.dart';
import 'package:parfait/core/download/download_manager.dart';
import 'package:parfait/core/download/download_recovery.dart';
import 'package:parfait/core/download/download_request.dart';
import 'package:parfait/core/download/download_sink.dart';
import 'package:parfait/core/download/download_subfolders.dart';
import 'package:parfait/core/download/download_task.dart';
import 'package:parfait/core/download/download_transport.dart';
import 'package:parfait/core/download/illust_download_coordinator.dart';
import 'package:parfait/core/download/naming_rule.dart';
import 'package:parfait/core/series/series_models.dart';
import 'package:parfait/core/series/series_repository.dart';
import 'package:parfait/core/settings/settings_enums.dart';

import 'helpers/illust_fixtures.dart';

DownloadSubmissionSnapshot _submission({
  String? accountId = 'acc-1',
  DownloadDestination destination = DownloadDestination.builtin,
}) => DownloadSubmissionSnapshot(
  snapshotId: 'sub-1',
  jobId: 'job-1',
  groupId: null,
  request: DownloadRequest(
    illustId: 7,
    pageIndex: 0,
    url: Uri.parse('https://i.pximg.net/7_p0.jpg'),
    target: DownloadTarget.illustPage,
  ),
  accountId: accountId,
  submittedAt: DateTime.utc(2026, 9, 1),
  destination: destination,
);

CaptionExporter _exporter(
  MemorySinkFactory sinks, {
  SharedPreferencesAsync? prefs,
  bool isAndroid = false,
}) => CaptionExporter(
  sinkFactory: sinks,
  preferences: prefs ?? SharedPreferencesAsync(),
  isAndroid: isAndroid,
);

class _FailingRawFactory implements RawDownloadSinkFactory {
  final sink = _RejectingSink();

  @override
  Future<DownloadSink> beginRaw({
    required String displayName,
    required String mimeType,
    required DownloadDestination destination,
    DownloadOutputOwner? owner,
    List<String> subdirectories = const [],
  }) async => sink;
}

class _RejectingSink implements DownloadSink {
  var aborted = false;

  @override
  Future<void> write(List<int> bytes) =>
      throw StateError('simulated write failure');

  @override
  Future<String> finalize() => throw StateError('unreachable');

  @override
  Future<void> abort() async {
    aborted = true;
  }
}

void main() {
  group('CaptionExporter', () {
    test('writes <stem>.txt with the info header', () async {
      final sinks = MemorySinkFactory();
      final illust = parseIllust(
        illustJson(7, caption: 'first<br>second<br/>third<br />fourth'),
      );

      await _exporter(sinks).export(
        illust: illust,
        submission: _submission(),
        pageZeroName: '7_p0.jpg',
      );

      expect(sinks.rawNames, ['7_p0.txt']);
      final sink = sinks.sinks.single;
      expect(sink.finalized, isTrue);
      final content = utf8.decode(sink.bytes);
      expect(content, contains('标题：illust 7\n\n'));
      expect(content, contains('作者：author\n\n'));
      expect(content, contains('作者ID：99\n\n'));
      expect(content, contains('作品ID：7\n\n'));
      expect(content, contains('作品链接：https://www.pixiv.net/artworks/7\n\n'));
      expect(content, contains('标签：original, 風景\n\n'));
      expect(content, contains('简介：\nfirst\nsecond\nthird\nfourth\n'));
    });

    test('dedupes per (account, illust, destination)', () async {
      final prefs = SharedPreferencesAsync();
      final sinks = MemorySinkFactory();
      final exporter = _exporter(sinks, prefs: prefs);
      final illust = parseIllust(illustJson(7));

      await exporter.export(
        illust: illust,
        submission: _submission(),
        pageZeroName: '7_p0.jpg',
      );
      await exporter.export(
        illust: illust,
        submission: _submission(),
        pageZeroName: '7_p0.jpg',
      );
      expect(sinks.sinks, hasLength(1));

      // A different account identity exports again.
      await exporter.export(
        illust: illust,
        submission: _submission(accountId: 'acc-2'),
        pageZeroName: '7_p0.jpg',
      );
      expect(sinks.sinks, hasLength(2));

      // Same account, different destination also exports again.
      await exporter.export(
        illust: illust,
        submission: _submission(
          destination: const DownloadDestination.customAlbum('Manga'),
        ),
        pageZeroName: '7_p0.jpg',
      );
      expect(sinks.sinks, hasLength(3));
    });

    test('exports ugoira captions and skips unowned submissions', () async {
      final sinks = MemorySinkFactory();
      final exporter = _exporter(sinks);

      await exporter.export(
        illust: parseIllust(illustJson(9, type: 'ugoira')),
        submission: _submission(),
        pageZeroName: '9.gif',
      );
      await exporter.export(
        illust: parseIllust(illustJson(10)),
        submission: _submission(accountId: null),
        pageZeroName: '10_p0.jpg',
      );
      expect(sinks.rawNames, ['9.txt']);
    });

    test('on Android only a folder takes the caption', () async {
      final sinks = MemorySinkFactory();
      final exporter = _exporter(sinks, isAndroid: true);
      for (final destination in const [
        DownloadDestination.builtin,
        DownloadDestination.customAlbum('Manga'),
        DownloadDestination.safFolder('content://tree/x'),
      ]) {
        await exporter.export(
          illust: parseIllust(illustJson(7)),
          submission: _submission(destination: destination),
          pageZeroName: '7_p0.jpg',
        );
      }
      expect(sinks.rawNames, ['7_p0.txt']);
    });

    test('write failure aborts the output and stays retryable', () async {
      final factory = _FailingRawFactory();
      final exporter = CaptionExporter(
        sinkFactory: factory,
        preferences: SharedPreferencesAsync(),
        isAndroid: false,
      );
      final illust = parseIllust(illustJson(7));

      await expectLater(
        exporter.export(
          illust: illust,
          submission: _submission(),
          pageZeroName: '7_p0.jpg',
        ),
        throwsStateError,
      );
      expect(factory.sink.aborted, isTrue);

      // Dedupe was not marked — a follow-up export retries the write.
      final sinks = MemorySinkFactory();
      await _exporter(sinks).export(
        illust: illust,
        submission: _submission(),
        pageZeroName: '7_p0.jpg',
      );
      expect(sinks.sinks, hasLength(1));
    });
  });

  group('NamingRule extended variables', () {
    const rule = NamingRule(
      preset: NamingPreset.custom,
      template:
          '{author_id}_{artist}_{id}_p{page1}of{pages}_{w}x{h}_{created}.{ext}',
    );

    test('renders work metadata', () {
      expect(NamingRule.isValidTemplate(rule.template), isTrue);
      expect(
        rule.resolve(
          illustId: 42,
          pageIndex: 2,
          extension: 'jpg',
          artist: 'maker',
          title: 't',
          date: DateTime(2026, 8, 1, 10, 30, 45),
          authorId: 99,
          totalPages: 5,
          width: 800,
          height: 600,
        ),
        '99_maker_42_p3of5_800x600_20260801_103045.jpg',
      );
    });

    test('absent series metadata renders empty and folds separators', () {
      const withSeries = NamingRule(
        preset: NamingPreset.custom,
        template: '{id}_{series}_{series_order}of{chapters}_p{page}.{ext}',
      );
      expect(
        withSeries.resolve(illustId: 5, pageIndex: 0, extension: 'png'),
        '5_of_p0.png',
      );
      expect(
        withSeries.resolve(
          illustId: 5,
          pageIndex: 0,
          extension: 'png',
          seriesTitle: 'Road',
          seriesOrder: 3,
          seriesTotal: 12,
        ),
        '5_Road_3of12_p0.png',
      );
      const nonMediaSuffix = NamingRule(
        preset: NamingPreset.custom,
        template: '{title}.canary',
      );
      expect(
        nonMediaSuffix.resolve(
          illustId: 5,
          pageIndex: 0,
          extension: 'jpg',
          title: 'art',
        ),
        'art.canary.jpg',
      );
    });

    test('DownloadRequest.displayName consumes the metadata fields', () {
      final request = DownloadRequest(
        illustId: 7,
        pageIndex: 1,
        url: Uri.parse('https://i.pximg.net/7_p1.png'),
        target: DownloadTarget.illustPage,
        namingRule: NamingRule(
          preset: NamingPreset.custom,
          template: '{author_id}_{id}_{pages}p{page1}_{w}x{h}.{ext}',
        ),
        authorId: 55,
        totalPages: 4,
        width: 1024,
        height: 768,
      );
      expect(request.displayName, '55_7_4p2_1024x768.png');
      // pageZero re-points the stem for the caption sidecar.
      expect(request.pageZero.displayName, '55_7_4p1_1024x768.png');
    });

    test(
      'padPageNumbers pads page, page1, and series_order to total width',
      () {
        const rule = NamingRule(
          preset: NamingPreset.custom,
          template: '{id}_s{series_order}_p{page}_{page1}.{ext}',
        );
        expect(
          rule.resolve(
            illustId: 7,
            pageIndex: 0,
            extension: 'jpg',
            totalPages: 12,
            seriesOrder: 2,
            seriesTotal: 100,
            padPageNumbers: true,
          ),
          '7_s002_p00_01.jpg',
        );
        expect(
          rule.resolve(
            illustId: 7,
            pageIndex: 0,
            extension: 'jpg',
            totalPages: 5,
            padPageNumbers: true,
          ),
          '7_s_p00_01.jpg',
        );
        expect(
          rule.resolve(
            illustId: 7,
            pageIndex: 0,
            extension: 'jpg',
            totalPages: 5,
            padPageNumbers: false,
          ),
          '7_s_p0_1.jpg',
        );
      },
    );

    test(
      'download_subfolders sanitizes hazards, resolves hierarchy, and clamps MediaStore path',
      () {
        expect(sanitizeSubdirectorySegment('  CON  '), '_CON');
        expect(sanitizeSubdirectorySegment('..'), 'work');
        expect(sanitizeSubdirectorySegment('a/b\\c:d*e'), 'a_b_c_d_e');
        expect(
          () => validateSubdirectories(['ok', '../escape']),
          throwsFormatException,
        );
        expect(() => validateSubdirectories(['NUL']), throwsFormatException);
        expect(
          resolveWorkSubdirectories(
            mode: DownloadSubfolderMode.byArtistAndSeries,
            multiPageSubfolder: true,
            illustId: 88,
            pageCount: 3,
            artist: 'Art/ist',
            authorId: 9,
            seriesTitle: 'Saga:1',
            seriesId: 4,
          ),
          ['Art_ist', 'Saga_1', '88'],
        );
        final longPath = mediaStoreRelativePathFor(
          DownloadDestination.customAlbum('MyAlbum'),
          subdirectories: ['a' * 64, 'b' * 64, 'c' * 64],
        );
        expect(longPath, isNotNull);
        expect(longPath!.length, lessThanOrEqualTo(128));
      },
    );

    test(
      'IllustDownloadCoordinator resolves series metadata, subfolders, and caption routing',
      () async {
        final sinks = MemorySinkFactory();
        final manager = DownloadManager(
          transport: _NoopDownloadTransport(),
          sinkFactory: sinks,
          submissionContext: () => const DownloadSubmissionContext(
            accountId: 'acc',
            destination: DownloadDestination.builtin,
          ),
        );
        addTearDown(manager.dispose);
        final exporter = _exporter(sinks);
        var contextCalls = 0;
        final coordinator = IllustDownloadCoordinator(
          manager,
          captionExporter: exporter,
          readSubfolderMode: () => DownloadSubfolderMode.byArtistAndSeries,
          readMultiPageSubfolder: () => true,
          readPadPageNumbers: () => true,
          resolveSeriesContext: (illustId) async {
            contextCalls++;
            return IllustSeriesContextResult(
              detail: const IllustSeriesEntity(
                id: 50,
                title: 'Chronicle',
                userId: 9,
                userName: 'Maker',
                caption: '',
                coverUrl: null,
                workCount: 12,
                watchlistAdded: null,
                isConcluded: null,
              ),
              context: const IllustSeriesContext(seriesId: 50, contentOrder: 3),
            );
          },
        );
        final work = parseIllust({
          ...illustJson(77, pageCount: 12),
          'user': {
            'id': 9,
            'name': 'Maker',
            'account': 'maker',
            'profile_image_urls': {'medium': 'https://i.pximg.net/u/9.jpg'},
          },
          'series': {'id': 50, 'title': 'Chronicle'},
        });
        final snapshot = await coordinator.downloadPage(
          work: work,
          pageIndex: 1,
          url: Uri.parse('https://i.pximg.net/77_p1.jpg'),
          namingRule: const NamingRule(
            preset: NamingPreset.custom,
            template: '{series}_{series_order}of{chapters}_p{page1}.{ext}',
          ),
        );
        expect(contextCalls, 1);
        expect(snapshot.displayName, 'Chronicle_03of12_p02.jpg');
        expect(snapshot.submission?.subdirectories, [
          'Maker',
          'Chronicle',
          '77',
        ]);
        expect(sinks.rawSubdirectories, [
          ['Maker', 'Chronicle', '77'],
        ]);
        expect(sinks.rawNames, ['Chronicle_03of12_p01.txt']);

        // Bulk author download uses warm metadata only (no per-work context fetches).
        final reqs = coordinator.authorWorksRequests([
          work.copyWith(
            pageCount: 1,
            metaSinglePageOriginalUrl: 'https://i.pximg.net/77_p0.jpg',
          ),
        ]);
        expect(contextCalls, 1);
        expect(reqs.single.subdirectories, ['Maker', 'Chronicle']);
      },
    );
  });
}

class _NoopDownloadTransport implements DownloadTransport {
  @override
  Future<DownloadResponse> open(
    Uri url, {
    required Map<String, String> headers,
    required DownloadCancelToken cancelToken,
  }) async => _NoopDownloadResponse();
}

class _NoopDownloadResponse implements DownloadResponse {
  @override
  int get statusCode => 200;

  @override
  int? get contentLength => 2;

  @override
  Stream<List<int>> get stream => Stream<List<int>>.value(const [1, 2]);

  @override
  Future<void> close() async {}
}
