import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import 'package:parfait/app/external_intent_bridge.dart';
import 'package:parfait/app/navigation/routes.dart';
import 'package:parfait/core/auth/credential.dart';
import 'package:parfait/core/platform/android_intent_channel.dart';
import 'package:parfait/core/platform/intent_router.dart';
import 'package:parfait/features/illust/detail/illust_detail_page.dart';
import 'package:parfait/features/login/login_page.dart';
import 'package:parfait/features/profile/user_page.dart';
import 'package:parfait/features/search/reverse_image_search_page.dart';

import 'helpers/fake_account.dart';
import 'helpers/prompt_host.dart';
import 'helpers/localized_app.dart';

class _ScriptedIntentSource implements AndroidIntentSource {
  _ScriptedIntentSource(this.initial);

  final AndroidIntentResult initial;
  final StreamController<AndroidIntentResult> controller =
      StreamController<AndroidIntentResult>.broadcast();

  @override
  Future<AndroidIntentResult> readInitial() async => initial;

  @override
  Stream<AndroidIntentResult> get onNewIntent => controller.stream;

  Future<void> dispose() => controller.close();
}

Widget _app(GoRouter router, _ScriptedIntentSource source) {
  final credentials = FakeCredentialStore(
    values: const {
      '100': Credential(accessToken: 'a-100', refreshToken: 'r-100'),
    },
  );
  return localizedRouterApp(
    router,
    overrides: [...accountProviderOverrides(credentialStore: credentials)],
    builder: (context, child) => promptHostBuilder(
      context,
      ExternalIntentBridge(router: router, intentSource: source, child: child!),
    ),
  );
}

Future<({GoRouter router, _ScriptedIntentSource source})> _pump(
  WidgetTester tester, {
  required AndroidIntentResult initial,
  String initialLocation = '/recommended',
}) async {
  final source = _ScriptedIntentSource(initial);
  final router = createPixivRouter(initialLocation: initialLocation);
  addTearDown(source.dispose);
  addTearDown(router.dispose);
  await seedAccounts(const [testerAccount], currentId: testerAccount.id);
  await tester.pumpWidget(_app(router, source));
  await tester.pump();
  return (router: router, source: source);
}

