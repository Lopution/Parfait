import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../settings/app_settings.dart';
import 'translation_transport.dart';

/// Public Index Translate chat-completions transport.
///
/// The endpoint is intentionally fixed and credential-free. Its request shape
/// mirrors the supplied upstream `call_api.py` script so the app and the
/// reference client exercise the same public contract.
class IndexTranslateTranslationTransport
    with SequentialBatchTranslation
    implements TranslationTransport {
  IndexTranslateTranslationTransport(
    this._client, {
    required IndexTranslateModel model,
    required bool enableThinking,
  }) : _model = model,
       _enableThinking = enableThinking;

  static final _endpoint = Uri.parse(
    'https://index-translate.bilibili.com/v1/chat/completions',
  );
  static const _userAgent = 'Index-Translate-Client/1.0';
  static const _timeout = Duration(seconds: 120);
  static const _maxSourceBytes = 512 * 1024;
  static const _maxResponseBytes = 256 * 1024;

  /// The upstream script's language-name table. The app normally passes one
  /// of zh/en/ja/ru, but keeping the complete table makes the transport's
  /// closed contract useful to other translation callers too.
  static const _languageNames = <String, String>{
    'en': '英语',
    'zh': '中文',
    'de': '德语',
    'fr': '法语',
    'es': '西班牙语',
    'ja': '日语',
    'ko': '韩语',
    'pt': '葡萄牙语',
    'ru': '俄语',
    'ar': '阿拉伯语',
    'it': '意大利语',
    'nl': '荷兰语',
    'pl': '波兰语',
    'ro': '罗马尼亚语',
    'sv': '瑞典语',
    'tr': '土耳其语',
    'hi': '印地语',
    'vi': '越南语',
    'th': '泰语',
    'id': '印尼语',
    'ms': '马来语',
    'fil': '菲律宾语',
    'ukr_cyrl': '乌克兰语',
    'fas_arab': '波斯语',
    'ces_latn': '捷克语',
    'ell_grek': '希腊语',
    'dan_latn': '丹麦语',
    'hun_latn': '匈牙利语',
    'fin_latn': '芬兰语',
    'nob_latn': '书面挪威语',
    'slk_latn': '斯洛伐克语',
    'bul_cyrl': '保加利亚语',
  };

  final http.Client _client;
  final IndexTranslateModel _model;
  final bool _enableThinking;

  @override
  Future<String> translate(
    String text, {
    required String targetLanguage,
  }) async {
    final source = text.trim();
    if (source.isEmpty) {
      throw const TranslationError('empty source text');
    }
    if (utf8.encode(source).length > _maxSourceBytes) {
      throw const TranslationError('source text is too long');
    }
    final target = _targetName(targetLanguage);
    final prompt = '请将以下文本翻译为$target，直接输出翻译结果，不要进行任何解释。\n\n$source';
    final response = await _post(prompt);
    if (response.bodyBytes.length > _maxResponseBytes) {
      throw const TranslationError(
        'Index Translate response too large',
        TranslationFailureKind.malformed,
      );
    }
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const TranslationError(
        'Index Translate credentials rejected',
        TranslationFailureKind.invalidCredentials,
      );
    }
    if (response.statusCode == 429) {
      throw const TranslationError(
        'Index Translate rate limited',
        TranslationFailureKind.rateLimited,
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw const TranslationError(
        'Index Translate http failure',
        TranslationFailureKind.network,
      );
    }
    final dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw const TranslationError(
        'malformed response',
        TranslationFailureKind.malformed,
      );
    }
    final content = _extractContent(decoded);
    if (content == null) {
      throw const TranslationError(
        'malformed response',
        TranslationFailureKind.malformed,
      );
    }
    final result = _stripThink(content);
    if (result.trim().isEmpty) {
      throw const TranslationError(
        'empty translation',
        TranslationFailureKind.malformed,
      );
    }
    return result;
  }

  Future<http.Response> _post(String prompt) async {
    try {
      return await _client
          .post(
            _endpoint,
            headers: const {
              'Content-Type': 'application/json',
              'User-Agent': _userAgent,
            },
            body: jsonEncode({
              'model': _model.modelName,
              'messages': [
                {'role': 'user', 'content': prompt},
              ],
              'temperature': 0.0,
              'max_tokens': 1024,
              'stream': false,
              'chat_template_kwargs': {'enable_thinking': _enableThinking},
            }),
          )
          .timeout(_timeout);
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
  }

  static String _targetName(String targetLanguage) {
    final code = targetLanguage.trim().toLowerCase().replaceAll('-', '_');
    final normalized = switch (code) {
      'zh_cn' || 'zh_hans' || 'zh_sg' || 'zh_tw' || 'zh_hant' => 'zh',
      _ => code,
    };
    final name = _languageNames[normalized];
    if (name == null) {
      throw const TranslationError(
        'unsupported target language',
        TranslationFailureKind.unsupportedLanguage,
      );
    }
    return name;
  }

  static String? _extractContent(Object? decoded) {
    if (decoded is! Map<String, dynamic>) return null;
    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty) return null;
    final first = choices.first;
    if (first is! Map<String, dynamic>) return null;
    if (first['finish_reason'] == 'length') {
      throw const TranslationError(
        'Index Translate response truncated',
        TranslationFailureKind.malformed,
      );
    }
    final message = first['message'];
    if (message is! Map<String, dynamic>) return null;
    final content = message['content'];
    if (content is! String || content.trim().isEmpty) return null;
    return content.trim();
  }

  /// Matches the reference client: when reasoning is disabled, discard an
  /// optional thinking block but keep the actual answer after it.
  static String _stripThink(String content) {
    final end = content.indexOf('</think>');
    if (end >= 0) return content.substring(end + '</think>'.length).trim();
    return content.trim().replaceFirst(RegExp(r'^<think>'), '').trim();
  }
}
