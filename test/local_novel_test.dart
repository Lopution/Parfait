import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:charset/charset.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parfait/core/localnovel/local_novel_database.dart';
import 'package:parfait/core/localnovel/local_novel_decoder.dart';
import 'package:parfait/core/localnovel/local_novel_repository.dart';
import 'package:parfait/core/localnovel/local_novel_store.dart';
import 'package:parfait/core/platform/saf_tree.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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

    test('GBK import stores decoded UTF-8 text on disk', () async {
      final novel = await repository.importBytes(
        fileName: 'legacy.txt',
        bytes: Uint8List.fromList(gbk.encode('古早文本')),
        targetDir: dir,
      );
      expect(novel.encoding, LocalNovelEncoding.gbk);
      expect(await File(novel.path).readAsString(), '古早文本');
    });

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
  });
}
