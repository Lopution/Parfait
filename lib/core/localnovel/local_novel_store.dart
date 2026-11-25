/// Local-novel library state: the indexed list plus import/delete actions.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../errors/no_retry.dart';
import '../platform/saf_tree.dart';
import 'local_novel_repository.dart';

/// The directory imported TXT files are copied into; injectable so tests
/// never touch the real application-support directory.
final localNovelDirectoryProvider = Provider<Future<Directory> Function()>(
  (ref) => LocalNovelRepository.defaultNovelsDirectory,
);

/// Platform TXT picker behind a provider so widget tests can inject a
/// (name, bytes) pair without a platform file picker — same convention as
/// `backupFilePickerProvider`.
final localNovelFilePickerProvider =
    Provider<Future<(String, Uint8List)?> Function()>((ref) {
      final picker = ref.watch(documentPickerProvider);
      return () async {
        final picked = await picker.pickDocument(
          label: 'TXT',
          extensions: const ['txt'],
          mimeTypes: const ['text/plain'],
          maxBytes: LocalNovelRepository.maxImportBytes,
        );
        if (picked == null) return null;
        return (picked.name, picked.bytes);
      };
    });

class LocalNovelStore extends AsyncNotifier<List<LocalNovel>> {
  final Map<int, int> _pendingOffsets = {};

  @override
  Future<List<LocalNovel>> build() async {
    final rows = await ref.watch(localNovelRepositoryProvider).list();
    if (_pendingOffsets.isEmpty) return rows;
    final pending = Map<int, int>.of(_pendingOffsets);
    _pendingOffsets.clear();
    return [
      for (final item in rows)
        if (pending[item.id] case final offset?)
          item.withReadOffset(offset)
        else
          item,
    ];
  }

  /// Picks a TXT file, decodes it, copies it into the library directory
  /// and indexes it. Returns the imported entity; null when the user
  /// cancelled the picker.
  Future<LocalNovel?> importPicked() async {
    final picked = await ref.read(localNovelFilePickerProvider)();
    if (picked == null) return null;
    final dir = await ref.read(localNovelDirectoryProvider)();
    final novel = await ref
        .read(localNovelRepositoryProvider)
        .importBytes(fileName: picked.$1, bytes: picked.$2, targetDir: dir);
    state = AsyncData([novel, ...state.value ?? const []]);
    return novel;
  }

  /// Imports a local TXT file directly from a desktop drag-and-drop [path],
  /// enforcing the same byte, character, and paragraph limits as the picker.
  Future<LocalNovel> importFilePath(String path) async {
    final file = File(path);
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file) {
      throw FileSystemException('Not a regular file', path);
    }
    if (stat.size > LocalNovelRepository.maxImportBytes) {
      throw const DocumentTooLargeException(
        LocalNovelRepository.maxImportBytes,
      );
    }
    final bytes = await file.readAsBytes();
    final dir = await ref.read(localNovelDirectoryProvider)();
    final novel = await ref
        .read(localNovelRepositoryProvider)
        .importBytes(fileName: p.basename(path), bytes: bytes, targetDir: dir);
    state = AsyncData([novel, ...state.value ?? const []]);
    return novel;
  }

  Future<LocalNovel> savePixivNovel({
    required String title,
    required String? author,
    required String text,
    int? pixivNovelId,
    int? pixivSeriesId,
    String? pixivSeriesTitle,
  }) async {
    final dir = await ref.read(localNovelDirectoryProvider)();
    final saved = await ref
        .read(localNovelRepositoryProvider)
        .savePixivNovel(
          title: title,
          author: author,
          text: text,
          targetDir: dir,
          pixivNovelId: pixivNovelId,
          pixivSeriesId: pixivSeriesId,
          pixivSeriesTitle: pixivSeriesTitle,
        );
    final current = state.value;
    if (current != null) {
      state = AsyncData([
        saved,
        for (final item in current)
          if (item.id != saved.id) item,
      ]);
    }
    return saved;
  }

  Future<void> delete(LocalNovel novel) async {
    _pendingOffsets.remove(novel.id);
    await ref.read(localNovelRepositoryProvider).delete(novel);
    final current = state.value;
    if (current == null) return;
    state = AsyncData([
      for (final item in current)
        if (item.id != novel.id) item,
    ]);
  }

  /// Persists [offset] and updates the in-memory list entry immediately so
  /// returning to the library reflects the new reading progress without a
  /// manual reload.
  Future<void> updateReadOffset(int id, int offset) async {
    _pendingOffsets[id] = offset;
    await ref.read(localNovelRepositoryProvider).updateReadOffset(id, offset);
    final current = state.value;
    if (current == null) return;
    _pendingOffsets.remove(id);
    state = AsyncData([
      for (final item in current)
        if (item.id == id) item.withReadOffset(offset) else item,
    ]);
  }
}

final localNovelStoreProvider =
    AsyncNotifierProvider<LocalNovelStore, List<LocalNovel>>(
      LocalNovelStore.new,
      retry: noRetry,
    );
