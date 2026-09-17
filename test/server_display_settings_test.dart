import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/auth/credential.dart';
import 'package:pixiv_func/core/network/api_error.dart';
import 'package:pixiv_func/core/network/compat/network_contracts.dart';
import 'package:pixiv_func/core/network/compat/network_policy.dart';
import 'package:pixiv_func/core/network/compat/network_providers.dart';
import 'package:pixiv_func/core/network/compat/pixiv_network_factory.dart';
import 'package:pixiv_func/core/network/compat/secure_resolver.dart';
import 'package:pixiv_func/core/settings/server_display_settings.dart';
import 'package:pixiv_func/app/widgets/settings/settings_control.dart';
import 'package:pixiv_func/features/settings/pages/account_settings_page.dart';
import 'package:pixiv_func/l10n/app_localizations.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/fake_account.dart';
import 'helpers/test_preferences.dart';

class _StubResolver implements SecureResolver {
  @override
  Future<ResolvedHost> resolve(
    String host, {
    required NetworkRevision revision,
    NetworkCancelSignal? cancelSignal,
  }) async => ResolvedHost(
    host: host,
    addresses: [InternetAddress('93.184.216.34')],
    dnsSource: DnsSource.system,
    revision: revision,
    ttl: const Duration(seconds: 30),
  );

  @override
  Future<void> dispose() async {}
}

/// Maps `METHOD /path` to a response; a null entry yields 404 and a thrown
/// value propagates as a transport failure.
class _ApiScript {
  _ApiScript(this.routes);

  final Map<String, Object? Function(http.Request)> routes;
  final requests = <http.Request>[];

  http.Client asClient() => MockClient((request) async {
    requests.add(request);
    final handler = routes['${request.method} ${request.url.path}'];
    if (handler == null) {
      return http.Response('{"error":"unhandled"}', 404);
    }
    final outcome = handler(request);
    if (outcome == null) return http.Response('{}', 200);
    if (outcome is http.Response) return outcome;
    throw outcome;
  });
}

