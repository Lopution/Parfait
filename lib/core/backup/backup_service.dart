import 'dart:io';
import 'dart:ui' show Rect;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart' as share_plus;

import '../auth/account_store.dart';
import '../history/history_models.dart';
import '../history/history_repository.dart';
import '../mute/mute_models.dart';
import '../mute/mute_store.dart';
import '../platform/app_storage_paths.dart';
import '../platform/platform_caps.dart';
import '../platform/saf_tree.dart';
import '../settings/app_settings.dart';
import '../settings/settings_controller.dart';
import 'backup_envelope.dart';

/// Platform file-share boundary for iOS backup export, where `file_selector_ios`
/// does not implement directory picking. Returns `false` when the user
/// dismissed the share sheet and `true` otherwise.
abstract interface class BackupShareExporter {
  Future<bool> shareFile({
    required String path,
    required String fileName,
    required String mimeType,
    Rect? sharePositionOrigin,
  });
}

class SharePlusBackupExporter implements BackupShareExporter {
  const SharePlusBackupExporter();

  @override
  Future<bool> shareFile({
    required String path,
    required String fileName,
    required String mimeType,
    Rect? sharePositionOrigin,
  }) async {
    final result = await share_plus.SharePlus.instance.share(
      share_plus.ShareParams(
        files: [share_plus.XFile(path, mimeType: mimeType, name: fileName)],
        subject: fileName,
        sharePositionOrigin: sharePositionOrigin,
      ),
    );
    return result.status != share_plus.ShareResultStatus.dismissed;
  }
}

final backupShareExporterProvider = Provider<BackupShareExporter?>((ref) {
  return ref.watch(platformCapsProvider).isIOS
      ? const SharePlusBackupExporter()
      : null;
});

/// What a completed export produced — the opaque SAF uri plus the display
/// name the user can find in the chosen directory.
typedef BackupExportResult = ({String uri, String fileName});

/// Outcome counters shown to the user after an import.
class BackupImportResult {
  const BackupImportResult({
    required this.tagsAdded,
    required this.usersAdded,
    required this.workMutesChanged,
    required this.historyRows,
  });

  final int tagsAdded;
  final int usersAdded;
  final int workMutesChanged;
  final int historyRows;
}

/// Export/import orchestration for the `pixivfunc.backup.v1` document.
///
/// Writes stay inside existing boundaries: settings go through the
/// serialized settings writer, server mute tags/users go through
/// [MuteStore] (which talks to `/v1/mute/edit`), work mutes stay local per
/// account, and history goes through [HistoryRepository]. Nothing here
/// touches credentials — `AppSettings.toJson` already serializes
/// `SecretSettingRef` ids only.
class BackupService {
  BackupService({
    required Future<AppSettings> Function() settingsReader,
    required Future<void> Function(AppSettings) settingsWriter,
    required MuteStore muteStore,
    required MuteState Function() muteStateReader,
    required HistoryRepository historyRepository,
    required SafTreePicker treePicker,
    required SafDocumentSinkFactory sinkFactory,
    required String? Function() currentAccountId,
    BackupShareExporter? shareExporter,
    Future<Directory> Function()? tempDirResolver,
    DateTime Function()? now,
  }) : _readSettings = settingsReader,
       _writeSettings = settingsWriter,
       _muteStore = muteStore,
       _readMuteState = muteStateReader,
       _history = historyRepository,
       _treePicker = treePicker,
       _sinkFactory = sinkFactory,
       _currentAccountId = currentAccountId,
       _shareExporter = shareExporter,
       _resolveTempDir =
           tempDirResolver ?? AppStoragePaths.active.resolveTempDir,
       _now = now ?? DateTime.now;

  final Future<AppSettings> Function() _readSettings;
  final Future<void> Function(AppSettings) _writeSettings;
  final MuteStore _muteStore;
  final MuteState Function() _readMuteState;
  final HistoryRepository _history;
  final SafTreePicker _treePicker;
  final SafDocumentSinkFactory _sinkFactory;
  final String? Function() _currentAccountId;
  final BackupShareExporter? _shareExporter;
  final Future<Directory> Function() _resolveTempDir;
  final DateTime Function() _now;

