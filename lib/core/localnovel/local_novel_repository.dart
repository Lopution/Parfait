/// Local-novel library index: decoded TXT files copied into the app
/// support directory and indexed in `local_novels.db`.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'local_novel_database.dart';
import 'local_novel_decoder.dart';

/// One indexed local novel.
class LocalNovel {
  const LocalNovel({
    required this.id,
    required this.title,
    required this.path,
    required this.charCount,
    required this.importedAt,
    this.author,
    this.encoding,
    this.readOffset,
  });

  final int id;
  final String title;
  final String? author;

  /// Absolute path inside the app's private `local_novels/` directory.
  final String path;
  final int charCount;
  final DateTime importedAt;
  final LocalNovelEncoding? encoding;

  /// Reading cursor written by the local reader (character offset).
  final int? readOffset;

  File get file => File(path);
}

/// CRUD + import boundary for the local TXT library. File writes and the
/// index row commit in order — an orphaned file without a row is collected
/// by the next [reconcileFiles] pass instead of silently accumulating.
class LocalNovelRepository {
  LocalNovelRepository({required LocalNovelDatabase database})
    : _database = database;

  final LocalNovelDatabase _database;

  /// Directory that owns copied-in TXT files; injectable for tests.
  static Future<Directory> defaultNovelsDirectory() async {
    final support = await getApplicationSupportDirectory();
    return Directory(path.join(support.path, 'local_novels'));
  }

  Future<List<LocalNovel>> list() async {
    final db = await _database.database;
    final rows = await db.query(
      LocalNovelDatabase.table,
      orderBy: 'imported_at DESC, id DESC',
    );
    return [for (final row in rows) _fromRow(row)];
  }

  Future<LocalNovel?> get(int id) async {
    final db = await _database.database;
    final rows = await db.query(
      LocalNovelDatabase.table,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  /// Decodes [bytes] as a TXT novel, copies it under [targetDir], and
  /// indexes it. Returns the inserted entity.
  Future<LocalNovel> importBytes({
    required String fileName,
    required Uint8List bytes,
    required Directory targetDir,
  }) async {
    final (text, encoding) = decodeLocalNovelText(bytes);
    await targetDir.create(recursive: true);
    final file = await _uniqueFile(targetDir, fileName);
    await file.writeAsString(text, flush: true);

    final db = await _database.database;
    final id = await db.insert(LocalNovelDatabase.table, {
      'title': _titleOf(fileName),
      'author': null,
      'path': file.path,
      'char_count': text.length,
      'imported_at': DateTime.now().millisecondsSinceEpoch,
      'read_offset': null,
    });
    return LocalNovel(
      id: id,
      title: _titleOf(fileName),
      path: file.path,
      charCount: text.length,
      importedAt: DateTime.now(),
      encoding: encoding,
    );
  }

  /// Removes the index row and the stored file together; a missing file is
  /// tolerated so cleanup of a half-deleted entry still completes.
  Future<void> delete(LocalNovel novel) async {
    final db = await _database.database;
    await db.delete(
      LocalNovelDatabase.table,
      where: 'id = ?',
      whereArgs: [novel.id],
    );
    final file = novel.file;
    if (await file.exists()) {
      await file.delete();
    }
  }

  Future<void> updateReadOffset(int id, int offset) async {
    final db = await _database.database;
    await db.update(
      LocalNovelDatabase.table,
      {'read_offset': offset},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Deletes rows whose backing file vanished and files that lost their
  /// row — the two halves of an interrupted import or delete.
  Future<void> reconcileFiles() async {
    final novels = await list();
    for (final novel in novels) {
      if (!await novel.file.exists()) {
        final db = await _database.database;
        await db.delete(
          LocalNovelDatabase.table,
          where: 'id = ?',
          whereArgs: [novel.id],
        );
      }
    }
  }

  /// Unique, filesystem-safe destination inside [dir]: `name.txt`,
  /// `name-2.txt`, … Sanitizes separators so a picked file name can never
  /// escape the library directory.
  Future<File> _uniqueFile(Directory dir, String fileName) async {
    var stem = _titleOf(fileName).replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    if (stem.isEmpty) stem = 'novel';
    for (var suffix = 0; ; suffix++) {
      final candidate = File(
        path.join(dir.path, suffix == 0 ? '$stem.txt' : '$stem-$suffix.txt'),
      );
      if (!await candidate.exists()) return candidate;
    }
  }

  static String _titleOf(String fileName) {
    final base = path.basename(fileName);
    final dot = base.lastIndexOf('.');
    return dot > 0 ? base.substring(0, dot) : base;
  }

  LocalNovel _fromRow(Map<String, Object?> row) {
    return LocalNovel(
      id: row['id']! as int,
      title: row['title']! as String,
      author: row['author'] as String?,
      path: row['path']! as String,
      charCount: (row['char_count'] as int?) ?? 0,
      importedAt: DateTime.fromMillisecondsSinceEpoch(
        row['imported_at']! as int,
      ),
      readOffset: row['read_offset'] as int?,
    );
  }
}

final localNovelDatabaseProvider = Provider<LocalNovelDatabase>((ref) {
  final database = LocalNovelDatabase();
  ref.onDispose(database.close);
  return database;
});

final localNovelRepositoryProvider = Provider<LocalNovelRepository>((ref) {
  return LocalNovelRepository(database: ref.watch(localNovelDatabaseProvider));
});
