import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../settings/preference_keys.dart';
import '../settings/shared_preferences.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../download/download_manager.dart';
import '../download/download_recovery.dart';
import '../download/download_destination.dart';
import '../download/download_request.dart';
import '../download/pixiv_download_transport.dart';
import 'update_download.dart';
import 'update_service.dart';
import '../network/http_client_providers.dart';

const _updaterSubmissionContext = DownloadSubmissionContext(
  accountId: 'pixivfunc-updater',
  // The updater never renders in user album lists; the custom identity keeps
  // its recovery namespace disjoint from product downloads while staying a
  // valid D5 destination value.
  destination: DownloadDestination.customAlbum('app-private-updates'),
);

/// The updater has its own exact-host transport and recovery namespace. It
/// never inherits Pixiv cookies, account ownership or image CDN policy.
final updateServiceProvider = FutureProvider<UpdateService>((ref) async {
  final platform = MethodChannelUpdatePlatform();
  final capability = await platform.capability();
  if (capability.storeManaged || capability.flavor == UpdateFlavor.fdroid) {
    // Do not even construct an HttpClient in the F-Droid graph. The native
    // capability is checked before path/network resources are created.
    return UpdateService(
      manifestTransport: const _DisabledUpdateManifestTransport(),
      platform: platform,
    );
  }
  final supportDirectory = await getApplicationSupportDirectory();
  final updateDirectory = Directory(p.join(supportDirectory.path, 'updates'));
  final manifestTransport = HttpUpdateManifestTransport(
    client: ref.watch(resolverHttpClientProvider),
  );
  final apkTransport = HttpDownloadTransport(
    httpClient: ref.watch(thirdPartyHttpClientProvider),
    allowedHosts: kUpdateDownloadHosts,
    strictUrlPolicy: true,
  );
  final manager = DownloadManager(
    transport: apkTransport,
    sinkFactory: UpdateFileSinkFactory(updateDirectory),
    maxConcurrent: 1,
    recoveryStore: PreferencesDownloadRecoveryStore(
      preferences: ref.watch(sharedPreferencesProvider),
      storageKey: PreferenceKeys.updateManagerRecovery,
    ),
    submissionContext: () => _updaterSubmissionContext,
    enforceDefaultDestination: false,
  );
  ref.onDispose(() {
    unawaited(manifestTransport.dispose());
    unawaited(manager.dispose());
  });

  // Recovery only restores the exact updater owner identity. It does not
  // resume a request automatically; UpdateService requires confirmation and
  // then reuses the persisted task/path when it is still valid.
  await manager.recover(currentContext: _updaterSubmissionContext);
  final downloader = UpdateDownloadCoordinator(
    manager: manager,
    platform: platform,
    directory: updateDirectory,
    stateStore: PreferencesUpdateDownloadStateStore(
      preferences: ref.watch(sharedPreferencesProvider),
    ),
  );
  return UpdateService(
    manifestTransport: manifestTransport,
    platform: platform,
    downloader: downloader,
  );
});

class _DisabledUpdateManifestTransport implements UpdateManifestTransport {
  const _DisabledUpdateManifestTransport();

  @override
  Future<UpdateHttpResponse> fetch(Uri uri) =>
      throw const UpdateTransportException('updates_disabled');
}