  /// Builds the document for the current state and writes it either through
  /// the iOS share sheet (when a [BackupShareExporter] is configured) or into
  /// a user-picked SAF/desktop directory. Returns the created document's uri
  /// and name, or null when cancelled.
  Future<BackupExportResult?> export({Rect? sharePositionOrigin}) async {
    final envelope = await _collect();
    final exporter = _shareExporter;
    if (exporter != null) {
      return _exportViaShare(
        envelope,
        exporter: exporter,
        sharePositionOrigin: sharePositionOrigin,
      );
    }
    final treeUri = await _treePicker.pickTree();
    if (treeUri == null) return null;
    final fileName = BackupEnvelope.fileName(_now());
    final sink = await _sinkFactory.create(
      treeUri: treeUri,
      displayName: fileName,
      mimeType: BackupEnvelope.mimeType,
    );
    try {
      await sink.write(envelope.encode());
      await sink.close();
    } on Object {
      // Best-effort: a cleanup failure must not mask the write error.
      try {
        await sink.delete();
      } on Object {
        // The document is already unusable; keep the original error.
      }
      rethrow;
    }
    return (uri: sink.uri, fileName: fileName);
  }

  Future<BackupExportResult?> _exportViaShare(
    BackupEnvelope envelope, {
    required BackupShareExporter exporter,
    Rect? sharePositionOrigin,
  }) async {
    final fileName = BackupEnvelope.fileName(_now());
    final tempDir = await _resolveTempDir();
    final exportDir = Directory(p.join(tempDir.path, 'backup_exports'));
    await exportDir.create(recursive: true);
    await _sweepStaleExports(exportDir);
    final target = File(p.join(exportDir.path, fileName));
    final bool shared;
    try {
      await target.writeAsBytes(envelope.encode(), flush: true);
      shared = await exporter.shareFile(
        path: target.path,
        fileName: fileName,
        mimeType: BackupEnvelope.mimeType,
        sharePositionOrigin: sharePositionOrigin,
      );
    } on Object {
      await _deleteQuietly(target);
      rethrow;
    }
    if (!shared) {
      await _deleteQuietly(target);
      return null;
    }
    return (uri: Uri.file(target.path).toString(), fileName: fileName);
  }

  static Future<void> _sweepStaleExports(Directory exportDir) async {
    try {
      await for (final entity in exportDir.list()) {
        if (entity is File) await _deleteQuietly(entity);
      }
    } on Object {
      // Best-effort sweep; never block the new export.
    }
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on Object {
      // Best-effort cleanup must not mask primary errors.
    }
  }

  Future<BackupEnvelope> _collect() async {
    final accountId = _currentAccountId();
    // A cold MuteStore answers with the pre-hydrate empty set; wait for the
    // merge so the exported set is the effective one.
    await _muteStore.ensureHydrated();
    final mute = _readMuteState();
    return BackupEnvelope(
      exportedAt: _now().toUtc(),
      accountId: accountId,
      settings: (await _readSettings()).toJson(),
      muteTags: mute.tags,
      muteUsers: mute.users.values.toList(),
      muteWorks: mute.works,
      history: accountId == null
          ? const []
          : await _history.all(accountId: accountId),
    );
  }

