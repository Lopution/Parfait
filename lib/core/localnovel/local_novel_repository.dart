/// Local-novel library index: decoded TXT files copied into the app
/// support directory and indexed in `local_novels.db`.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import '../log.dart';
import '../network/data_worker.dart';
import '../platform/app_storage_paths.dart';
import '../platform/saf_tree.dart';
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
    this.pixivNovelId,
    this.pixivSeriesId,
    this.pixivSeriesTitle,
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

  /// Origin Pixiv metadata when cached from an online novel or novel series.
  final int? pixivNovelId;
  final int? pixivSeriesId;
  final String? pixivSeriesTitle;

  bool get isPixivCached => pixivNovelId != null || pixivSeriesId != null;

  File get file => File(path);

  LocalNovel withReadOffset(int? readOffset) => LocalNovel(
    id: id,
    title: title,
    author: author,
    path: path,
    charCount: charCount,
    importedAt: importedAt,
    encoding: encoding,
    readOffset: readOffset,
    pixivNovelId: pixivNovelId,
    pixivSeriesId: pixivSeriesId,
    pixivSeriesTitle: pixivSeriesTitle,
  );
}

/// Which decoded text budget [LocalNovelRepository.importBytes] rejected.
enum LocalNovelLimitKind { chars, paragraphs }

/// Decoded TXT exceeds what the novel layout engine (`NovelLayoutBudget`) can
/// open; rejected at import time before writing files or database rows.
class LocalNovelTooLargeException implements Exception {
  const LocalNovelTooLargeException({
    required this.kind,
    required this.actual,
    required this.limit,
  });

  final LocalNovelLimitKind kind;
  final int actual;
  final int limit;

  @override
  String toString() =>
      'LocalNovelTooLargeException(${kind.name}: $actual > $limit)';
}

/// CRUD + import boundary for the local TXT library. The file is written
/// before its index row; a row that fails to store takes the file with it,
/// so the library directory holds no file the list cannot show.
(String, LocalNovelEncoding, int) _decodeAndCountLocalNovel(Uint8List bytes) {
  final (text, encoding) = decodeLocalNovelText(bytes);
  var count = 1;
  for (var i = 0; i < text.length; i++) {
    if (text.codeUnitAt(i) == 0x0A) count += 1;
  }
  return (text, encoding, count);
}

class LocalNovelRepository {
  LocalNovelRepository({
    required LocalNovelDatabase database,
    DataWorker worker = const InlineDataWorker(),
  }) : _database = database,
       _worker = worker;

  final LocalNovelDatabase _database;
  final DataWorker _worker;

  /// Largest raw TXT file accepted by the document picker.
  static const maxImportBytes = 64 * 1024 * 1024;

  /// Decoded text limits matching `NovelLayoutBudget` (4M UTF-16 units and
  /// 100k paragraphs) so an imported TXT never fails permanently on open.
  static const maxImportChars = 4 * 1024 * 1024;
  static const maxImportParagraphs = 100000;

  /// Directory that owns copied-in TXT files; injectable for tests.
  static Future<Directory> defaultNovelsDirectory() async {
    final support = await AppStoragePaths.active.resolveSupportDir();
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
    if (bytes.length > maxImportBytes) {
      throw const DocumentTooLargeException(maxImportBytes);
    }
    final (text, encoding, paragraphs) = await _worker.run(
      _decodeAndCountLocalNovel,
      bytes,
      label: 'local_novel.decode',
    );
    if (text.length > maxImportChars) {
      throw LocalNovelTooLargeException(
        kind: LocalNovelLimitKind.chars,
        actual: text.length,
        limit: maxImportChars,
      );
    }
    if (paragraphs > maxImportParagraphs) {
      throw LocalNovelTooLargeException(
        kind: LocalNovelLimitKind.paragraphs,
        actual: paragraphs,
        limit: maxImportParagraphs,
      );
    }
    await targetDir.create(recursive: true);
    final file = await _createUniqueFile(targetDir, fileName);

    final importedAt = DateTime.now();
    final int id;
    try {
      await file.writeAsString(text, flush: true);
      final db = await _database.database;
      id = await db.insert(LocalNovelDatabase.table, {
        'title': _titleOf(fileName),
        'author': null,
        'path': file.path,
        'char_count': text.length,
        'imported_at': importedAt.millisecondsSinceEpoch,
        'read_offset': null,
        'encoding': encoding.name,
      });
    } on Object {
      try {
        await file.delete();
      } on FileSystemException catch (error) {
        log('local novel: orphaned file not removed: $error');
      }
      rethrow;
    }
    return LocalNovel(
      id: id,
      title: _titleOf(fileName),
      path: file.path,
      charCount: text.length,
      importedAt: importedAt,
      encoding: encoding,
    );
  }

