import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../network/compat/network_contracts.dart';
import '../network/compat/network_policy.dart';
import '../network/compat/network_providers.dart';
import '../settings/app_settings.dart';
import '../settings/settings_controller.dart';
import 'disk_image_cache.dart';
import 'image_worker.dart';
import 'image_worker_client.dart';
import 'image_worker_protocol.dart';

/// The app's image worker. Built once: the handle never depends on a
/// setting, so `WorkerImageProvider` keys and the worker's demand stay
/// stable. Settings, the network identity and the mirror reach the running
/// isolate as config pushes; what it learns about routes comes back into
/// the main isolate's stores, the only writers of those preferences.
final imageWorkerProvider = Provider<ImageWorker>((ref) {
  final fastRoutes = ref.watch(fastRouteStoreProvider);
  final routeKinds = ref.watch(routeKindStoreProvider);

  Future<ImageWorkerConfig> config() async {
    final policy = ref.read(networkAccessPolicyProvider);
    final identity = policy.revision.networkIdentity;
    final learned = await fastRoutes.learned();
    return ImageWorkerConfig(
      imageSource:
          ref.read(settingsProvider).value?.imageSource ??
          AppSettings.defaultImageSource,
      autoWinnerHost: ref.read(autoImageSourceWinnerProvider),
      mode: policy.mode.name,
      networkIdentity: identity,
      echFrontHost: ref.read(echFrontHostProvider),
      dohEndpoints: ref.read(dohEnabledProvider)
          ? ref.read(dohEndpointsProvider)
          : const [],
      bootstrapNoSniEnabled: true,
      learnedFastRoutes: {
        for (final MapEntry(:key, :value) in learned.entries)
          key: value.address,
      },
      routeKinds: await routeKinds.kindsFor(identity) ?? const {},
    );
  }

  final worker =
      ImageWorker(
          config: config,
          start: (config, demand) async {
            final temp = await getTemporaryDirectory();
            return ImageWorkerClient.start(
              config: config,
              cacheDir: p.join(temp.path, DiskImageCache.directoryName),
              demand: demand,
            );
          },
        )
        ..onFastRouteLearned = (host, address) {
          final parsed = InternetAddress.tryParse(address);
          if (parsed != null) unawaited(fastRoutes.remember(host, parsed));
        }
        ..onRouteKindLearned = (identity, group, kind) {
          unawaited(routeKinds.remember(identity, group, kind));
        }
        // The main policy owns the auto-source re-race.
        ..onRouteExhausted = (host) {
          ref
              .read(networkAccessPolicyProvider)
              .onImageHostExhausted
              ?.call(host);
        };

  void push() => unawaited(worker.configChanged());
  // A policy rebuild is a DoH, ECH, mode or allowlist change; the revision
  // hook is a network identity change on the live policy.
  ref
    ..listen<NetworkAccessPolicy>(networkAccessPolicyProvider, (_, policy) {
      policy.onRevisionAdvanced = (NetworkRevision _) => push();
      push();
    }, fireImmediately: true)
    ..listen(imageMirrorProvider, (_, _) => push())
    ..onDispose(() => unawaited(worker.dispose()));
  return worker;
});
