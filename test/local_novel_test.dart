import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:charset/charset.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parfait/core/download/download_destination.dart';
import 'package:parfait/core/download/download_manager.dart';
import 'package:parfait/core/download/download_providers.dart';
import 'package:parfait/core/download/download_sink.dart';
import 'package:parfait/core/download/download_task.dart';
import 'package:parfait/core/download/naming_rule.dart';
import 'package:parfait/core/download/novel_txt_formatter.dart';
import 'package:parfait/core/localnovel/local_novel_database.dart';
import 'package:parfait/core/localnovel/local_novel_decoder.dart';
import 'package:parfait/core/localnovel/local_novel_repository.dart';
import 'package:parfait/core/localnovel/local_novel_store.dart';
import 'package:parfait/core/localnovel/read_offset_anchor.dart';
import 'package:parfait/core/novel/novel_download_coordinator.dart';
import 'package:parfait/core/novel/novel_entity.dart';
import 'package:parfait/core/platform/platform_caps.dart';
import 'package:parfait/core/platform/saf_tree.dart';
import 'package:parfait/core/settings/settings_controller.dart';
import 'package:parfait/core/user/user_entity.dart';
import 'package:parfait/features/novel/novel_layout.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/download_world.dart';

void main() {
  sqfliteFfiInit();

  group('decoder', () {
    test('plain UTF-8 decodes as utf8', () {
      final (text, encoding) = decodeLocalNovelText(
        Uint8List.fromList(utf8.encode('第一章 开始\n正文内容。')),
      );
      expect(encoding, LocalNovelEncoding.utf8);
      expect(text, '第一章 开始\n正文内容。');
    });

    test('UTF-8 BOM is honoured', () {
      final bytes = Uint8List.fromList([
        0xEF,
        0xBB,
        0xBF,
        ...utf8.encode('bom text'),
      ]);
      final (text, encoding) = decodeLocalNovelText(bytes);
      expect(encoding, LocalNovelEncoding.utf8);
      expect(text, 'bom text');
    });

    test('UTF-16 LE BOM decodes through the utf16 path', () {
      final source = '你好，世界';
      final bytes = utf16.encode(source);
      final (text, encoding) = decodeLocalNovelText(Uint8List.fromList(bytes));
      expect(encoding, LocalNovelEncoding.utf16);
      expect(text, source);
    });

    test('GBK bytes decode Chinese without mojibake', () {
      final source = '修真小说 第一卷\n仙路漫漫';
      final bytes = Uint8List.fromList(gbk.encode(source));
      // GBK bytes are not valid UTF-8, so the fallback chain must engage.
      final (text, encoding) = decodeLocalNovelText(bytes);
      expect(encoding, LocalNovelEncoding.gbk);
      expect(text, source);
    });

    test('undecodable bytes fall back to tagged lossy UTF-8', () {
      // 0xFF alone is invalid UTF-8 and unmapped in GBK.
      final (text, encoding) = decodeLocalNovelText(
        Uint8List.fromList([0x61, 0xFF, 0x62]),
      );
      expect(encoding, LocalNovelEncoding.utf8Lossy);
      expect(text, contains('a'));
      expect(text, contains('b'));
    });
  });

  group('repository', () {
    late Directory dir;
    late LocalNovelRepository repository;
    late LocalNovelDatabase database;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('local-novels-test');
      database = LocalNovelDatabase(
        factory: databaseFactoryFfi,
        databasePath: '${dir.path}/local_novels.db',
      );
      repository = LocalNovelRepository(database: database);
    });

    tearDown(() async {
      await database.close();
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test(
      'import decodes, copies under the directory and indexes a row',
      () async {
        final novel = await repository.importBytes(
          fileName: '我的小说.txt',
          bytes: Uint8List.fromList(utf8.encode('正文一二三')),
          targetDir: dir,
        );

        expect(novel.title, '我的小说');
        expect(novel.charCount, 5);
        expect(novel.encoding, LocalNovelEncoding.utf8);
        expect(await File(novel.path).readAsString(), '正文一二三');
        expect(novel.path, startsWith(dir.path));

        final listed = await repository.list();
        expect(listed, hasLength(1));
        expect(listed.single.id, novel.id);
        expect(listed.single.encoding, LocalNovelEncoding.utf8);
        expect(
          (await repository.get(novel.id))!.encoding,
          LocalNovelEncoding.utf8,
        );
      },
    );

    test(
      'decoded char and paragraph caps match NovelLayoutBudget and reject before storing',
      () async {
        const budget = NovelLayoutBudget();
        expect(LocalNovelRepository.maxImportChars, budget.maxTextUnits);
        expect(LocalNovelRepository.maxImportParagraphs, budget.maxParagraphs);

        final target = Directory('${dir.path}/budget');
        await expectLater(
          repository.importBytes(
            fileName: 'too-many-chars.txt',
            bytes: Uint8List(LocalNovelRepository.maxImportChars + 1)
              ..fillRange(0, LocalNovelRepository.maxImportChars + 1, 0x61),
            targetDir: target,
          ),
          throwsA(
            isA<LocalNovelTooLargeException>().having(
              (e) => e.kind,
              'kind',
              LocalNovelLimitKind.chars,
            ),
          ),
        );
        await expectLater(
          repository.importBytes(
            fileName: 'too-many-paragraphs.txt',
            bytes: Uint8List(LocalNovelRepository.maxImportParagraphs)
              ..fillRange(0, LocalNovelRepository.maxImportParagraphs, 0x0A),
            targetDir: target,
          ),
          throwsA(
            isA<LocalNovelTooLargeException>().having(
              (e) => e.kind,
              'kind',
              LocalNovelLimitKind.paragraphs,
            ),
          ),
        );
        expect(await repository.list(), isEmpty);
        expect(target.existsSync(), isFalse);
      },
    );

    test(
      'a file over the limit is refused before anything is stored',
      () async {
        final target = Directory('${dir.path}/novels');
        await expectLater(
          repository.importBytes(
            fileName: 'huge.txt',
            bytes: Uint8List(LocalNovelRepository.maxImportBytes + 1),
            targetDir: target,
          ),
          throwsA(isA<DocumentTooLargeException>()),
        );
        expect(await repository.list(), isEmpty);
        expect(target.existsSync(), isFalse);
      },
    );

    test('an import whose row fails to store leaves no file', () async {
      final target = Directory('${dir.path}/novels');
      final db = await database.database;
      await db.execute('DROP TABLE ${LocalNovelDatabase.table}');
      await expectLater(
        repository.importBytes(
          fileName: 'lost.txt',
          bytes: Uint8List.fromList(utf8.encode('正文')),
          targetDir: target,
        ),
        throwsA(isA<DatabaseException>()),
      );
      expect(target.listSync(), isEmpty);
    });

    test(
      'GBK import stores decoded UTF-8 text and persists encoding',
      () async {
        final novel = await repository.importBytes(
          fileName: 'legacy.txt',
          bytes: Uint8List.fromList(gbk.encode('古早文本')),
          targetDir: dir,
        );
        expect(novel.encoding, LocalNovelEncoding.gbk);
        expect(await File(novel.path).readAsString(), '古早文本');
        expect(
          (await repository.get(novel.id))!.encoding,
          LocalNovelEncoding.gbk,
        );
        expect(
          (await repository.list()).single.encoding,
          LocalNovelEncoding.gbk,
        );
      },
    );

    test(
      'v1 database upgrades to v2 preserving legacy rows and persisting encoding',
      () async {
        final v1Path = '${dir.path}/v1_novels.db';
        final legacyFile = File('${dir.path}/legacy_v1.txt')
          ..writeAsStringSync('旧版正文');
        final raw = await databaseFactoryFfi.openDatabase(
          v1Path,
          options: OpenDatabaseOptions(
            version: 1,
            onCreate: (db, _) => db.execute('''
              CREATE TABLE ${LocalNovelDatabase.table} (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                title TEXT NOT NULL,
                author TEXT,
                path TEXT NOT NULL UNIQUE,
                char_count INTEGER NOT NULL DEFAULT 0,
                imported_at INTEGER NOT NULL,
                read_offset INTEGER
              )
            '''),
          ),
        );
        final legacyId = await raw.insert(LocalNovelDatabase.table, {
          'title': '旧版小说',
          'author': null,
          'path': legacyFile.path,
          'char_count': 4,
          'imported_at': 1700000000000,
          'read_offset': 2,
        });
        await raw.close();

        final upgradedDb = LocalNovelDatabase(
          factory: databaseFactoryFfi,
          databasePath: v1Path,
        );
        addTearDown(upgradedDb.close);
        final upgradedRepo = LocalNovelRepository(database: upgradedDb);

        final legacy = await upgradedRepo.get(legacyId);
        expect(legacy, isNotNull);
        expect(legacy!.title, '旧版小说');
        expect(legacy.readOffset, 2);
        expect(legacy.encoding, isNull);

        final imported = await upgradedRepo.importBytes(
          fileName: 'gbk_after_upgrade.txt',
          bytes: Uint8List.fromList(gbk.encode('升级后导入')),
          targetDir: dir,
        );
        final reloaded = await upgradedRepo.get(imported.id);
        expect(reloaded!.encoding, LocalNovelEncoding.gbk);
        final all = await upgradedRepo.list();
        expect(
          all.firstWhere((item) => item.id == imported.id).encoding,
          LocalNovelEncoding.gbk,
        );
        expect(all.firstWhere((item) => item.id == legacyId).encoding, isNull);
      },
    );

    test('same file name imports get unique paths, even at once', () async {
      Future<LocalNovel> import(String text) => repository.importBytes(
        fileName: 'dup.txt',
        bytes: Uint8List.fromList(utf8.encode(text)),
        targetDir: dir,
      );
      final [first, second] = await Future.wait([import('一'), import('二')]);
      expect(first.path, isNot(second.path));
      expect(await File(first.path).readAsString(), '一');
      expect(await File(second.path).readAsString(), '二');
    });

    test('delete removes the row and the file together', () async {
      final novel = await repository.importBytes(
        fileName: 'gone.txt',
        bytes: Uint8List.fromList(utf8.encode('删除我')),
        targetDir: dir,
      );
      final path = novel.path;
      await repository.delete(novel);
      expect(await repository.list(), isEmpty);
      expect(await File(path).exists(), isFalse);
    });

    test('read offset persists through updateReadOffset', () async {
      final novel = await repository.importBytes(
        fileName: 'progress.txt',
        bytes: Uint8List.fromList(utf8.encode('进度')),
        targetDir: dir,
      );
      await repository.updateReadOffset(novel.id, 1234);
      final reloaded = await repository.get(novel.id);
      expect(reloaded!.readOffset, 1234);
    });
  });

  group('store', () {
    late Directory dir;
    late ProviderContainer container;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('local-novels-store');
      final database = LocalNovelDatabase(
        factory: databaseFactoryFfi,
        databasePath: '${dir.path}/local_novels.db',
      );
      addTearDown(database.close);
      container = ProviderContainer.test(
        overrides: [
          localNovelDatabaseProvider.overrideWithValue(database),
          localNovelDirectoryProvider.overrideWithValue(() async => dir),
          localNovelFilePickerProvider.overrideWithValue(
            () async => ('picked.txt', Uint8List.fromList(utf8.encode('选中内容'))),
          ),
        ],
      );
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test(
      'importPicked imports through the picker and updates the list',
      () async {
        await container.read(localNovelStoreProvider.future);
        final novel = await container
            .read(localNovelStoreProvider.notifier)
            .importPicked();
        expect(novel!.title, 'picked');
        expect(await File(novel.path).readAsString(), '选中内容');
        expect(container.read(localNovelStoreProvider).value, hasLength(1));
      },
    );

    test('delete removes the entry from state', () async {
      await container.read(localNovelStoreProvider.future);
      final novel = (await container
          .read(localNovelStoreProvider.notifier)
          .importPicked())!;
      await container.read(localNovelStoreProvider.notifier).delete(novel);
      expect(container.read(localNovelStoreProvider).value, isEmpty);
      expect(await File(novel.path).exists(), isFalse);
    });

    test(
      'updateReadOffset persists and refreshes list state immediately',
      () async {
        await container.read(localNovelStoreProvider.future);
        final novel = (await container
            .read(localNovelStoreProvider.notifier)
            .importPicked())!;
        expect(
          container.read(localNovelStoreProvider).value!.single.readOffset,
          isNull,
        );

        await container
            .read(localNovelStoreProvider.notifier)
            .updateReadOffset(novel.id, 3);
        expect(
          container.read(localNovelStoreProvider).value!.single.readOffset,
          3,
        );
        final stored = await container
            .read(localNovelRepositoryProvider)
            .get(novel.id);
        expect(stored!.readOffset, 3);
      },
    );
  });

  group('read offset anchor', () {
    int forwardOffset(String text, String paragraphId, int offset) {
      final lines = text.split('\n');
      var base = 0;
      for (var i = 0; i < lines.length; i++) {
        if ('p$i' == paragraphId) return base + offset;
        base += lines[i].length + 1;
      }
      throw ArgumentError('unknown paragraph $paragraphId');
    }

    test('empty or absent cursors restore nothing', () {
      expect(novelAnchorForReadOffset(null, 'a\nb'), isNull);
      expect(novelAnchorForReadOffset(0, 'a\nb'), isNull);
      expect(novelAnchorForReadOffset(-3, 'a\nb'), isNull);
      expect(novelAnchorForReadOffset(4, ''), isNull);
    });

    test('offsets inside a paragraph map to that paragraph', () {
      const text = 'hello\nworld';
      expect(novelAnchorForReadOffset(1, text), (paragraphId: 'p0', offset: 1));
      expect(novelAnchorForReadOffset(8, text), (paragraphId: 'p1', offset: 2));
    });

    test('a newline position belongs to the paragraph before it', () {
      const text = 'hello\nworld';
      expect(novelAnchorForReadOffset(5, text), (paragraphId: 'p0', offset: 5));
      expect(novelAnchorForReadOffset(6, text), (paragraphId: 'p1', offset: 0));
    });

    test('round-trips every anchor the persist side can produce', () {
      const text = 'ab\n\ncd\nef';
      for (var i = 0; i < text.split('\n').length; i++) {
        final length = text.split('\n')[i].length;
        for (var offset = 0; offset <= length; offset++) {
          final stored = forwardOffset(text, 'p$i', offset);
          expect(
            novelAnchorForReadOffset(stored, text),
            stored == 0 ? null : (paragraphId: 'p$i', offset: offset),
            reason: 'p$i:$offset -> $stored',
          );
        }
      }
    });

    test('an offset past the end clamps to the last paragraph', () {
      const text = 'a\nb';
      expect(novelAnchorForReadOffset(3, text), (paragraphId: 'p1', offset: 1));
      expect(novelAnchorForReadOffset(999, text), (
        paragraphId: 'p1',
        offset: 1,
      ));
    });

    test('a trailing newline keeps the final empty paragraph reachable', () {
      const text = 'a\n';
      expect(novelAnchorForReadOffset(1, text), (paragraphId: 'p0', offset: 1));
      expect(novelAnchorForReadOffset(2, text), (paragraphId: 'p1', offset: 0));
    });

    test(
      'indexed lineStarts binary search and O(1) save match linear scan',
      () {
        const text = 'ab\n\ncd\nef\n';
        final starts = buildLocalNovelLineStarts(text);
        for (var pos = 0; pos <= text.length + 2; pos++) {
          final anchor = novelAnchorForReadOffsetWithStarts(
            pos,
            starts,
            text.length,
          );
          expect(anchor, novelAnchorForReadOffset(pos, text));
          if (anchor != null) {
            expect(
              localNovelReadOffsetForAnchor(
                paragraphId: anchor.paragraphId,
                offset: anchor.offset,
                lineStarts: starts,
                textLength: text.length,
              ),
              pos.clamp(0, text.length),
            );
          }
        }
      },
    );
  });

  group('Pixiv offline novel and TXT export', () {
    test(
      'NovelDownloadCoordinator saves offline with chapters and exports TXT per platform',
      () async {
        final dir = await Directory.systemTemp.createTemp('pixiv-novel-save');
        addTearDown(() async {
          if (await dir.exists()) await dir.delete(recursive: true);
        });
        final database = LocalNovelDatabase(
          factory: databaseFactoryFfi,
          databasePath: '${dir.path}/local_novels.db',
        );
        addTearDown(database.close);

        final sinks = MemorySinkFactory();
        final payloads = NovelTxtPayloadStore();
        final executor = NovelTxtDownloadExecutor(payloads: payloads);
        final manager = DownloadManager(
          transport: FakeTransport(),
          sinkFactory: sinks,
          customExecutor:
              ({
                required request,
                required snapshot,
                required sink,
                required cancelToken,
                required checkOwner,
                required onProgress,
              }) => executor.execute(
                request: request,
                snapshot: snapshot,
                sink: sink,
                cancelToken: cancelToken,
                checkOwner: checkOwner,
                onProgress: onProgress,
              ),
          submissionContext: () => const DownloadSubmissionContext(
            accountId: 'acc',
            destination: DownloadDestination.builtin,
          ),
        );
        addTearDown(manager.dispose);

        final rawBody = '[chapter:序章]\n第一段\n[newpage]\n[chapter:终章]\n第二段';
        final markup = NovelContentMapper.parse(rawBody, images: false);
        final novel = NovelEntity(
          id: 505,
          title: '星海游记',
          caption: '简介<br/>第二行',
          user: const UserEntity(id: 88, name: '星野', account: 'hoshino'),
          tags: const [NovelTag(name: 'SF')],
          seriesId: 12,
          seriesTitle: '银河三部曲',
          textLength: rawBody.length,
          contentVersion: 'v1',
          contentAvailable: true,
          paragraphs: markup.paragraphs,
          markup: markup,
        );

        final desktopContainer = ProviderContainer.test(
          overrides: [
            localNovelDatabaseProvider.overrideWithValue(database),
            localNovelDirectoryProvider.overrideWithValue(() async => dir),
            platformCapsProvider.overrideWithValue(
              const PlatformCaps(isWindows: true),
            ),
            downloadDestinationProvider.overrideWithValue(
              DownloadDestination.builtin,
            ),
            namingRuleProvider.overrideWithValue(
              const NamingRule(
                preset: NamingPreset.custom,
                template:
                    '{series}_{series_order}of{chapters}_{artist}_{title}_{id}_p{page}.{ext}',
              ),
            ),
            downloadPadPageNumbersProvider.overrideWithValue(true),
            novelTxtPayloadStoreProvider.overrideWithValue(payloads),
            downloadManagerProvider.overrideWithValue(manager),
          ],
        );

        final coordinator = desktopContainer.read(
          novelDownloadCoordinatorProvider,
        );
        final cached = await coordinator.saveNovelOffline(novel);
        expect(cached.pixivNovelId, 505);
        expect(cached.pixivSeriesId, 12);
        expect(cached.author, '星野');
        expect(await cached.file.readAsString(), contains('[chapter:序章]'));
        // Concurrent re-saves serialize cleanly without duplicating rows/files.
        final [concurrentA, concurrentB] = await Future.wait([
          coordinator.saveNovelOffline(novel),
          coordinator.saveNovelOffline(novel),
        ]);
        expect(concurrentA.id, cached.id);
        expect(concurrentB.id, cached.id);
        expect(
          await desktopContainer.read(localNovelRepositoryProvider).list(),
          hasLength(1),
        );

        final done = manager.events.first;
        final outcome = await coordinator.exportNovelTxt(
          novel,
          seriesOrder: 2,
          seriesTotal: 10,
        );
        expect(outcome, NovelTxtExportOutcome.queued);
        final event = await done;
        expect(event.kind, DownloadEventKind.succeeded);
        expect(event.snapshot.displayName, '银河三部曲_02of10_星野_星海游记_505.txt');
        expect(utf8.decode(sinks.sinks.single.bytes), contains('[chapter:终章]'));

        // Android MediaStore album refuses TXT export with actionable notice.
        final androidContainer = ProviderContainer.test(
          overrides: [
            platformCapsProvider.overrideWithValue(
              const PlatformCaps(isAndroid: true),
            ),
            downloadDestinationProvider.overrideWithValue(
              DownloadDestination.builtin,
            ),
          ],
        );
        expect(
          await androidContainer
              .read(novelDownloadCoordinatorProvider)
              .exportNovelTxt(novel),
          NovelTxtExportOutcome.androidFolderRequired,
        );
      },
    );
  });
}