Future<(ProviderContainer, _ApiScript)> _world(
  _ApiScript script, {
  List<Account> accounts = const [
    Account(id: '100', userId: 100, name: 'user100'),
  ],
  String? currentId = '100',
}) async {
  SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  final container = ProviderContainer(
    overrides: [
      ...accountProviderOverrides(
        metadataRepository: FakeAccountMetadataRepository(
          accounts: accounts,
          currentId: currentId,
        ),
        credentialStore: FakeCredentialStore(
          values: {
            for (final account in accounts)
              account.id: const Credential(
                accessToken: 'access',
                refreshToken: 'refresh',
              ),
          },
        ),
      ),
      pixivNetworkFactoryProvider.overrideWithValue(
        PixivNetworkFactory(
          NetworkAccessPolicy(
            resolver: _StubResolver(),
            clientFactory: (route, host, purpose) => script.asClient(),
          ),
        ),
      ),
    ],
  );
  await container.read(accountStoreProvider.future);
  return (container, script);
}

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  });

  test('fetch reads both endpoints with the documented field names', () async {
    final (container, script) = await _world(
      _ApiScript({
        'GET /v1/user/ai-show-settings': (_) =>
            http.Response('{"show_ai":true}', 200),
        'GET /v1/user/restricted-mode-settings': (_) =>
            http.Response('{"is_restricted_mode_enabled":true}', 200),
      }),
    );
    addTearDown(container.dispose);
    final repository = container.read(serverDisplaySettingsRepositoryProvider);

    final settings = await repository.fetch();

    expect(settings.showAi, isTrue);
    expect(settings.restrictedMode, isTrue);
    expect(script.requests.map((r) => '${r.method} ${r.url.path}').toSet(), {
      'GET /v1/user/ai-show-settings',
      'GET /v1/user/restricted-mode-settings',
    });
    expect(
      script.requests.first.headers['Authorization'],
      'Bearer access',
      reason: 'the request stays inside the current account boundary',
    );
  });

  test('edits post the documented form fields and return the echo', () async {
    final (container, script) = await _world(
      _ApiScript({
        'POST /v1/user/ai-show-settings/edit': (request) {
          expect(request.bodyFields['show_ai'], 'false');
          return http.Response('{"show_ai":false}', 200);
        },
        'POST /v1/user/restricted-mode-settings': (request) {
          expect(request.bodyFields['is_restricted_mode_enabled'], 'true');
          return http.Response('{"is_restricted_mode_enabled":true}', 200);
        },
      }),
    );
    addTearDown(container.dispose);
    final repository = container.read(serverDisplaySettingsRepositoryProvider);

    expect(await repository.editAiShow(false), isFalse);
    expect(await repository.editRestrictedMode(true), isTrue);
    expect(
      script.requests.map((r) => r.url.path),
      containsAll([
        '/v1/user/ai-show-settings/edit',
        '/v1/user/restricted-mode-settings',
      ]),
    );
  });

  test('a malformed GET payload surfaces as a parse error', () async {
    final (container, _) = await _world(
      _ApiScript({
        'GET /v1/user/ai-show-settings': (_) =>
            http.Response('{"unexpected":true}', 200),
      }),
    );
    addTearDown(container.dispose);
    final repository = container.read(serverDisplaySettingsRepositoryProvider);

    await expectLater(repository.fetchAiShow(), throwsA(isA<ApiParseError>()));
  });

  test('a server error status surfaces as ApiHttpError', () async {
    final (container, _) = await _world(
      _ApiScript({
        'GET /v1/user/ai-show-settings': (_) => http.Response('', 500),
      }),
    );
    addTearDown(container.dispose);
    final repository = container.read(serverDisplaySettingsRepositoryProvider);

    await expectLater(repository.fetchAiShow(), throwsA(isA<ApiHttpError>()));
  });

  test(
    'controller fetches per account and confirms optimistic writes',
    () async {
      const showAi = true;
      var restricted = false;
      final (container, _) = await _world(
        _ApiScript({
          'GET /v1/user/ai-show-settings': (_) =>
              http.Response(jsonEncode({'show_ai': showAi}), 200),
          'GET /v1/user/restricted-mode-settings': (_) => http.Response(
            jsonEncode({'is_restricted_mode_enabled': restricted}),
            200,
          ),
          'POST /v1/user/restricted-mode-settings': (_) {
            restricted = true;
            return http.Response('{"is_restricted_mode_enabled":true}', 200);
          },
        }),
      );
      addTearDown(container.dispose);

      final initial = await container.read(
        serverDisplaySettingsProvider.future,
      );
      expect(initial, isA<ServerDisplaySettings>());
      expect(initial.showAi, isTrue);
      expect(initial.restrictedMode, isFalse);

      await container
          .read(serverDisplaySettingsProvider.notifier)
          .setRestrictedMode(true);
      expect(
        container.read(serverDisplaySettingsProvider).value!.restrictedMode,
        isTrue,
      );
    },
  );

  test('a failed write rolls the visible state back and rethrows', () async {
    final (container, _) = await _world(
      _ApiScript({
        'GET /v1/user/ai-show-settings': (_) =>
            http.Response('{"show_ai":true}', 200),
        'GET /v1/user/restricted-mode-settings': (_) =>
            http.Response('{"is_restricted_mode_enabled":false}', 200),
        'POST /v1/user/ai-show-settings/edit': (_) =>
            http.Response('{"error":"nope"}', 400),
      }),
    );
    addTearDown(container.dispose);

    await container.read(serverDisplaySettingsProvider.future);

    await expectLater(
      container.read(serverDisplaySettingsProvider.notifier).setShowAi(false),
      throwsA(isA<ApiHttpError>()),
    );
    expect(
      container.read(serverDisplaySettingsProvider).value!.showAi,
      isTrue,
      reason: 'the toggle snaps back to the last confirmed value',
    );
  });

  test('no usable account yields an unauthorized error state', () async {
    final (container, _) = await _world(
      _ApiScript({}),
      accounts: const [],
      currentId: null,
    );
    addTearDown(container.dispose);

    // `.future` stays pending while Riverpod's retry re-runs a failing
    // build, so observe the AsyncError emission instead.
    final errors = <Object?>[];
    final sub = container.listen(serverDisplaySettingsProvider, (_, next) {
      if (next case AsyncError<ServerDisplaySettings>(:final error)) {
        errors.add(error);
      }
    }, fireImmediately: true);
    addTearDown(sub.close);
    container.read(serverDisplaySettingsProvider);

    await Future.doWhile(() async {
      await Future<void>.delayed(Duration.zero);
      return errors.isEmpty;
    });
    expect(errors.first, isA<ApiUnauthorized>());
  });

  testWidgets(
    'account page toggles server settings and rolls back on failure',
    (tester) async {
      var restricted = false;
      final script = _ApiScript({
        'GET /v1/user/ai-show-settings': (_) =>
            http.Response('{"show_ai":true}', 200),
        'GET /v1/user/restricted-mode-settings': (_) => http.Response(
          jsonEncode({'is_restricted_mode_enabled': restricted}),
          200,
        ),
        'POST /v1/user/restricted-mode-settings': (_) {
          restricted = true;
          return http.Response('{"is_restricted_mode_enabled":true}', 200);
        },
        'POST /v1/user/ai-show-settings/edit': (_) =>
            http.Response('{"error":"nope"}', 500),
      });
      SharedPreferencesAsyncPlatform.instance = memoryPreferences();
      final container = ProviderContainer(
        overrides: [
          ...accountProviderOverrides(
            metadataRepository: FakeAccountMetadataRepository(
              accounts: const [
                Account(id: '100', userId: 100, name: 'user100'),
              ],
              currentId: '100',
            ),
            credentialStore: FakeCredentialStore(
              values: const {
                '100': Credential(
                  accessToken: 'access',
                  refreshToken: 'refresh',
                ),
              },
            ),
          ),
          pixivNetworkFactoryProvider.overrideWithValue(
            PixivNetworkFactory(
              NetworkAccessPolicy(
                resolver: _StubResolver(),
                clientFactory: (route, host, purpose) => script.asClient(),
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(accountStoreProvider.future);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale('zh', 'CN'),
            home: AccountSettingsPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('账号显示设置'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      final aiSwitch = tester.widget<SettingsControl>(
        find.widgetWithText(SettingsControl, '显示 AI 生成作品'),
      );
      expect(aiSwitch.value, isTrue);
      final restrictedSwitch = tester.widget<SettingsControl>(
        find.widgetWithText(SettingsControl, '受限模式'),
      );
      expect(restrictedSwitch.value, isFalse);

      await tester.ensureVisible(find.widgetWithText(SettingsControl, '受限模式'));
      await tester.pump();
      await tester.tap(find.widgetWithText(SettingsControl, '受限模式'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SettingsControl>(
              find.widgetWithText(SettingsControl, '受限模式'),
            )
            .value,
        isTrue,
      );

      await tester.ensureVisible(
        find.widgetWithText(SettingsControl, '显示 AI 生成作品'),
      );
      await tester.pump();
      await tester.tap(find.widgetWithText(SettingsControl, '显示 AI 生成作品'));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsOneWidget);
      expect(
        tester
            .widget<SettingsControl>(
              find.widgetWithText(SettingsControl, '显示 AI 生成作品'),
            )
            .value,
        isTrue,
        reason: 'the failed write restores the previous value',
      );
      expect(find.textContaining('服务端设置保存失败'), findsOneWidget);
    },
  );
}