void main() {
  testWidgets('cold-start Pixiv links use the recommended branch', (
    tester,
  ) async {
    final result = await _pump(
      tester,
      initial: RoutedAndroidIntent(
        IntentRouter.route(Uri.parse('pixiv://illusts/456')),
      ),
    );
    await tester.pump(const Duration(milliseconds: 350));

    expect(result.router.state.uri.path, '/recommended/illust/456');
    expect(find.byType(IllustDetailPage), findsOneWidget);
    expect(
      tester.widget<IllustDetailPage>(find.byType(IllustDetailPage)).illustId,
      456,
    );
  });

  testWidgets(
    'running deep links replace the current branch with recommended',
    (tester) async {
      final result = await _pump(
        tester,
        initial: const IgnoredAndroidIntent('test: no initial intent'),
        initialLocation: '/settings',
      );

      result.source.controller.add(
        RoutedAndroidIntent(
          IntentRouter.route(Uri.parse('https://www.pixiv.net/users/789')),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(result.router.state.uri.path, '/recommended/user/789');
      expect(find.byType(UserPage), findsOneWidget);
      expect(tester.widget<UserPage>(find.byType(UserPage)).userId, 789);
    },
  );

  testWidgets('ACTION_SEND pushes the root reverse-image route', (
    tester,
  ) async {
    final result = await _pump(
      tester,
      initial: const IgnoredAndroidIntent('test: no initial intent'),
    );

    result.source.controller.add(
      SharedImageAndroidIntent(
        contentUri: Uri.parse('content://share/1'),
        mimeType: 'image/png',
        sizeBytes: 32,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(result.router.state.uri.path, '/reverse-image');
    expect(find.byType(ReverseImageSearchPage), findsOneWidget);
  });

  testWidgets('rejected intents show the existing rejection snackbar', (
    tester,
  ) async {
    await _pump(
      tester,
      initial: const RejectedAndroidIntent(
        AndroidIntentRejectionCode.invalidViewUri,
        'invalid link',
      ),
    );
    await tester.pump();

    expect(find.text('分享的图片无法使用'), findsOneWidget);
  });

  testWidgets('account callbacks enter the login route with their payload', (
    tester,
  ) async {
    final result = await _pump(
      tester,
      initial: const RoutedAndroidIntent(AccountCallbackRoute('code')),
      initialLocation: '/login',
    );
    await tester.pump();

    expect(result.router.state.uri.path, '/login/callback');
    expect(find.byType(LoginPage), findsNWidgets(2));
    expect(result.router.state.extra, isA<AccountCallbackRoute>());
  });

  testWidgets(
    'subscribing before readInitial delivers queued cold-start and follow-up links in order exactly once',
    (tester) async {
      // Mirrors IosIntentBridge / MacosIntentBridge queueing when two links
      // arrive before Dart mounts ExternalIntentBridge (which subscribes to
      // onNewIntent before calling readInitial).
      final bridge = _QueuedIntentSource([
        RoutedAndroidIntent(
          IntentRouter.route(Uri.parse('pixiv://illusts/111')),
        ),
        RoutedAndroidIntent(IntentRouter.route(Uri.parse('pixiv://users/222'))),
      ]);
      addTearDown(bridge.dispose);

      final visited = <String>[];
      final router = createPixivRouter(initialLocation: '/recommended');
      addTearDown(router.dispose);
      router.routerDelegate.addListener(() {
        visited.add(router.state.uri.path);
      });

      await seedAccounts(const [testerAccount], currentId: testerAccount.id);
      await tester.pumpWidget(
        localizedRouterApp(
          router,
          overrides: [
            ...accountProviderOverrides(
              credentialStore: FakeCredentialStore(
                values: const {
                  '100': Credential(
                    accessToken: 'a-100',
                    refreshToken: 'r-100',
                  ),
                },
              ),
            ),
          ],
          builder: (context, child) => promptHostBuilder(
            context,
            ExternalIntentBridge(
              router: router,
              intentSource: bridge,
              child: child!,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      expect(bridge.events, ['onListen', 'readInitial', 'flush:1']);
      expect(bridge.delivered, ['initial:111', 'stream:222']);
      expect(
        visited.where(
          (p) => p.contains('/illust/111') || p.contains('/user/222'),
        ),
        ['/recommended/illust/111', '/recommended/user/222'],
      );
      expect(find.byType(UserPage), findsOneWidget);
      expect(tester.widget<UserPage>(find.byType(UserPage)).userId, 222);
    },
  );
}

class _QueuedIntentSource implements AndroidIntentSource {
  _QueuedIntentSource(List<AndroidIntentResult> incoming)
    : _initial = incoming.first,
      _pending = incoming.skip(1).toList() {
    _controller = StreamController<AndroidIntentResult>(
      onListen: () {
        events.add('onListen');
        _listening = true;
        _flushIfReady();
      },
    );
  }

  AndroidIntentResult? _initial;
  final List<AndroidIntentResult> _pending;
  bool _initialConsumed = false;
  bool _listening = false;
  final List<String> events = [];
  final List<String> delivered = [];
  late final StreamController<AndroidIntentResult> _controller;

  static String _labelOf(AndroidIntentResult item) => switch (item) {
    RoutedAndroidIntent(:final route) => switch (route) {
      IllustRoute(:final illustId) => '$illustId',
      UserRoute(:final userId) => '$userId',
      _ => route.runtimeType.toString(),
    },
    _ => item.runtimeType.toString(),
  };

  void _flushIfReady() {
    if ((!_initialConsumed && _initial != null) ||
        !_listening ||
        _pending.isEmpty) {
      return;
    }
    final queued = List<AndroidIntentResult>.of(_pending);
    _pending.clear();
    events.add('flush:${queued.length}');
    scheduleMicrotask(() {
      for (final item in queued) {
        if (!_controller.isClosed) {
          delivered.add('stream:${_labelOf(item)}');
          _controller.add(item);
        }
      }
    });
  }

  @override
  Future<AndroidIntentResult> readInitial() async {
    events.add('readInitial');
    _initialConsumed = true;
    final current = _initial;
    _initial = null;
    if (current != null) delivered.add('initial:${_labelOf(current)}');
    _flushIfReady();
    return current ?? const IgnoredAndroidIntent('test: none');
  }

  @override
  Stream<AndroidIntentResult> get onNewIntent => _controller.stream;

  Future<void> dispose() => _controller.close();
}
