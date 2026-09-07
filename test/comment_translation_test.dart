import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pixiv_func/core/comments/comment_translation.dart';
import 'package:pixiv_func/core/comments/translation_credentials.dart';
import 'package:pixiv_func/core/settings/app_settings.dart';

class _FakeCredentials implements TranslationCredentialStore {
  BaiduTranslationCredentials? baidu;
  LlmTranslationCredentials? llm;

  @override
  Future<BaiduTranslationCredentials?> readBaidu() async => baidu;

  @override
  Future<void> writeBaidu(BaiduTranslationCredentials credentials) async {
    baidu = credentials;
  }

  @override
  Future<LlmTranslationCredentials?> readLlm() async => llm;

  @override
  Future<void> writeLlm(LlmTranslationCredentials credentials) async {
    llm = credentials;
  }

  @override
  Future<void> deleteBaidu() async {
    baidu = null;
  }

  @override
  Future<void> deleteLlm() async {
    llm = null;
  }

  @override
  Future<void> deleteAll() async {
    baidu = null;
    llm = null;
  }
}

void main() {
  final fixedNow = DateTime(2026, 9, 3, 12, 0, 0);
  late _FakeCredentials store;

  setUp(() {
    store = _FakeCredentials();
  });

  group('BaiduCommentTranslationService', () {
    test(
      'signs with md5(appid+q+salt+secret) and maps a success response',
      () async {
        store.baidu = const BaiduTranslationCredentials(
          appId: 'app-1',
          secret: 'sec-1',
        );
        String? seenSign;
        final client = MockClient((request) async {
          final body = Uri.splitQueryString(request.body);
          expect(request.url.host, 'fanyi-api.baidu.com');
          expect(
            request.headers['content-type'],
            contains('application/x-www-form-urlencoded'),
          );
          // Verify the documented signature inside the request scope.
          expect(body['sign'], md5Of('app-1${body['q']}${body['salt']}sec-1'));
          expect(body, isNot(contains('secret')));
          seenSign = body['sign'];
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'from': 'auto',
                'to': body['to'],
                'trans_result': [
                  {'src': 'hello', 'dst': '你好'},
                  {'src': 'world', 'dst': '世界'},
                ],
              }),
            ),
            200,
          );
        });
        final service = BaiduCommentTranslationService(
          client,
          () => fixedNow,
          store,
        );

        final result = await service.translate(
          'hello\nworld',
          targetLanguage: 'zh',
        );

        expect(result, '你好\n世界');
        expect(seenSign, isNotEmpty);
      },
    );

    test('throws notConfigured for an absent credential record', () async {
      final service = BaiduCommentTranslationService(
        MockClient((_) async => http.Response('{}', 200)),
        () => fixedNow,
        store,
      );

      await expectLater(
        service.translate('hello', targetLanguage: 'zh'),
        throwsA(
          isA<CommentTranslationUnavailable>().having(
            (e) => e.kind,
            'kind',
            CommentTranslationFailureKind.notConfigured,
          ),
        ),
      );
    });

    test('maps business error codes into visible classifications', () async {
      store.baidu = const BaiduTranslationCredentials(
        appId: 'app-1',
        secret: 'sec-1',
      );
      final cases = {
        '52003': CommentTranslationFailureKind.invalidCredentials,
        '54001': CommentTranslationFailureKind.invalidCredentials,
        '54003': CommentTranslationFailureKind.rateLimited,
        '54004': CommentTranslationFailureKind.rateLimited,
        '58002': CommentTranslationFailureKind.other,
      };
      for (final entry in cases.entries) {
        final service = BaiduCommentTranslationService(
          MockClient(
            (_) async =>
                http.Response(jsonEncode({'error_code': entry.key}), 200),
          ),
          () => fixedNow,
          store,
        );
        await expectLater(
          service.translate('hello', targetLanguage: 'zh'),
          throwsA(
            isA<CommentTranslationError>().having(
              (e) => e.kind,
              'kind',
              entry.value,
            ),
          ),
          reason: 'error code ${entry.key}',
        );
      }
    });

    test('rejects unsupported target languages without a request', () async {
      store.baidu = const BaiduTranslationCredentials(
        appId: 'app-1',
        secret: 'sec-1',
      );
      var called = false;
      final service = BaiduCommentTranslationService(
        MockClient((_) async {
          called = true;
          return http.Response('{}', 200);
        }),
        () => fixedNow,
        store,
      );

      await expectLater(
        service.translate('hello', targetLanguage: 'xx'),
        throwsA(
          isA<CommentTranslationError>().having(
            (e) => e.kind,
            'kind',
            CommentTranslationFailureKind.unsupportedLanguage,
          ),
        ),
      );
      expect(called, isFalse);
    });
  });

  group('LlmCommentTranslationService', () {
    test('posts a fixed prompt and extracts the answer', () async {
      store.llm = const LlmTranslationCredentials(
        baseUrl: 'https://llm.example.com/v1',
        apiKey: 'key-secret',
        model: 'mini-1',
      );
      String? auth;
      String? body;
      final client = MockClient((request) async {
        auth = request.headers['authorization'];
        body = request.body;
        expect(
          request.url.toString(),
          'https://llm.example.com/v1/chat/completions',
        );
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': '你好'},
                },
              ],
            }),
          ),
          200,
        );
      });

      final service = LlmCommentTranslationService(client, store);
      final result = await service.translate('hello', targetLanguage: 'zh');

      expect(result, '你好');
      expect(auth, 'Bearer key-secret');
      final decoded = jsonDecode(body!) as Map<String, dynamic>;
      expect(decoded['model'], 'mini-1');
      expect(decoded['temperature'], 0.2);
      final messages = decoded['messages'] as List;
      expect(messages.first['role'], 'system');
      expect(
        (messages.last['content'] as String),
        contains('Translate into zh'),
      );
    });

    test('rejects plain HTTP endpoints as invalid credentials', () async {
      store.llm = const LlmTranslationCredentials(
        baseUrl: 'http://llm.example.com/v1',
        apiKey: 'key-secret',
      );
      var called = false;
      final service = LlmCommentTranslationService(
        MockClient((_) async {
          called = true;
          return http.Response('{}', 200);
        }),
        store,
      );

      await expectLater(
        service.translate('hello', targetLanguage: 'zh'),
        throwsA(
          isA<CommentTranslationError>().having(
            (e) => e.kind,
            'kind',
            CommentTranslationFailureKind.invalidCredentials,
          ),
        ),
      );
      expect(called, isFalse);
    });

    test(
      'maps 401 and 429 into invalid credentials and rate limited',
      () async {
        store.llm = const LlmTranslationCredentials(
          baseUrl: 'https://llm.example.com/v1',
          apiKey: 'key-secret',
        );
        final cases = {
          401: CommentTranslationFailureKind.invalidCredentials,
          403: CommentTranslationFailureKind.invalidCredentials,
          429: CommentTranslationFailureKind.rateLimited,
        };
        for (final entry in cases.entries) {
          final service = LlmCommentTranslationService(
            MockClient((_) async => http.Response('{}', entry.key)),
            store,
          );
          await expectLater(
            service.translate('hello', targetLanguage: 'zh'),
            throwsA(
              isA<CommentTranslationError>().having(
                (e) => e.kind,
                'kind',
                entry.value,
              ),
            ),
            reason: 'http ${entry.key}',
          );
        }
      },
    );

    test('defaults the model and rejects an oversized response', () async {
      store.llm = const LlmTranslationCredentials(
        baseUrl: 'https://llm.example.com/v1',
        apiKey: 'key-secret',
      );
      var seenModel = '';
      final service = LlmCommentTranslationService(
        MockClient((request) async {
          seenModel =
              (jsonDecode(request.body) as Map<String, dynamic>)['model']
                  as String;
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': 'hi'},
                },
              ],
            }),
            200,
          );
        }),
        store,
      );

      final result = await service.translate('hello', targetLanguage: 'zh');

      expect(seenModel, 'gpt-4o-mini');
      expect(result, 'hi');
      // An oversized response must be rejected as malformed.
      final oversized = LlmCommentTranslationService(
        MockClient((_) async => http.Response('x' * (256 * 1024 + 1), 200)),
        store,
      );
      await expectLater(
        oversized.translate('hello', targetLanguage: 'zh'),
        throwsA(
          isA<CommentTranslationError>().having(
            (e) => e.kind,
            'kind',
            CommentTranslationFailureKind.malformed,
          ),
        ),
      );
    });
  });

  group('ConfiguredCommentTranslationService dispatch', () {
    test('disabled path throws without touching the network', () async {
      var called = false;
      final service = ConfiguredCommentTranslationService(
        resolveProvider: () => TranslationProvider.disabled,
        store: store,
        google: _RecordingTransport(() => called = true),
        baidu: _RecordingTransport(() => called = true),
        llm: _RecordingTransport(() => called = true),
      );

      await expectLater(
        service.translate('hello', targetLanguage: 'zh'),
        throwsA(
          isA<CommentTranslationUnavailable>().having(
            (e) => e.kind,
            'kind',
            CommentTranslationFailureKind.disabled,
          ),
        ),
      );
      expect(called, isFalse);
    });

    test('baidu provider is dispatched to the baidu transport', () async {
      var baiduCalled = false;
      final service = ConfiguredCommentTranslationService(
        resolveProvider: () => TranslationProvider.baidu,
        store: store,
        google: _RecordingTransport(() {}),
        baidu: _RecordingTransport(() => baiduCalled = true, result: '你好'),
        llm: _RecordingTransport(() {}),
      );

      expect(await service.translate('hello', targetLanguage: 'zh'), '你好');
      expect(baiduCalled, isTrue);
    });
  });

  group('credentials store', () {
    test(
      'round-trips baidu and llm records and clears them independently',
      () async {
        await store.writeBaidu(
          const BaiduTranslationCredentials(appId: 'a', secret: 's'),
        );
        await store.writeLlm(
          const LlmTranslationCredentials(
            baseUrl: 'https://x.example/v1',
            apiKey: 'k',
            model: 'm',
          ),
        );

        expect((await store.readBaidu())!.secret, 's');
        expect((await store.readLlm())!.apiKey, 'k');
        expect((await store.readLlm())!.model, 'm');

        await store.deleteAll();
        expect(await store.readBaidu(), isNull);
        expect(await store.readLlm(), isNull);
      },
    );

    test('never exposes secrets in toString', () {
      final baidu = const BaiduTranslationCredentials(
        appId: 'app-1',
        secret: 'SECRET-VALUE-xyz',
      );
      final llm = const LlmTranslationCredentials(
        baseUrl: 'https://x.example/v1',
        apiKey: 'APIKEY-VALUE-xyz',
      );
      expect(baidu.toString(), isNot(contains('SECRET-VALUE-xyz')));
      expect(llm.toString(), isNot(contains('APIKEY-VALUE-xyz')));
    });

    test('default settings resolve to disabled for fresh installs', () {
      expect(
        AppSettings.defaults().translationProvider,
        TranslationProvider.disabled,
      );
    });
  });
}

String md5Of(String value) {
  return md5.convert(utf8.encode(value)).toString();
}

class _RecordingTransport implements CommentTranslationTransport {
  _RecordingTransport(this.onCall, {this.result});

  final void Function() onCall;
  final String? result;

  @override
  Future<String> translate(
    String text, {
    required String targetLanguage,
  }) async {
    onCall();
    return result ?? text;
  }
}
