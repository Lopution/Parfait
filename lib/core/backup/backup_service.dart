import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_store.dart';
import '../history/history_models.dart';
import '../history/history_repository.dart';
import '../mute/mute_models.dart';
import '../mute/mute_store.dart';
import '../platform/saf_tree.dart';
import '../settings/app_settings.dart';
import '../settings/settings_controller.dart';
import 'backup_envelope.dart';

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
    DateTime Function()? now,
  }) : _readSettings = settingsReader,
       _writeSettings = settingsWriter,
       _muteStore = muteStore,
       _readMuteState = muteStateReader,
       _history = historyRepository,
       _treePicker = treePicker,
       _sinkFactory = sinkFactory,
       _currentAccountId = currentAccountId,
       _now = now ?? DateTime.now;

  final Future<AppSettings> Function() _readSettings;
  final Future<void> Function(AppSettings) _writeSettings;
  final MuteStore _muteStore;
  final MuteState Function() _readMuteState;
  final HistoryRepository _history;
  final SafTreePicker _treePicker;
  final SafDocumentSinkFactory _sinkFactory;
  final String? Function() _currentAccountId;
  final DateTime Function() _now;

  /// Builds the document for the current state, asks for a destination
  /// tree, and streams the JSON into it. Returns the created document uri,
  /// or null when the picker was cancelled.
  Future<String?> export() async {
    final envelope = await _collect();
    final treeUri = await _treePicker.pickTree();
    if (treeUri == null) return null;
    final sink = await _sinkFactory.create(
      treeUri: treeUri,
      displayName: BackupEnvelope.fileName(_now()),
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
    return sink.uri;
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
      muteWorkIds: mute.workIds,
      history: accountId == null ? const [] : await _readAllHistory(accountId),
    );
  }

  Future<List<HistoryRecord>> _readAllHistory(String accountId) async {
    final records = <HistoryRecord>[];
    var offset = 0;
    while (true) {
      final page = await _history.page(
        accountId: accountId,
        offset: offset,
        limit: 100,
      );
      records.addAll(page.records);
      if (!page.hasMore) return records;
      offset += page.records.length;
    }
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

    final currentWorks = _readMuteState().workIds;
    final wantedWorks = switch (strategy) {
      BackupImportStrategy.merge => envelope.muteWorkIds.difference(
        currentWorks,
      ),
      BackupImportStrategy.overwrite =>
        envelope.muteWorkIds
            .difference(currentWorks)
            .union(currentWorks.difference(envelope.muteWorkIds)),
    };
    for (final workId in wantedWorks) {
      await _muteStore.toggleWork(workId);
      workMutesChanged++;
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
    await _history.clear(accountId);
    for (final record in envelope.history) {
      await _history.upsert(_forAccount(record, accountId));
    }
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
  );
});