  /// Caches a Pixiv novel or merged series into the offline library, updating
  /// any existing entry with the same [pixivNovelId] or merged [pixivSeriesId]
  /// Serializes concurrent Pixiv upserts sharing the same origin key so two
  /// simultaneous saves cannot race past the existence check and create
  /// duplicate rows/files.
  final Map<String, Future<void>> _pixivSaveLocks = {};

  /// Saves or updates an online Pixiv novel (or combined series) into the
  /// offline local library as UTF-8 TXT without duplicating existing entries,
  /// while enforcing the same decoded char/paragraph limits as [importBytes].
  Future<LocalNovel> savePixivNovel({
    required String title,
    required String? author,
    required String text,
    required Directory targetDir,
    int? pixivNovelId,
    int? pixivSeriesId,
    String? pixivSeriesTitle,
  }) async {
    final lockKey = pixivNovelId != null
        ? 'novel:$pixivNovelId'
        : (pixivSeriesId != null ? 'series:$pixivSeriesId' : null);
    if (lockKey == null) {
      return _savePixivNovelUnlocked(
        title: title,
        author: author,
        text: text,
        targetDir: targetDir,
        pixivNovelId: pixivNovelId,
        pixivSeriesId: pixivSeriesId,
        pixivSeriesTitle: pixivSeriesTitle,
      );
    }
    final previous = _pixivSaveLocks[lockKey];
    final gate = Completer<void>();
    _pixivSaveLocks[lockKey] = gate.future;
    try {
      if (previous != null) await previous;
      return await _savePixivNovelUnlocked(
        title: title,
        author: author,
        text: text,
        targetDir: targetDir,
        pixivNovelId: pixivNovelId,
        pixivSeriesId: pixivSeriesId,
        pixivSeriesTitle: pixivSeriesTitle,
      );
    } finally {
      if (identical(_pixivSaveLocks[lockKey], gate.future)) {
        unawaited(_pixivSaveLocks.remove(lockKey));
      }
      gate.complete();
    }
  }

