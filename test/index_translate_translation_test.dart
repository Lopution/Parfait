import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parfait/core/settings/app_settings.dart';
import 'package:parfait/core/translation/index_translate_translation.dart';
import 'package:parfait/core/translation/translation_transport.dart';

http.Response _success(String content, {String? finishReason}) =>
    http.Response.bytes(
      utf8.encode(
        jsonEncode({
          'choices': [
            {
              'message': {'content': content},
              ...?(finishReason == null
                  ? null
                  : {'finish_reason': finishReason}),
            },
          ],
        }),
      ),
      200,
    );

IndexTranslateTranslationTransport _transport(
  http.Client client, {
  IndexTranslateModel model = IndexTranslateModel.thirtyFiveBA3B,
  bool thinking = false,
}) => IndexTranslateTranslationTransport(
  client,
  model: model,
  enableThinking: thinking,
);

void main() {
  test(
    'matches the public request contract and strips disabled thinking',
    () async {
      String? body;
      final transport = _transport(
        MockClient((request) async {
          body = request.body;
          expect(
            request.url.toString(),
            'https://index-translate.bilibili.com/v1/chat/completions',
          );
          expect(request.headers['content-type'], 'application/json');
          expect(request.headers['user-agent'], 'Index-Translate-Client/1.0');
          expect(request.headers.containsKey('authorization'), isFalse);
          return _success('<think>internal</think>你好');
        }),
        model: IndexTranslateModel.nineB,
      );

      expect(await transport.translate('hello', targetLanguage: 'zh'), '你好');
      final decoded = jsonDecode(body!) as Map<String, dynamic>;
      expect(decoded['model'], 'Index-Translate-9B');
      expect(decoded['temperature'], 0.0);
      expect(decoded['max_tokens'], 1024);
      expect(decoded['stream'], false);
      expect(decoded['chat_template_kwargs'], {'enable_thinking': false});
      final messages = (decoded['messages'] as List)
          .cast<Map<String, dynamic>>();
      expect(messages.single['role'], 'user');
      expect(messages.single['content'], contains('翻译为中文'));
    },
  );

  test('thinking can be enabled and its output stays observable', () async {
    final transport = _transport(
      MockClient((_) async => _success('<think>reason</think>answer')),
      thinking: true,
    );

    expect(
      await transport.translate('hello', targetLanguage: 'en'),
      '<think>reason</think>answer',
    );
  });

  test('unsupported target language fails before a request', () async {
    var called = false;
    final transport = _transport(
      MockClient((_) async {
        called = true;
        return _success('unused');
      }),
    );

    await expectLater(
      transport.translate('hello', targetLanguage: 'xx'),
      throwsA(
        isA<TranslationError>().having(
          (error) => error.kind,
          'kind',
          TranslationFailureKind.unsupportedLanguage,
        ),
      ),
    );
    expect(called, isFalse);
  });

  test('maps public failures without exposing response text', () async {
    for (final (status, kind) in [
      (401, TranslationFailureKind.invalidCredentials),
      (403, TranslationFailureKind.invalidCredentials),
      (429, TranslationFailureKind.rateLimited),
      (503, TranslationFailureKind.network),
    ]) {
      await expectLater(
        _transport(
          MockClient((_) async => http.Response('upstream secret', status)),
        ).translate('hello', targetLanguage: 'zh'),
        throwsA(isA<TranslationError>().having((e) => e.kind, 'kind', kind)),
        reason: 'HTTP $status',
      );
    }

    await expectLater(
      _transport(
        MockClient((_) async => _success('partial', finishReason: 'length')),
      ).translate('hello', targetLanguage: 'zh'),
      throwsA(
        isA<TranslationError>().having(
          (e) => e.kind,
          'kind',
          TranslationFailureKind.malformed,
        ),
      ),
    );

    await expectLater(
      _transport(
        MockClient((_) async => throw const SocketException('offline')),
      ).translate('hello', targetLanguage: 'zh'),
      throwsA(
        isA<TranslationError>().having(
          (e) => e.kind,
          'kind',
          TranslationFailureKind.network,
        ),
      ),
    );
  });
}
