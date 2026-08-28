import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_store.dart';
import '../platform/media_store_channel.dart';
import '../settings/settings_controller.dart';
import '../network/compat/network_providers.dart';
import '../network/compat/policy_download_transport.dart';
import 'download_manager.dart';
import 'download_recovery.dart';
import 'download_sink.dart';
import 'download_transport.dart';
import '../ugoira/ugoira_recovery.dart';

/// One app-scoped strict Pixiv media transport shared by downloads, Ugoira
/// metadata consumers and future compatibility routing.
final pixivMediaTransportProvider = Provider<DownloadTransport>((ref) {
  final transport = PolicyDownloadTransport(
    policy: ref.watch(networkAccessPolicyProvider),
  );
  ref.onDispose(() async => transport.dispose());
  return transport;
});

final downloadSinkFactoryProvider = Provider<DownloadSinkFactory>((ref) {
  return MediaStoreSinkFactory(const MethodChannelMediaStoreSession());
});

/// Ugoira post-process records use a separate namespace so a recovered GIF
/// export is never retried as if its synthetic URL were a normal download.
final ugoiraRecoveryStoreProvider = Provider<DownloadRecoveryStore>((ref) {
  return PreferencesDownloadRecoveryStore(
    storageKey: kUgoiraRecoveryStorageKey,
  );
});

/// App-scoped manager: shared pooled transport + MediaStore pending sinks.
final downloadManagerProvider = Provider<DownloadManager>((ref) {
  final manager = DownloadManager(
    transport: ref.watch(pixivMediaTransportProvider),
    sinkFactory: ref.watch(downloadSinkFactoryProvider),
    maxConcurrent: ref.read(maxDownloadCountProvider),
    requireOwnedSubmissions: true,
    recoveryStore: PreferencesDownloadRecoveryStore(),
    submissionContext: () {
      final accountState = ref.read(accountStoreProvider).asData?.value;
      final account = accountState?.usableCurrent;
      if (accountState == null || account == null) return null;
      return DownloadSubmissionContext(
        accountId: account.id,
        credentialRevision: accountState.credentialRevision,
        networkRevision: ref.read(networkAccessPolicyProvider).revision,
      );
    },
  );
  // Keep running jobs intact while applying the new cap to subsequent
  // dispatches. The manager owns the scheduler; settings only supplies the
  // typed configuration value.
  ref.listen<int>(maxDownloadCountProvider, (_, next) {
    manager.maxConcurrent = next;
  });
  Future<void> recoverMedia() async {
    await recoverUgoiraExports(
      store: ref.read(ugoiraRecoveryStoreProvider),
      sinkFactory: ref.read(downloadSinkFactoryProvider),
    );
    await manager.recover();
  }

  ref.listen<AsyncValue<AccountState>>(accountStoreProvider, (_, next) {
    manager.invalidateStaleSubmissions();
    unawaited(recoverMedia());
  }, fireImmediately: true);
  ref.onDispose(manager.dispose);
  return manager;
});
