import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_store.dart';
import '../network/compat/network_contracts.dart';
import '../network/compat/network_providers.dart';
import '../network/pixiv_http_client.dart';
import 'widget_feed_loader.dart';
import 'widget_snapshot_store.dart';

/// Method channel the headless entrypoint reports through. The native worker
/// listens for exactly one result message per run.
const MethodChannel widgetBackgroundChannel = MethodChannel(
  'pixivfunc/widget_background',
);

/// Runs the headless widget generation pass. Called from `main.dart`'s
/// `widgetBackgroundMain` entrypoint (the engine resolves entrypoints
/// against the root library).
///
/// It boots the same provider graph as the app — shared AccountStore,
/// PixivHttpClient, TokenRefreshGate and NetworkAccessPolicy — and writes the
/// secret-free snapshot. No credential, token or account id crosses the
/// channel back to native; only the outcome classification.
Future<void> runWidgetBackground() async {
  WidgetsFlutterBinding.ensureInitialized();
  debugPrint('WidgetBackground: entered');
  final container = ProviderContainer();
  try {
    final loader = WidgetFeedLoader(
      apiClient: container.read(pixivHttpClientProvider),
      imageClient: container
          .read(pixivNetworkFactoryProvider)
          .client(PixivDestinationPurpose.image),
      accountStore: container.read(accountStoreProvider.notifier),
      credentialStore: container.read(credentialStoreProvider),
      storeFactory: WidgetSnapshotStore.standard,
      networkRevision: () =>
          container.read(networkAccessPolicyProvider).revision,
    );
    debugPrint('WidgetBackground: loader built');
    final result = await loader.load().timeout(const Duration(minutes: 4));
    debugPrint('WidgetBackground: outcome ${result.outcome.name}');
    await _report(result.outcome.name);
  } on TimeoutException {
    await _report('transientFailure');
  } on Object catch (error) {
    // The worker must always receive a classification; any unexpected
    // failure is treated as transient so the bounded retry path stays the
    // single recovery story.
    debugPrint('WidgetBackground: failed ${error.runtimeType}: $error');
    await _report('transientFailure');
  } finally {
    container.dispose();
  }
}

Future<void> _report(String outcome) async {
  try {
    await widgetBackgroundChannel.invokeMethod<void>('result', <String, String>{
      'outcome': outcome,
    });
  } on MissingPluginException {
    // A non-Android test or a worker that has already been torn down has no
    // native receiver; keep the condition observable without leaking data.
    debugPrint('WidgetBackground: result channel unavailable');
  } on PlatformException catch (error) {
    debugPrint(
      'WidgetBackground: result channel failed: ${error.code}: ${error.message}',
    );
  }
}
