import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../settings/app_settings.dart';
import '../settings/settings_controller.dart';

class CommentTranslationUnavailable implements Exception {
  const CommentTranslationUnavailable();

  @override
  String toString() => 'CommentTranslationUnavailable(provider disabled)';
}

class CommentTranslationError implements Exception {
  const CommentTranslationError(this.reason);

  final String reason;

  @override
  String toString() => 'CommentTranslationError($reason)';
}

abstract interface class CommentTranslationService {
  Future<String> translate(String text, {required String targetLanguage});
}

/// Translation is an explicit, non-persistent overlay action. The comment
/// text is sent only when the user taps translate; this service never logs or
/// stores the private source text.
class GoogleCommentTranslationService implements CommentTranslationService {
  GoogleCommentTranslationService(this._client);

  static const _host = 'translate.googleapis.com';
  static const _timeout = Duration(seconds: 15);

  final http.Client _client;

  @override
  Future<String> translate(
    String text, {
    required String targetLanguage,
  }) async {
    final source = text.trim();
    if (source.isEmpty) {
      throw const CommentTranslationError('empty source text');
    }
    final target = targetLanguage.trim().toLowerCase();
    if (!RegExp(r'^[a-z]{2,3}(?:-[a-z]{2,4})?$').hasMatch(target)) {
      throw const CommentTranslationError('invalid target language');
    }
    final response = await _client
        .get(
          Uri.https(_host, '/translate_a/single', {
            'client': 'gtx',
            'dt': 't',
            'sl': 'auto',
            'tl': target,
            'q': source,
          }),
        )
        .timeout(_timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw CommentTranslationError('http ${response.statusCode}');
    }
    final dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw const CommentTranslationError('malformed response');
    }
    if (decoded is! List || decoded.isEmpty || decoded.first is! List) {
      throw const CommentTranslationError('malformed response');
    }
    final translations = decoded.first as List;
    final parts = <String>[];
    for (final item in translations) {
      if (item is List && item.isNotEmpty && item.first is String) {
        parts.add(item.first as String);
      }
    }
    final result = parts.join();
    if (result.trim().isEmpty) {
      throw const CommentTranslationError('empty translation');
    }
    return result;
  }
}

class DisabledCommentTranslationService implements CommentTranslationService {
  const DisabledCommentTranslationService();

  @override
  Future<String> translate(
    String text, {
    required String targetLanguage,
  }) async {
    throw const CommentTranslationUnavailable();
  }
}

final commentTranslationServiceProvider = Provider<CommentTranslationService>((
  ref,
) {
  final client = http.Client();
  ref.onDispose(client.close);
  final configured = _ConfiguredCommentTranslationService(
    ref,
    GoogleCommentTranslationService(client),
  );
  return configured;
});

class _ConfiguredCommentTranslationService
    implements CommentTranslationService {
  _ConfiguredCommentTranslationService(this._ref, this._google);

  final Ref _ref;
  final GoogleCommentTranslationService _google;

  @override
  Future<String> translate(String text, {required String targetLanguage}) {
    final provider = _ref.read(translationProvider);
    if (provider == TranslationProvider.disabled) {
      return const DisabledCommentTranslationService().translate(
        text,
        targetLanguage: targetLanguage,
      );
    }
    return _google.translate(text, targetLanguage: targetLanguage);
  }
}
