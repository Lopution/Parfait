import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'translation_credentials.dart';
import 'translation_transport.dart';

/// Doubao web article translation, signed in as the user's own doubao.com
/// account. This is the private protocol the official Doubao browser
/// extension uses (the request shape follows the Cometix extension): every
/// request carries the captured login cookie and the extension's Origin, and
/// nothing works without a login. The endpoint is unofficial and may change;
/// failures are reported as they are, never swapped for another provider.
class DoubaoWebTranslationTransport implements TranslationTransport {
  DoubaoWebTranslationTransport(
    this._client,
    this._store, {
    required String Function() browserLanguage,
    Random? random,
  }) : _browserLanguage = browserLanguage,
       _tabId = _uuidV4(random ?? Random.secure());

  /// Desktop Chrome: doubao.com serves its web client (and the login dialog)
  /// to desktop browsers, and the login WebView sends the same agent so the
  /// session and the API calls look alike.
  static const userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36';
  static final home = Uri.parse('https://www.doubao.com/chat/');
  static final _translateUrl = Uri.parse(
    'https://www.doubao.com/samantha/plugin/stream_article_translate',
  );
  static final _launchUrl = Uri.parse(
    'https://www.doubao.com/alice/user/launch',
  );
  static const _extensionOrigin =
      'chrome-extension://dbjibobgilijgolhjdcbdebjhejelffo';

  /// Limits of the web endpoint, as the extension enforces them.
  static const _timeout = Duration(seconds: 60);
  static const _maxGroupSize = 10;
  static const _maxSegmentChars = 5000;
  static const _maxBodyBytes = 96 * 1024;

  /// A group whose answer misses entries is re-sent for the missing ones
  /// only, this many rounds in total.
  static const _attempts = 2;

  /// `translate_service`: 1 = Doubao's own model (0 = Volcano, 3 = Microsoft).
  static const _doubaoService = '1';

  final http.Client _client;
  final TranslationCredentialStore _store;
  final String Function() _browserLanguage;
  final String _tabId;

  /// Result of the launch handshake, kept until a login error asks for a
  /// fresh one. A failed launch is remembered as [_LaunchInfo.none]: the
  /// translate call still works without it, and reports its own errors.
  Future<_LaunchInfo>? _launch;

  @override
  Future<String> translate(
    String text, {
    required String targetLanguage,
  }) async =>
      (await translateAll([text], targetLanguage: targetLanguage)).single;

  @override
  Future<List<String>> translateAll(
    List<String> texts, {
    required String targetLanguage,
  }) async {
    final target = doubaoTargetLanguage(targetLanguage);
    for (final text in texts) {
      if (text.trim().isEmpty) {
        throw const TranslationError('empty source text');
      }
      if (text.length > _maxSegmentChars) {
        throw const TranslationError('source text exceeds the Doubao limit');
      }
    }
    final session = await _store.readDoubao();
    if (session == null) {
      throw const TranslationUnavailable(TranslationFailureKind.notConfigured);
    }
    final results = <String>[];
    for (final group in _groups(texts)) {
      results.addAll(await _translateGroup(session, group, target));
    }
    return results;
  }

  /// Splits [texts] into request-sized groups, keeping order.
  static List<List<String>> _groups(List<String> texts) {
    final groups = <List<String>>[];
    var current = <String>[];
    var bytes = 0;
    for (final text in texts) {
      // JSON escaping can grow a string; budget for the worst common case.
      final size = utf8.encode(text).length + 16;
      if (current.length == _maxGroupSize ||
          (current.isNotEmpty && bytes + size > _maxBodyBytes)) {
        groups.add(current);
        current = <String>[];
        bytes = 0;
      }
      current.add(text);
      bytes += size;
    }
    if (current.isNotEmpty) groups.add(current);
    return groups;
  }