  Future<LocalNovel> _savePixivNovelUnlocked({
    required String title,
    required String? author,
    required String text,
    required Directory targetDir,
    int? pixivNovelId,
    int? pixivSeriesId,
    String? pixivSeriesTitle,
  }) async {
    final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    if (normalized.length > maxImportChars) {
      throw LocalNovelTooLargeException(
        kind: LocalNovelLimitKind.chars,
        actual: normalized.length,
        limit: maxImportChars,
      );
    }
    var paragraphs = 1;
    for (var i = 0; i < normalized.length; i++) {
      if (normalized.codeUnitAt(i) == 0x0A) paragraphs += 1;
    }
    if (paragraphs > maxImportParagraphs) {
      throw LocalNovelTooLargeException(
        kind: LocalNovelLimitKind.paragraphs,
        actual: paragraphs,
        limit: maxImportParagraphs,
      );
    }
    await targetDir.create(recursive: true);
    final db = await _database.database;
    LocalNovel? existing;
    if (pixivNovelId != null) {
      final rows = await db.query(
        LocalNovelDatabase.table,
        where: 'pixiv_novel_id = ?',
        whereArgs: [pixivNovelId],
        limit: 1,
      );
      if (rows.isNotEmpty) existing = _fromRow(rows.first);
    } else if (pixivSeriesId != null) {
      final rows = await db.query(
        LocalNovelDatabase.table,
        where: 'pixiv_novel_id IS NULL AND pixiv_series_id = ?',
        whereArgs: [pixivSeriesId],
        limit: 1,
      );
      if (rows.isNotEmpty) existing = _fromRow(rows.first);
    }
    final importedAt = DateTime.now();
    if (existing != null) {
      final file = File(existing.path);
      await file.parent.create(recursive: true);
      await file.writeAsString(normalized, flush: true);
      final clampedOffset = existing.readOffset?.clamp(0, normalized.length);
      await db.update(
        LocalNovelDatabase.table,
        {
          'title': title,
          'author': author,
          'char_count': normalized.length,
          'imported_at': importedAt.millisecondsSinceEpoch,
          'read_offset': clampedOffset,
          'encoding': LocalNovelEncoding.utf8.name,
          'pixiv_novel_id': pixivNovelId,
          'pixiv_series_id': pixivSeriesId,
          'pixiv_series_title': pixivSeriesTitle,
        },
        where: 'id = ?',
        whereArgs: [existing.id],
      );
      return LocalNovel(
        id: existing.id,
        title: title,
        author: author,
        path: existing.path,
        charCount: normalized.length,
        importedAt: importedAt,
        encoding: LocalNovelEncoding.utf8,
        readOffset: clampedOffset,
        pixivNovelId: pixivNovelId,
        pixivSeriesId: pixivSeriesId,
        pixivSeriesTitle: pixivSeriesTitle,
      );
    }
    final file = await _createUniqueFile(targetDir, '$title.txt');
    final int id;
    try {
      await file.writeAsString(normalized, flush: true);
      id = await db.insert(LocalNovelDatabase.table, {
        'title': title,
        'author': author,
        'path': file.path,
        'char_count': normalized.length,
        'imported_at': importedAt.millisecondsSinceEpoch,
        'read_offset': null,
        'encoding': LocalNovelEncoding.utf8.name,
        'pixiv_novel_id': pixivNovelId,
        'pixiv_series_id': pixivSeriesId,
        'pixiv_series_title': pixivSeriesTitle,
      });
    } on Object {
      try {
        await file.delete();
      } on FileSystemException catch (error) {
        log('local novel: orphaned file not removed: $error');
      }
      rethrow;
    }
    return LocalNovel(
      id: id,
      title: title,
      author: author,
      path: file.path,
      charCount: normalized.length,
      importedAt: importedAt,
      encoding: LocalNovelEncoding.utf8,
      pixivNovelId: pixivNovelId,
      pixivSeriesId: pixivSeriesId,
      pixivSeriesTitle: pixivSeriesTitle,
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

  /// Creates a unique, filesystem-safe file inside [dir]: `name.txt`,
  /// `name-1.txt`, … Sanitizes separators so a picked file name can never
  /// escape the library directory. The exclusive create makes the file this
  /// import's alone, so two imports of one name never share it and a failed
  /// import deletes only its own.
  Future<File> _createUniqueFile(Directory dir, String fileName) async {
    var stem = _titleOf(fileName).replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    if (stem.isEmpty) stem = 'novel';
    for (var suffix = 0; ; suffix++) {
      final candidate = File(
        path.join(dir.path, suffix == 0 ? '$stem.txt' : '$stem-$suffix.txt'),
      );
      try {
        return await candidate.create(exclusive: true);
      } on PathExistsException {
        continue;
      }
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
      encoding: LocalNovelEncoding.values
          .asNameMap()[row['encoding'] as String?],
      readOffset: row['read_offset'] as int?,
      pixivNovelId: row['pixiv_novel_id'] as int?,
      pixivSeriesId: row['pixiv_series_id'] as int?,
      pixivSeriesTitle: row['pixiv_series_title'] as String?,
    );
  }
}

final localNovelDatabaseProvider = Provider<LocalNovelDatabase>((ref) {
  final database = LocalNovelDatabase(
    databasePath: ref
        .watch(appStoragePathsProvider)
        .databasePath(LocalNovelDatabase.databaseName),
  );
  ref.onDispose(database.close);
  return database;
});

final localNovelRepositoryProvider = Provider<LocalNovelRepository>((ref) {
  return LocalNovelRepository(
    database: ref.watch(localNovelDatabaseProvider),
    worker: ref.watch(dataWorkerProvider),
  );
});
