import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parfait/core/translation/doubao_web_translation.dart';
import 'package:parfait/core/translation/translation_credentials.dart';
import 'package:parfait/core/translation/translation_transport.dart';

import 'helpers/settings_world.dart';

const _session = DoubaoWebSession(
  cookie: 'sessionid=abc; ttwid=t',
  teaUuid: '123456789012345678',
);

/// Stands in for doubao.com: answers launch with a fixed handshake and each
/// translate request with whatever [answer] streams back.
class _FakeDoubao {
  _FakeDoubao(this.answer);

  final List<String> Function(List<String> rawText, int call) answer;
  final translateRequests = <http.BaseRequest>[];
  final translateBodies = <Map<String, dynamic>>[];
  var launches = 0;

  late final client = MockClient.streaming((request, body) async {
    final bytes = await body.toBytes();
    if (request.url.path == '/alice/user/launch') {
      launches++;
      return _json({
        'code': 0,
        'data': {
          'config': {'ttwid': 'tt', 'web_id': 'web-7'},
          'country': 'CN',
        },
      });
    }
    final decoded = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    translateRequests.add(request);
    translateBodies.add(decoded);
    final chunks = answer(
      (decoded['raw_text'] as List).cast<String>(),
      translateRequests.length,
    );
    if (chunks.length == 1 && chunks.single.startsWith('{')) {
      return _json(jsonDecode(chunks.single) as Object);
    }
    return http.StreamedResponse(
      Stream.fromIterable(chunks.map(utf8.encode)),
      200,
      headers: {'content-type': 'text/event-stream; charset=utf-8'},
    );
  });

  static http.StreamedResponse _json(Object body) => http.StreamedResponse(
    Stream.value(utf8.encode(jsonEncode(body))),
    200,
    headers: {'content-type': 'application/json'},
  );
}

String _items(List<(int, String, String)> items) =>
    'event: json\ndata: ${jsonEncode({
      'code': 0,
      'data': {
        'items': [
          for (final (index, res, lang) in items) {'index': index, 'res': res, 'detect_lang': lang},
        ],
      },
    })}\n\n';

/// Translates every entry as `<text>-zh`, detected as Japanese.
List<String> _echo(List<String> raw, int call) => [
  _items([for (var i = 0; i < raw.length; i++) (i, '${raw[i]}-zh', 'ja')]),
  'event: done\ndata: {}\n\n',
];

DoubaoWebTranslationTransport _transport(
  http.Client client,
  FakeTranslationStore store,
) => DoubaoWebTranslationTransport(
  client,
  store,
  browserLanguage: () => 'zh-CN',
  random: Random(1),
);

void main() {
  late FakeTranslationStore store;

  setUp(() => store = FakeTranslationStore()..doubao = _session);

  test('sends the web client request after one launch handshake', () async {
    final doubao = _FakeDoubao(_echo);
    final transport = _transport(doubao.client, store);

    expect(
      await transport.translate('こんにちは', targetLanguage: 'zh'),
      'こんにちは-zh',
    );
    await transport.translate('もう一度', targetLanguage: 'zh');

    expect(doubao.launches, 1);
    final request = doubao.translateRequests.first;
    expect(request.url.path, '/samantha/plugin/stream_article_translate');
    expect(request.url.queryParameters.keys.toList(), [
      'language',
      'browser_language',
      'device_platform',
      'aid',
      'real_aid',
      'pkg_type',
      'device_id',
      'tea_uuid',
      'web_id',
      'is_new_user',
      'region',
      'sys_region',
      'use-olympus-account',
      'samantha_web',
      'version',
      'version_code',
      'pc_version',
      'web_tab_id',
    ]);
    expect(request.url.queryParameters, containsPair('device_id', 'web-7'));
    expect(request.url.queryParameters, containsPair('region', 'CN'));
    expect(
      request.url.queryParameters,
      containsPair('web_id', _session.teaUuid),
    );
    expect(request.headers['Cookie'], _session.cookie);
    expect(request.headers['Origin'], startsWith('chrome-extension://'));
    expect(request.headers['Accept'], 'text/event-stream');
    expect(doubao.translateBodies.first, {
      'raw_text': ['こんにちは'],
      'target_lang': 'zh',
      'translate_service': '1',
    });
  });

  test('parses events split across chunks and keeps text already in the '
      'target language', () async {
    final doubao = _FakeDoubao((raw, _) {
      final stream =
          '${_items([(0, '你好-rewritten', 'zh'), (1, '世界', 'en')])}'
          'event: done\r\ndata: {}\r\n\r\n';
      // Cut mid-line and between CR and LF.
      return [
        stream.substring(0, 17),
        stream.substring(17, stream.length - 3),
        stream.substring(stream.length - 3),
      ];
    });

    final result = await _transport(
      doubao.client,
      store,
    ).translateAll(['你好', 'world'], targetLanguage: 'zh');

    expect(result, ['你好', '世界']);
  });

  test(
    'splits batches of more than ten and re-sends only missing entries',
    () async {
      final texts = [for (var i = 0; i < 12; i++) 't$i'];
      final doubao = _FakeDoubao((raw, call) {
        // The first answer drops entry 3.
        if (call == 1) {
          return [
            _items([
              for (var i = 0; i < raw.length; i++)
                if (i != 3) (i, '${raw[i]}-zh', 'en'),
            ]),
          ];
        }
        return _echo(raw, call);
      });

      final result = await _transport(
        doubao.client,
        store,
      ).translateAll(texts, targetLanguage: 'zh');

      expect(result, [for (final text in texts) '$text-zh']);
      expect(
        doubao.translateBodies.map((body) => (body['raw_text'] as List).length),
        [10, 1, 2],
      );
      expect(doubao.translateBodies[1]['raw_text'], ['t3']);
    },
  );

  test('maps Doubao error codes and retries a login error after a fresh '
      'launch', () async {
    Future<Object?> failure(String Function(int call) answer) async {
      final doubao = _FakeDoubao((raw, call) => [answer(call)]);
      try {
        await _transport(
          doubao.client,
          store,
        ).translate('x', targetLanguage: 'zh');
      } on TranslationError catch (error) {
        return (error.kind, doubao.launches, doubao.translateRequests.length);
      }
      return null;
    }

    expect(await failure((_) => 'event: err\ndata: {"code":710012001}\n\n'), (
      TranslationFailureKind.invalidCredentials,
      2,
      2,
    ));
    expect(await failure((_) => '{"code":710022002,"msg":"rejected"}'), (
      TranslationFailureKind.rejected,
      1,
      1,
    ));
    expect(await failure((_) => 'event: err\ndata: {"code":710012007}\n\n'), (
      TranslationFailureKind.rateLimited,
      1,
      1,
    ));
  });

  test('without a saved session nothing is sent', () async {
    final doubao = _FakeDoubao(_echo);
    store.doubao = null;

    await expectLater(
      _transport(doubao.client, store).translate('x', targetLanguage: 'zh'),
      throwsA(
        isA<TranslationUnavailable>().having(
          (error) => error.kind,
          'kind',
          TranslationFailureKind.notConfigured,
        ),
      ),
    );
    expect(doubao.launches + doubao.translateRequests.length, 0);
  });

  test('maps app languages onto Doubao targets', () {
    expect(doubaoTargetLanguage('zh'), 'zh');
    expect(doubaoTargetLanguage('zh_TW'), 'zh-Hant');
    expect(doubaoTargetLanguage('ja'), 'ja');
    expect(() => doubaoTargetLanguage('xx'), throwsA(isA<TranslationError>()));
  });
}