  Future<List<String>> _translateGroup(
    DoubaoWebSession session,
    List<String> sources,
    String target,
  ) async {
    try {
      return await _translateWithRetries(session, sources, target);
    } on DoubaoRemoteError catch (error) {
      if (!error.needsRelaunch) rethrow;
      // A stale handshake reads as a login error too; redo it once before
      // reporting the session as expired.
      _launch = null;
      return _translateWithRetries(session, sources, target);
    }
  }

  Future<List<String>> _translateWithRetries(
    DoubaoWebSession session,
    List<String> sources,
    String target,
  ) async {
    final results = List<String?>.filled(sources.length, null);
    var pending = [for (var i = 0; i < sources.length; i++) i];
    for (var round = 0; round < _attempts && pending.isNotEmpty; round++) {
      final batch = [for (final i in pending) sources[i]];
      final answer = await _post(session, batch, target);
      for (final entry in answer.entries) {
        results[pending[entry.key]] = entry.value;
      }
      pending = [
        for (final i in pending)
          if (results[i] == null) i,
      ];
    }
    if (pending.isNotEmpty) {
      throw const TranslationError(
        'Doubao returned the wrong number of translations',
        TranslationFailureKind.malformed,
      );
    }
    return [for (final result in results) result!];
  }

  /// One translate request; returns the translations it carried by index.
  Future<Map<int, String>> _post(
    DoubaoWebSession session,
    List<String> sources,
    String target,
  ) async {
    final launch = await (_launch ??= _runLaunch(session));
    final request =
        http.Request('POST', _withQuery(_translateUrl, session, launch))
          ..followRedirects = false
          ..headers.addAll({
            ..._headers(session),
            'Accept': 'text/event-stream',
          })
          ..body = jsonEncode({
            'raw_text': sources,
            'target_lang': target,
            'translate_service': _doubaoService,
          });
    final parser = DoubaoStreamParser(sources: sources, target: target);
    try {
      final response = await _client.send(request).timeout(_timeout);
      _checkStatus(response.statusCode);
      final contentType = response.headers['content-type'] ?? '';
      if (!contentType.startsWith('text/event-stream')) {
        // Errors come back as a plain JSON envelope.
        final body = await response.stream.bytesToString().timeout(_timeout);
        throw _envelopeError(body);
      }
      final chunks = response.stream.transform(utf8.decoder).timeout(_timeout);
      await for (final chunk in chunks) {
        parser.push(chunk);
        if (parser.done) break;
      }
      parser.finish();
    } on TimeoutException {
      throw const TranslationError(
        'translation timed out',
        TranslationFailureKind.network,
      );
    } on SocketException {
      throw const TranslationError(
        'translation network failure',
        TranslationFailureKind.network,
      );
    } on http.ClientException {
      throw const TranslationError(
        'translation network failure',
        TranslationFailureKind.network,
      );
    }
    return parser.results;
  }

  static void _checkStatus(int status) {
    if (status >= 200 && status < 300) return;
    if (status == 401 || status == 403) {
      throw const TranslationError(
        'Doubao refused the session',
        TranslationFailureKind.invalidCredentials,
      );
    }
    if (status == 429) {
      throw const TranslationError(
        'Doubao rate limited',
        TranslationFailureKind.rateLimited,
      );
    }
    throw TranslationError(
      'Doubao http $status',
      TranslationFailureKind.network,
    );
  }