  /// Applies a parsed document under [strategy]. Order matters: the
  /// fallible server-bound mute edits run before the local settings and
  /// history writes, so a network failure reports cleanly instead of
  /// half-applying local state.
  ///
  /// Requires a usable account — mutes and history are account-scoped.
  Future<BackupImportResult> apply(
    BackupEnvelope envelope,
    BackupImportStrategy strategy,
  ) async {
    final accountId = _currentAccountId();
    if (accountId == null) {
      throw const BackupImportException(
        BackupImportErrorCode.accountRequired,
        'a signed-in account is required to import',
      );
    }
    // Reads below must see the merged server+local set, not a cold store.
    await _muteStore.ensureHydrated();

    var tagsAdded = 0;
    var usersAdded = 0;
    var workMutesChanged = 0;

    for (final tag in envelope.muteTags) {
      if (_readMuteState().isTagMuted(tag)) continue;
      await _muteStore.toggleTag(tag);
      tagsAdded++;
    }
    for (final user in envelope.muteUsers) {
      if (_readMuteState().isUserMuted(user.userId)) continue;
      await _muteStore.toggleUser(user);
      usersAdded++;
    }

    final currentWorks = _readMuteState().works;
    for (final work in envelope.muteWorks.values) {
      final current = currentWorks[work.illustId];
      if (current == null) {
        await _muteStore.muteWork(work);
        workMutesChanged++;
        continue;
      }
      // Under either strategy an entry kept from before titles were stored
      // takes them from the file; one that has them keeps its own. Not a
      // mute change, so not counted.
      final filled = current.filledFrom(work);
      if (filled != current) await _muteStore.muteWork(filled);
    }
    if (strategy == BackupImportStrategy.overwrite) {
      for (final workId in currentWorks.keys) {
        if (envelope.muteWorks.containsKey(workId)) continue;
        await _muteStore.unmuteWork(workId);
        workMutesChanged++;
      }
    }

    await _writeSettings(
      AppSettings.fromJson(envelope.settings, fallback: await _readSettings()),
    );

    final historyRows = switch (strategy) {
      BackupImportStrategy.merge => await _mergeHistory(accountId, envelope),
      BackupImportStrategy.overwrite => await _replaceHistory(
        accountId,
        envelope,
      ),
    };

    return BackupImportResult(
      tagsAdded: tagsAdded,
      usersAdded: usersAdded,
      workMutesChanged: workMutesChanged,
      historyRows: historyRows,
    );
  }

  /// Upsert per identity, keeping the newer `last_viewed_at` when a row
  /// already exists locally.
  Future<int> _mergeHistory(String accountId, BackupEnvelope envelope) async {
    var written = 0;
    for (final record in envelope.history) {
      final existing = await _history.find(
        accountId: accountId,
        contentType: record.contentType,
        contentId: record.contentId,
      );
      if (existing != null &&
          !record.lastViewedAt.isAfter(existing.lastViewedAt)) {
        continue;
      }
      await _history.upsert(_forAccount(record, accountId));
      written++;
    }
    return written;
  }

  Future<int> _replaceHistory(String accountId, BackupEnvelope envelope) async {
    await _history.replaceAll(accountId, [
      for (final record in envelope.history) _forAccount(record, accountId),
    ]);
    return envelope.history.length;
  }

  /// Imported rows always land in the current account, regardless of which
  /// account exported the file.
  static HistoryRecord _forAccount(HistoryRecord record, String accountId) {
    return HistoryRecord(
      accountId: accountId,
      contentType: record.contentType,
      contentId: record.contentId,
      lastViewedAt: record.lastViewedAt,
      snapshot: record.snapshot,
      visibleDuration: record.visibleDuration,
      snapshotVersion: record.snapshotVersion,
    );
  }
}

final backupServiceProvider = Provider<BackupService>((ref) {
  return BackupService(
    settingsReader: () => ref.read(settingsProvider.future),
    settingsWriter: (settings) =>
        ref.read(settingsProvider.notifier).replaceAll(settings),
    muteStore: ref.read(muteStoreProvider.notifier),
    muteStateReader: () => ref.read(muteStoreProvider),
    historyRepository: ref.watch(historyRepositoryProvider),
    treePicker: ref.watch(safTreePickerProvider),
    sinkFactory: ref.watch(safDocumentSinkFactoryProvider),
    currentAccountId: () =>
        ref.read(accountStoreProvider).value?.usableCurrent?.id,
    shareExporter: ref.watch(backupShareExporterProvider),
    tempDirResolver: ref.watch(appStoragePathsProvider).resolveTempDir,
  );
});
