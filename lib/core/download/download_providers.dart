import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../settings/shared_preferences.dart';

import '../auth/account_store.dart';
import '../platform/desktop_file_sink.dart';
import '../platform/media_store_channel.dart';
import '../platform/platform_caps.dart';
import '../platform/saf_tree.dart';
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
  // D5: the factory routes each submission to its immutable destination
  // snapshot (built-in/custom album via MediaStore, or the SAF tree).
  //
  // This provider must not watch [downloadDestinationProvider]. Watching the
  // setting would dispose the app-scoped manager whenever the user changes
  // the destination, losing queued/recoverable jobs. The manager passes the
  // captured destination to every begin call instead.
  return DestinationAwareSinkFactory(
    mediaStore: MediaStoreSinkFactory(
      ref.watch(platformCapsProvider).isAndroid
          ? const MethodChannelMediaStoreSession()
          : const DesktopFileMediaStoreSession(),
    ),
    saf: ref.watch(safDocumentSinkFactoryProvider),
  );
});

/// Ugoira post-process records use a separate namespace so a recovered GIF
/// export is never retried as if its synthetic URL were a normal download.
final ugoiraRecoveryStoreProvider = Provider<DownloadRecoveryStore>((ref) {
  return PreferencesDownloadRecoveryStore(
    preferences: ref.watch(sharedPreferencesProvider),
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
    // D5: authenticated product downloads may target the selected custom
    // album or SAF tree. Account and destination identity checks remain in
    // force; this flag only removes the obsolete builtin-only guard.
    enforceDefaultDestination: false,
    recoveryStore: PreferencesDownloadRecoveryStore(
      preferences: ref.watch(sharedPreferencesProvider),
    ),
    submissionContext: () {
      final accountState = ref.read(accountStoreProvider).asData?.value;
      final account = accountState?.usableCurrent;
      if (accountState == null || account == null) return null;
      // C4: the stable owner is accountId + destination; a token refresh
      // (credentialRevision) never orphans an in-flight task.
      return DownloadSubmissionContext(
        accountId: account.id,
        destination: ref.read(downloadDestinationProvider),
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
