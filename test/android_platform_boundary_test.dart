import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/network/compat/network_contracts.dart';
import 'package:pixiv_func/core/network/compat/webview_route.dart';
import 'package:pixiv_func/core/platform/android_platform_interfaces.dart';
import 'package:pixiv_func/core/platform/intent_router.dart';

void main() {
  group('WebViewRouteSession boundary', () {
    test(
      'keeps revision and exact hosts, and cleans all owners on background',
      () async {
        var revision = const NetworkRevision(7, networkIdentity: 'mumu-wifi');
        final loopback = _FakeLoopbackAdapter();
        final policy = WebViewRoutePolicy(
          registry: PixivDestinationRegistry(),
          capabilities: const _SupportedWebKitCapabilities(),
          loopbackImplementationAvailable: true,
          loopbackAdapter: loopback,
          revisionProvider: () => revision,
        );

        final session = await WebViewRouteSession.open(
          policy: policy,
          uri: Uri.parse('https://app-api.pixiv.net/web/v1/login'),
          accountId: '1048052188',
          credentialRevision: 3,
        );
        expect(session.sessionId, isNotEmpty);
        expect(session.accountId, '1048052188');
        expect(session.credentialRevision, 3);
        expect(session.networkRevision, revision);
        expect(session.allowedHosts, contains('accounts.pixiv.net'));

        final first = await session.openLoopback(ownerId: 'login-page');
        final second = await session.acquire(ownerId: 'navigation-observer');
        expect(session.refCount, 2);
        expect(policy.listenerCreated, isTrue);

        await first.release();
        await first.release();
        expect(session.refCount, 1);

        await session.invalidate(WebViewRouteInvalidationReason.background);
        expect(session.isClosed, isTrue);
        expect(session.refCount, 0);
        expect(session.closedAt, isNotNull);
        expect(policy.listenerCreated, isFalse);
        expect(loopback.closeCount, 1);

        await second.release();
        await session.close();
        expect(loopback.closeCount, 1);

        revision = const NetworkRevision(8, networkIdentity: 'mumu-wifi');
      },
    );

    test('capability absence is a typed fail-closed loopback result', () async {
      final policy = WebViewRoutePolicy(
        registry: PixivDestinationRegistry(),
        capabilities: const UnsupportedWebKitCapabilities(),
      );
      final session = await WebViewRouteSession.open(
        policy: policy,
        uri: Uri.parse('https://app-api.pixiv.net/web/v1/login'),
      );

      await expectLater(
        session.openLoopback(ownerId: 'login-page'),
        throwsA(
          isA<WebViewRouteFailure>().having(
            (error) => error.code,
            'code',
            WebViewRouteFailureCode.capabilityUnavailable,
          ),
        ),
      );
      expect(policy.listenerCreated, isFalse);
      await session.close();
    });

    test('a revision change rejects an old session before route use', () async {
      var revision = const NetworkRevision(1, networkIdentity: 'wifi-a');
      final policy = WebViewRoutePolicy(
        registry: PixivDestinationRegistry(),
        capabilities: const UnsupportedWebKitCapabilities(),
        revisionProvider: () => revision,
      );
      final session = await WebViewRouteSession.open(
        policy: policy,
        uri: Uri.parse('https://app-api.pixiv.net/web/v1/login'),
      );
      revision = const NetworkRevision(2, networkIdentity: 'wifi-b');

      expect(
        () => session.validate(Uri.parse('https://accounts.pixiv.net/')),
        throwsA(
          isA<WebViewRouteFailure>().having(
            (error) => error.code,
            'code',
            WebViewRouteFailureCode.staleNetworkRevision,
          ),
        ),
      );
      await session.close();
    });

    test('concurrent owners share one loopback handle', () async {
      final loopback = _FakeLoopbackAdapter();
      final policy = WebViewRoutePolicy(
        registry: PixivDestinationRegistry(),
        capabilities: const _SupportedWebKitCapabilities(),
        loopbackImplementationAvailable: true,
        loopbackAdapter: loopback,
      );
      final session = await WebViewRouteSession.open(
        policy: policy,
        uri: Uri.parse('https://app-api.pixiv.net/web/v1/login'),
      );

      final leases = await Future.wait([
        session.openLoopback(ownerId: 'owner-a'),
        session.openLoopback(ownerId: 'owner-b'),
      ]);

      expect(loopback.openCount, 1);
      expect(session.refCount, 2);
      await leases[0].release();
      expect(loopback.closeCount, 0);
      await leases[1].release();
      expect(loopback.closeCount, 1);
      await session.close();
    });

    test('closing while loopback opens closes the late handle', () async {
      final loopback = _DeferredLoopbackAdapter();
      final policy = WebViewRoutePolicy(
        registry: PixivDestinationRegistry(),
        capabilities: const _SupportedWebKitCapabilities(),
        loopbackImplementationAvailable: true,
        loopbackAdapter: loopback,
      );
      final session = await WebViewRouteSession.open(
        policy: policy,
        uri: Uri.parse('https://app-api.pixiv.net/web/v1/login'),
      );

      final opening = session.openLoopback(ownerId: 'owner-a');
      await Future<void>.delayed(Duration.zero);
      await session.close();
      final handle = _FakeLoopbackHandle(() {});
      loopback.complete(handle);

      await expectLater(
        opening,
        throwsA(
          isA<WebViewRouteFailure>().having(
            (error) => error.code,
            'code',
            WebViewRouteFailureCode.sessionClosed,
          ),
        ),
      );
      expect(handle.isClosed, isTrue);
      expect(policy.listenerCreated, isFalse);
    });
  });

  group('Android intent boundary', () {
    test('routes only an explicit VIEW deep link', () {
      final result = IntentRouter.routeIntent(
        AndroidIntentInput(
          action: AndroidIntentInput.viewAction,
          uri: Uri.parse('https://www.pixiv.net/artworks/123'),
        ),
      );
      expect(result, isA<RoutedAndroidIntent>());
      expect((result as RoutedAndroidIntent).route, isA<IllustRoute>());
    });

    test('rejects SEND without the exact stream extra and read grant', () {
      final result = IntentRouter.routeIntent(
        AndroidIntentInput(
          action: AndroidIntentInput.sendAction,
          uri: Uri.parse('content://share/1'),
          mimeType: 'image/png',
          sizeBytes: 128,
          hasReadUriPermission: false,
        ),
      );
      expect(result, isA<RejectedAndroidIntent>());
      expect(
        (result as RejectedAndroidIntent).code,
        AndroidIntentRejectionCode.missingStreamExtra,
      );
    });

    test(
      'accepts a bounded content URI only with the stream extra and grant',
      () {
        final result = IntentRouter.routeIntent(
          AndroidIntentInput(
            action: AndroidIntentInput.sendAction,
            uri: Uri.parse('content://share/1'),
            mimeType: 'IMAGE/PNG',
            sizeBytes: 128,
            hasReadUriPermission: true,
            extraKeys: const {AndroidIntentInput.streamExtra},
          ),
        );
        expect(result, isA<SharedImageAndroidIntent>());
        final image = result as SharedImageAndroidIntent;
        expect(image.contentUri.toString(), 'content://share/1');
        expect(image.sizeBytes, 128);
      },
    );

    test('rejects foreign, file and oversized shared payloads', () {
      final inputs = [
        AndroidIntentInput(
          action: AndroidIntentInput.sendAction,
          uri: Uri.parse('file:///sdcard/a.png'),
          mimeType: 'image/png',
          sizeBytes: 1,
          hasReadUriPermission: true,
          extraKeys: const {AndroidIntentInput.streamExtra},
        ),
        AndroidIntentInput(
          action: AndroidIntentInput.sendAction,
          uri: Uri.parse('content://share/1'),
          mimeType: 'text/plain',
          sizeBytes: 1,
          hasReadUriPermission: true,
          extraKeys: const {AndroidIntentInput.streamExtra},
        ),
        AndroidIntentInput(
          action: AndroidIntentInput.sendAction,
          uri: Uri.parse('content://share/1'),
          mimeType: 'image/png',
          sizeBytes: 10 * 1024 * 1024 + 1,
          hasReadUriPermission: true,
          extraKeys: const {AndroidIntentInput.streamExtra},
        ),
      ];

      for (final input in inputs) {
        expect(IntentRouter.routeIntent(input), isA<RejectedAndroidIntent>());
      }
    });
  });
}

