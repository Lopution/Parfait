/// Local-novel library state: the indexed list plus import/delete actions.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
      return () async {
        final file = await openFile(
          acceptedTypeGroups: [
            const XTypeGroup(label: 'TXT', extensions: ['txt']),
          ],
        );
        if (file == null) return null;
        return (file.name, await file.readAsBytes());
      };
    });

class LocalNovelStore extends AsyncNotifier<List<LocalNovel>> {
  @override
  Future<List<LocalNovel>> build() {
    return ref.watch(localNovelRepositoryProvider).list();
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

  Future<void> delete(LocalNovel novel) async {
    await ref.read(localNovelRepositoryProvider).delete(novel);
    final current = state.value;
    if (current == null) return;
    state = AsyncData([
      for (final item in current)
        if (item.id != novel.id) item,
    ]);
  }
}

final localNovelStoreProvider =
    AsyncNotifierProvider<LocalNovelStore, List<LocalNovel>>(
      LocalNovelStore.new,
    );
