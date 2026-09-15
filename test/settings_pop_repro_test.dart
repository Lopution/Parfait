import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:go_router/go_router.dart';
import 'package:pixiv_func/app/app.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/credential.dart';
import 'package:pixiv_func/core/download/download_manager.dart';
import 'package:pixiv_func/core/download/download_providers.dart';
import 'package:pixiv_func/core/download/download_sink.dart';
import 'package:pixiv_func/core/network/compat/network_policy.dart';
import 'package:pixiv_func/core/network/compat/network_providers.dart';
import 'package:pixiv_func/core/network/compat/pixiv_network_factory.dart';
import 'package:pixiv_func/core/settings/app_settings.dart';
import 'package:pixiv_func/core/settings/settings_controller.dart';
import 'package:pixiv_func/core/settings/settings_repository.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'download_manager_test.dart';
import 'helpers/fake_account.dart';
import 'helpers/test_preferences.dart';

class _MemRepo implements SettingsRepository {
  _MemRepo(this.value);
  AppSettings value;
  @override
  Future<AppSettings> load() async => value;
  @override
  Future<void> save(AppSettings settings) async => value = settings;
}

void main() {
  testWidgets(
    'settings change on a pushed page must not jump to /recommended',
    (tester) async {
      SharedPreferencesAsyncPlatform.instance = memoryPreferences();
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('pixivfunc/widget'),
        (call) async => false,
      );

      final container = ProviderContainer(
        overrides: [
          ...accountProviderOverrides(
            credentialStore: FakeCredentialStore(
              values: const {
                '100': Credential(accessToken: 'a', refreshToken: 'r'),
              },
            ),
            metadataRepository: FakeAccountMetadataRepository(
              accounts: const [Account(id: '100', userId: 100, name: 't')],
              currentId: '100',
            ),
          ),
          settingsRepositoryProvider.overrideWithValue(
            _MemRepo(AppSettings.defaults().copyWith(guideCompleted: true)),
          ),
          pixivNetworkFactoryProvider.overrideWithValue(
            PixivNetworkFactory(
              NetworkAccessPolicy(
                clientFactory: (route, host, purpose) =>
                    MockClient((_) async => http.Response('{}', 200)),
              ),
            ),
          ),
          downloadManagerProvider.overrideWithValue(
            DownloadManager(
              transport: FakeTransport(),
              sinkFactory: MemorySinkFactory(),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const PixivFuncApp(),
        ),
      );
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
      await tester.pumpAndSettle();

      final navEl = tester.element(find.byType(Navigator).first);
      final router = GoRouter.of(navEl);

      // Simulate the reported path: user is on /me (a declarative branch
      // switch — updates routeInformationProvider), then opens settings
      // (imperative push — does NOT update it). The gate must read the live
      // match, not the stale info-provider value.
      router.go('/me');
      await tester.pumpAndSettle();
      unawaited(router.push('/settings/theme'));
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/settings/theme');
      // The stale read the old code relied on:
      expect(
        router.routeInformationProvider.value.uri.path,
        isNot('/settings/theme'),
      );

      await container.read(settingsProvider.notifier).selectTheme(1);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/settings/theme');
    },
  );
}
