import 'package:flutter_test/flutter_test.dart';

import 'package:pixiv_func/core/auth/oauth_service.dart';
import 'package:pixiv_func/features/login/login_navigation_decision.dart';

OAuthService _service() => OAuthService();

void main() {
  group('decideLoginNavigation', () {
    test('exact pixiv://account callback yields the code', () {
      final service = _service();
      service.beginSession(); // live PKCE session required for validation
      final decision = decideLoginNavigation(
        service,
        'pixiv://account?code=abc123&via=login',
      );
      expect(decision, isA<LoginNavExchange>());
      expect((decision as LoginNavExchange).code, 'abc123');
    });

    test('pixiv://account without a code aborts the session', () {
      final service = _service();
      service.beginSession();
      final decision = decideLoginNavigation(service, 'pixiv://account');
      expect(decision, isA<LoginNavAbort>());
    });

    test('pixiv://account without a live session is invalid', () {
      final service = _service();
      final decision = decideLoginNavigation(
        service,
        'pixiv://account?code=abc',
      );
      expect(decision, isA<LoginNavAbort>());
    });

    test('pixiv login hosts and third-party urls are allowed', () {
      final service = _service();
      service.beginSession();
      for (final url in [
        'https://accounts.pixiv.net/login',
        'https://app-api.pixiv.net/web/v1/login',
        'https://www.google.com/recaptcha/',
        'https://social.gid.pixiv.net/authorize',
      ]) {
        expect(
          decideLoginNavigation(service, url),
          isA<LoginNavAllow>(),
          reason: url,
        );
      }
    });

    test('unparseable urls are ignored, not treated as callbacks', () {
      final service = _service();
      service.beginSession();
      expect(
        decideLoginNavigation(service, ':::not a url:::'),
        isA<LoginNavIgnore>(),
      );
    });
  });
}
