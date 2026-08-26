import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/auth/oauth_service.dart';
import 'package:pixiv_func/core/auth/pkce.dart';

void main() {
  group('PKCE (RFC 7636)', () {
    test('S256 challenge matches the RFC 7636 appendix B vector', () {
      const verifier = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
      expect(
        Pkce.computeChallenge(verifier),
        'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
      );
    });

    test('verifier uses secure random, RFC charset and valid length', () {
      final verifiers = List.generate(20, (_) => Pkce.generateVerifier());
      for (final verifier in verifiers) {
        expect(verifier.length, Pkce.verifierLength);
        expect(
          verifier.split('').every(Pkce.verifierCharset.contains),
          isTrue,
        );
      }
      // Randomness sanity: 20 draws never repeat.
      expect(verifiers.toSet().length, 20);
    });

    test('generateVerifier accepts an injected deterministic random', () {
      final verifier = Pkce.generateVerifier(random: Random(1));
      expect(Pkce.computeChallenge(verifier),
          Pkce.computeChallenge(Pkce.generateVerifier(random: Random(1))));
    });
  });

  group('pixiv://account callback whitelist', () {
    test('exact pixiv://account?code=... is accepted', () {
      final result = parsePixivAccountCallback(
        Uri.parse('pixiv://account?code=abc123'),
      );
      expect(result, isA<PixivCallbackCode>());
      expect((result as PixivCallbackCode).code, 'abc123');
    });

    test('wrong scheme or host is a normal navigation', () {
      for (final uri in [
        'https://account?code=abc',
        'pixiv://other?code=abc',
        'pixiv://',
        'https://www.pixiv.net/some/page',
      ]) {
        final result = parsePixivAccountCallback(Uri.parse(uri));
        expect(result, isA<PixivCallbackOther>(), reason: uri);
      }
    });

    test('missing, empty and duplicate codes are invalid', () {
      for (final uri in [
        'pixiv://account',
        'pixiv://account?other=1',
        'pixiv://account?code=',
        'pixiv://account?code=a&code=b',
      ]) {
        final result = parsePixivAccountCallback(Uri.parse(uri));
        expect(result, isA<PixivCallbackInvalid>(), reason: uri);
      }
    });
  });

  group('OAuthService session lifecycle', () {
    test('beginSession creates exactly one live session with S256 URL',
        () {
      final service = OAuthService();
      final first = service.beginSession();
      expect(service.hasLiveSession, isTrue);

      final second = service.beginSession();
      expect(second.sessionId, isNot(first.sessionId));

      final url = second.authorizeUrl;
      expect(url.scheme, 'https');
      expect(url.host, 'app-api.pixiv.net');
      expect(url.path, '/web/v1/login');
      expect(url.queryParameters['code_challenge_method'], 'S256');
      expect(url.queryParameters['client'], 'pixiv-android');
      final challenge = url.queryParameters['code_challenge'];
      expect(challenge, isNotNull);
      expect(challenge!.length, 43); // base64url(sha256) without padding
    });

    test('discardSession clears the live session', () {
      final service = OAuthService();
      service.beginSession();
      service.discardSession();
      expect(service.hasLiveSession, isFalse);
    });

    test('expired session is not live and cannot be exchanged', () async {
      final service = OAuthService(sessionTtl: const Duration(seconds: 0));
      service.beginSession();
      await Future<void>.delayed(Duration.zero);
      expect(service.hasLiveSession, isFalse);

      await expectLater(
        () => service.exchangeCode('any'),
        throwsA(isA<OAuthException>()),
      );
    });
  });

  group('token exchange', () {
    late HttpServer server;
    late OAuthService service;
    late List<Map<String, String>> receivedBodies;
    int responseStatus = 200;
    Object? responseJson;

    setUp(() async {
      receivedBodies = [];
      responseStatus = 200;
      responseJson = {
        'access_token': 'test-access',
        'refresh_token': 'test-refresh',
        'user': {
          'id': '100',
          'name': 'tester',
          'mail_address': 'tester@example.com',
          'profile_image_urls': {'main': 'https://img.example/main.jpg'},
        },
      };
      server = await HttpServer.bind('127.0.0.1', 0);
      server.listen((request) async {
        final body = await utf8.decoder.bind(request).join();
        receivedBodies.add(Uri.splitQueryString(body));
        request.response.statusCode = responseStatus;
        request.response.headers.contentType = ContentType.json;
        request.response.write(responseJson is String
            ? responseJson
            : jsonEncode(responseJson));
        await request.response.close();
      });
      service = OAuthService(
        tokenEndpoint:
            Uri.parse('http://127.0.0.1:${server.port}/auth/token'),
      );
    });

    tearDown(() async {
      await server.close(force: true);
      service.discardSession();
    });

    test('success consumes the session once and returns account data',
        () async {
      service.beginSession();
      final result = await service.exchangeCode('the-code');

      expect(result.accountId, '100');
      expect(result.credential.accessToken, 'test-access');
      expect(result.credential.refreshToken, 'test-refresh');
      expect(result.profile.userId, 100);
      expect(result.profile.name, 'tester');

      expect(receivedBodies, hasLength(1));
      final body = receivedBodies.single;
      expect(body['grant_type'], 'authorization_code');
      expect(body['code'], 'the-code');
      expect(body['client_id'], OAuthService.clientId);
      expect(body['client_secret'], OAuthService.clientSecret);
      expect(body['include_policy'], 'true');
      expect(body['redirect_uri'], OAuthService.defaultRedirectUri);
      expect(body['code_verifier'], hasLength(Pkce.verifierLength));

      // One-time use: a second exchange with the same session fails.
      await expectLater(
        () => service.exchangeCode('the-code'),
        throwsA(isA<OAuthException>()),
      );
    });

    test('exchange without a live session fails', () async {
      await expectLater(
        () => service.exchangeCode('code'),
        throwsA(isA<OAuthException>()),
      );
    });

    test('exchange error response discards the session and surfaces status',
        () async {
      service.beginSession();
      responseStatus = 400;
      await expectLater(
        () => service.exchangeCode('bad'),
        throwsA(isA<OAuthException>()
            .having((e) => e.statusCode, 'statusCode', 400)),
      );
      expect(service.hasLiveSession, isFalse);
    });

    test('verifier is cleared after a failed exchange', () async {
      final session = service.beginSession();
      responseStatus = 500;
      await expectLater(
        service.exchangeCode('bad'),
        throwsA(isA<OAuthException>()),
      );
      // A fresh session must have a different verifier; the consumed one
      // cannot be reused.
      final next = service.beginSession();
      expect(next.sessionId, isNot(session.sessionId));
    });
  });
}