  static TranslationError _envelopeError(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      return const TranslationError(
        'malformed response',
        TranslationFailureKind.malformed,
      );
    }
    if (decoded is Map<String, dynamic> && decoded['code'] != null) {
      return DoubaoRemoteError.fromCode(decoded['code']);
    }
    return const TranslationError(
      'malformed response',
      TranslationFailureKind.malformed,
    );
  }

  /// The launch handshake tells the web client its device id and region.
  Future<_LaunchInfo> _runLaunch(DoubaoWebSession session) async {
    try {
      final response = await _client
          .post(
            _withQuery(_launchUrl, session, _LaunchInfo.none),
            headers: {..._headers(session), 'Agw-Js-Conv': 'str'},
          )
          .timeout(_timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return _LaunchInfo.none;
      }
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map<String, dynamic> || decoded['code'] != 0) {
        return _LaunchInfo.none;
      }
      final data = decoded['data'];
      if (data is! Map<String, dynamic>) return _LaunchInfo.none;
      final config = data['config'];
      final ttwid = config is Map<String, dynamic> ? config['ttwid'] : null;
      return _LaunchInfo(
        hasTtwid: ttwid is String && ttwid.isNotEmpty,
        webId: _field(config is Map<String, dynamic> ? config['web_id'] : null),
        country: _field(data['country']),
      );
    } on Exception {
      return _LaunchInfo.none;
    }
  }

  /// Launch fields as the web client keeps them: strings or numbers,
  /// clipped to 64 characters.
  static String _field(Object? value) {
    if (value is! String && value is! num) return '';
    final text = value.toString();
    return text.length > 64 ? text.substring(0, 64) : text;
  }

  Map<String, String> _headers(DoubaoWebSession session) => {
    'Content-Type': 'application/json',
    'Origin': _extensionOrigin,
    'Cookie': session.cookie,
    'User-Agent': userAgent,
  };

  /// The web client's fixed query, in its own order.
  Uri _withQuery(Uri endpoint, DoubaoWebSession session, _LaunchInfo launch) {
    final params = <String, String>{
      'language': 'zh',
      'browser_language': _browserLanguage(),
      'device_platform': 'web',
      'aid': '586864',
      'real_aid': '586864',
      'pkg_type': 'release_version',
      'device_id': launch.hasTtwid ? launch.webId : '0',
      'tea_uuid': session.teaUuid,
      'web_id': session.teaUuid,
      'is_new_user': '0',
      'region': launch.country,
      'sys_region': launch.country,
      'use-olympus-account': '1',
      'samantha_web': '1',
      'version': '1.38.0',
      'version_code': '20800',
      'pc_version': '1.38.0',
      'web_tab_id': _tabId,
    };
    final query = params.entries
        .map(
          (entry) =>
              '${Uri.encodeComponent(entry.key)}='
              '${Uri.encodeComponent(entry.value)}',
        )
        .join('&');
    return endpoint.replace(query: query);
  }
}

/// Maps an app language code to Doubao's `target_lang`. The set is closed:
/// an unsupported target is reported, not translated into a wrong language.
String doubaoTargetLanguage(String languageCode) {
  final code = languageCode.trim().toLowerCase().replaceAll('_', '-');
  switch (code) {
    case 'zh' || 'zh-cn' || 'zh-hans' || 'zh-sg':
      return 'zh';
    case 'zh-tw' || 'zh-hk' || 'zh-hant' || 'zh-mo':
      return 'zh-Hant';
  }
  const passThrough = {
    'en',
    'ja',
    'ko',
    'fr',
    'de',
    'es',
    'pt',
    'ru',
    'it',
    'ar',
    'th',
    'vi',
    'id',
    'ms',
    'tr',
    'nl',
    'pl',
  };
  final base = code.split('-').first;
  if (passThrough.contains(base)) return base;
  throw const TranslationError(
    'unsupported target language',
    TranslationFailureKind.unsupportedLanguage,
  );
}

/// An 18-digit device id for a new login, as the web client generates it.
String newDoubaoTeaUuid([Random? random]) {
  final source = random ?? Random.secure();
  final digits = StringBuffer()..write(1 + source.nextInt(9));
  for (var i = 1; i < 18; i++) {
    digits.write(source.nextInt(10));
  }
  return digits.toString();
}

/// A business error code from Doubao (`code` in the envelope or an `err`
/// event).
class DoubaoRemoteError extends TranslationError {
  DoubaoRemoteError._(this.code, TranslationFailureKind kind)
    : super('Doubao error $code', kind);

  factory DoubaoRemoteError.fromCode(Object? code) {
    final value = code?.toString() ?? '';
    final kind = switch (value) {
      '710012000' ||
      '710012001' ||
      '710022013' => TranslationFailureKind.invalidCredentials,
      '710012007' || '676010003' => TranslationFailureKind.rateLimited,
      '710022002' || '710022004' => TranslationFailureKind.rejected,
      _ => TranslationFailureKind.other,
    };
    return DoubaoRemoteError._(value, kind);
  }