class _SupportedWebKitCapabilities implements WebKitCapabilities {
  const _SupportedWebKitCapabilities();

  @override
  Future<bool> get supportsProxyController async => true;

  @override
  Future<bool> get supportsProxyReverseBypass async => true;

  @override
  Future<bool> get supportsServiceWorkerController async => true;
}

class _FakeLoopbackAdapter implements WebViewLoopbackAdapter {
  int openCount = 0;
  int closeCount = 0;

  @override
  Future<WebViewLoopbackHandle> open({
    required WebViewRouteSession session,
    required String ownerId,
  }) async {
    openCount++;
    return _FakeLoopbackHandle(() => closeCount++);
  }
}

class _DeferredLoopbackAdapter implements WebViewLoopbackAdapter {
  final Completer<WebViewLoopbackHandle> _completer =
      Completer<WebViewLoopbackHandle>();

  @override
  Future<WebViewLoopbackHandle> open({
    required WebViewRouteSession session,
    required String ownerId,
  }) => _completer.future;

  void complete(WebViewLoopbackHandle handle) => _completer.complete(handle);
}

class _FakeLoopbackHandle implements WebViewLoopbackHandle {
  _FakeLoopbackHandle(this.onClose);

  final void Function() onClose;
  bool _closed = false;

  bool get isClosed => _closed;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    onClose();
  }
}
