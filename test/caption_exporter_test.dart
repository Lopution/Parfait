import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pixiv_func/core/download/caption_exporter.dart';
import 'package:pixiv_func/core/download/download_destination.dart';
import 'package:pixiv_func/core/download/download_recovery.dart';
import 'package:pixiv_func/core/download/download_request.dart';
import 'package:pixiv_func/core/download/download_sink.dart';
import 'package:pixiv_func/core/download/download_task.dart';
import 'package:pixiv_func/core/download/naming_rule.dart';

import 'helpers/illust_fixtures.dart';
import 'helpers/test_preferences.dart';

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
}) => CaptionExporter(
  sinkFactory: sinks,
  preferences: prefs ?? SharedPreferencesAsync(),
);

class _FailingRawFactory implements RawDownloadSinkFactory {
  final sink = _FailingSink();

  @override
  Future<DownloadSink> beginRaw({
    required String displayName,
    required String mimeType,
    required DownloadDestination destination,
    DownloadOutputOwner? owner,
  }) async => sink;
}

class _FailingSink implements DownloadSink {
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
  // Fresh in-memory store per test — the dedupe flags must not leak
  // between cases (each export key is a real prefs write).
  setUp(installMemoryPreferences);

  group('CaptionExporter', () {
    test('writes <stem>.txt with the Shaft info header', () async {
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

    test('skips ugoira and unowned submissions', () async {
      final sinks = MemorySinkFactory();
      final exporter = _exporter(sinks);

      await exporter.export(
        illust: parseIllust(illustJson(9, type: 'ugoira')),
        submission: _submission(),
        pageZeroName: '9_p0.jpg',
      );
      await exporter.export(
        illust: parseIllust(illustJson(10)),
        submission: _submission(accountId: null),
        pageZeroName: '10_p0.jpg',
      );
      expect(sinks.sinks, isEmpty);
    });

    test('write failure aborts the output and stays retryable', () async {
      final factory = _FailingRawFactory();
      final exporter = CaptionExporter(
        sinkFactory: factory,
        preferences: SharedPreferencesAsync(),
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
  });
}