  final String code;

  /// Login errors the extension answers with a fresh launch handshake.
  bool get needsRelaunch => code == '710012000' || code == '710012001';
}

/// Incremental parser for the translate endpoint's event stream: `json`
/// events carry `{code, data: {items: [{index, res, detect_lang}]}}`, `done`
/// ends the answer and `err` carries a failure code.
class DoubaoStreamParser {
  DoubaoStreamParser({required this.sources, required this.target});

  final List<String> sources;
  final String target;

  /// Translations received so far, by source index.
  final Map<int, String> results = {};
  bool _done = false;
  String _buffer = '';

  bool get done => _done;

  static final _lineBreaks = RegExp(r'\r\n?');
  static final _eventBreak = RegExp(r'\n{2,}');

  void push(String chunk) {
    if (_done) return;
    _buffer += chunk;
    // A trailing CR may be the first half of a CRLF split across chunks.
    final pendingCr = _buffer.endsWith('\r');
    final text = pendingCr ? _buffer.substring(0, _buffer.length - 1) : _buffer;
    final blocks = text.replaceAll(_lineBreaks, '\n').split(_eventBreak);
    _buffer = blocks.removeLast() + (pendingCr ? '\r' : '');
    for (final block in blocks) {
      _event(block);
      if (_done) return;
    }
  }

  /// Handles a final event that arrived without its blank-line terminator.
  void finish() {
    if (!_done && _buffer.trim().isNotEmpty) {
      _event(_buffer.replaceAll(_lineBreaks, '\n'));
    }
    _buffer = '';
    _done = true;
  }

  void _event(String block) {
    var event = 'message';
    final data = <String>[];
    for (final line in block.split('\n')) {
      if (line.isEmpty || line.startsWith(':')) continue;
      final colon = line.indexOf(':');
      final field = colon < 0 ? line : line.substring(0, colon);
      var value = colon < 0 ? '' : line.substring(colon + 1);
      if (value.startsWith(' ')) value = value.substring(1);
      if (field == 'event') {
        event = value;
      } else if (field == 'data') {
        data.add(value);
      }
    }
    switch (event) {
      case 'done':
        _done = true;
        return;
      case 'err':
        final payload = _decode(data.join('\n'), strict: false);
        throw DoubaoRemoteError.fromCode(
          payload is Map<String, dynamic> ? payload['code'] : null,
        );
      case 'json':
        _items(_decode(data.join('\n'), strict: true));
    }
  }

  void _items(Object? payload) {
    if (payload is! Map<String, dynamic>) throw _malformed;
    if (payload['code'] != 0) {
      throw DoubaoRemoteError.fromCode(payload['code']);
    }
    final body = payload['data'];
    final items = body is Map<String, dynamic> ? body['items'] : null;
    if (items is! List) throw _malformed;
    for (final item in items) {
      if (item is! Map<String, dynamic>) continue;
      final index = item['index'];
      final translated = item['res'];
      if (index is! int || index < 0 || index >= sources.length) continue;
      if (translated is! String || results.containsKey(index)) continue;
      // Already in the target language: Doubao echoes a rewrite; keep the
      // author's own text.
      results[index] = item['detect_lang'] == target
          ? sources[index]
          : translated;
    }
  }

  static Object? _decode(String raw, {required bool strict}) {
    try {
      return jsonDecode(raw);
    } on FormatException {
      if (strict) throw _malformed;
      return null;
    }
  }

  static const _malformed = TranslationError(
    'malformed response',
    TranslationFailureKind.malformed,
  );
}

class _LaunchInfo {
  const _LaunchInfo({
    required this.hasTtwid,
    required this.webId,
    required this.country,
  });

  static const none = _LaunchInfo(hasTtwid: false, webId: '', country: '');

  final bool hasTtwid;
  final String webId;
  final String country;
}

String _uuidV4(Random random) {
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
