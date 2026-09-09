import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/auth/credential.dart';
import 'package:pixiv_func/core/auth/credential_store.dart';
import 'package:pixiv_func/core/auth/oauth_service.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:pixiv_func/core/widget/widget_channel.dart';
import 'package:pixiv_func/core/widget/widget_coordinator.dart';
import 'package:pixiv_func/core/widget/widget_feed_loader.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/fake_account.dart';
import 'helpers/test_preferences.dart';

class _Gate implements WidgetInstanceGate {
  _Gate(this.hasInstances);

  bool hasInstances;
  var probes = 0;

  @override
  Future<bool> hasAnyInstances() async {
    probes += 1;
    return hasInstances;
  }
}

class _CountingLoader extends WidgetFeedLoader {
  // The same store instances are also handed to PixivHttpClient, so they
  // cannot be `super.` parameters.
  // ignore: use_super_parameters
  _CountingLoader({
    required AccountStore accountStore,
    required CredentialStore credentialStore,
    required OAuthService oauthService,
  }) : super(
         apiClient: PixivHttpClient(
           client: MockClient((_) async => http.Response('{}', 500)),
           accountStore: accountStore,
           credentialStore: credentialStore,
           oauthService: oauthService,
         ),
         imageClient: MockClient((_) async => http.Response('', 500)),
         accountStore: accountStore,
         credentialStore: credentialStore,
         storeFactory: () => throw StateError('widget snapshot write'),
       );

  var loads = 0;

  @override
  Future<WidgetFeedResult> load() async {
    loads += 1;
    return const WidgetFeedResult(WidgetFeedOutcome.noAccount);
  }
}

const _widgetChannel = MethodChannel('pixivfunc/widget');

Future<void> _flushPasses() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<(ProviderContainer, _CountingLoader, WidgetCoordinator, _Gate)>
_makeWorld({
  required bool hasWidget,
  List<Account> accounts = const [
    Account(id: '100', userId: 100, name: 'user100'),
  ],
  String? currentId = '100',
}) async {
  SharedPreferencesAsyncPlatform.instance =
      memoryPreferences();
  final credentials = FakeCredentialStore();
  for (final account in accounts) {
    credentials.seed(
      account.id,
      Credential(
        accessToken: 'access-${account.id}',
        refreshToken: 'refresh-${account.id}',
      ),
    );
  }
  final gate = _Gate(hasWidget);
  late _CountingLoader loader;
  late WidgetCoordinator coordinator;
  final container = ProviderContainer(
    overrides: [
      credentialStoreProvider.overrideWithValue(credentials),
      accountMetadataRepositoryProvider.overrideWithValue(
        FakeAccountMetadataRepository(accounts: accounts, currentId: currentId),
      ),
      oauthServiceProvider.overrideWithValue(
        OAuthService(client: MockClient((_) async => http.Response('{}', 500))),
      ),
      widgetFeedLoaderProvider.overrideWith((ref) {
        loader = _CountingLoader(
          accountStore: ref.read(accountStoreProvider.notifier),
          credentialStore: credentials,
          oauthService: ref.read(oauthServiceProvider),
        );
        return loader;
      }),
      widgetCoordinatorProvider.overrideWith((ref) {
        coordinator = WidgetCoordinator(ref, gate);
        ref.onDispose(coordinator.dispose);
        return coordinator;
      }),
    ],
  );
  addTearDown(container.dispose);
  await container.read(accountStoreProvider.future);
  container.read(widgetFeedLoaderProvider);
  return (container, loader, container.read(widgetCoordinatorProvider), gate);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final channelCalls = <String>[];

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        memoryPreferences();
    channelCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_widgetChannel, (call) async {
          channelCalls.add(call.method);
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_widgetChannel, null);
  });

  test(
    'closed widget gate starts nothing and issues no loads or native requests',
    () async {
      final (container, loader, coordinator, gate) = await _makeWorld(
        hasWidget: false,
      );

      await coordinator.start();
      await coordinator.ensureStarted();
      await _flushPasses();

      expect(gate.probes, 2);
      expect(loader.loads, 0);
      expect(channelCalls, isEmpty);

      await container
          .read(accountStoreProvider.notifier)
          .upsertAccount(
            const Account(id: '200', userId: 200, name: 'user200'),
            const Credential(accessToken: 'a-200', refreshToken: 'r-200'),
          );
      await _flushPasses();
      expect(loader.loads, 0);
      expect(channelCalls, isEmpty);
    },
  );

  test(
    'open widget gate keeps the startup pass and account-change contract',
    () async {
      final (container, loader, coordinator, _) = await _makeWorld(
        hasWidget: true,
      );

      await coordinator.start();
      await _flushPasses();

      expect(loader.loads, 1);
      expect(channelCalls, contains('clearSnapshot'));

      final loadsAfterStart = loader.loads;
      await container
          .read(accountStoreProvider.notifier)
          .upsertAccount(
            const Account(id: '200', userId: 200, name: 'user200'),
            const Credential(accessToken: 'a-200', refreshToken: 'r-200'),
          );
      await _flushPasses();
      expect(loader.loads, greaterThan(loadsAfterStart));
    },
  );

  test(
    'ensureStarted starts after a false-to-true lifecycle recheck',
    () async {
      final (_, loader, coordinator, gate) = await _makeWorld(hasWidget: false);

      await coordinator.start();
      await _flushPasses();
      expect(loader.loads, 0);

      gate.hasInstances = true;
      await coordinator.ensureStarted();
      await _flushPasses();

      expect(loader.loads, 1);
      expect(channelCalls, contains('clearSnapshot'));
    },
  );
}
