/// Failure classification surfaced wherever a translation is shown. Callers
/// never fall back to a different provider on their own; a failure stays
/// visible.
enum TranslationFailureKind {
  disabled,
  notConfigured,

  /// Credentials were refused, or a web login session has expired.
  invalidCredentials,
  rateLimited,
  network,
  malformed,
  unsupportedLanguage,

  /// The provider declined this content (moderation).
  rejected,
  other,
}

class TranslationUnavailable implements Exception {
  const TranslationUnavailable(this.kind);

  final TranslationFailureKind kind;

  @override
  String toString() => 'TranslationUnavailable($kind)';
}

class TranslationError implements Exception {
  const TranslationError(
    this.reason, [
    this.kind = TranslationFailureKind.other,
  ]);

  final String reason;
  final TranslationFailureKind kind;

  @override
  String toString() => 'TranslationError($reason)';
}

/// Resolved at request scope from secure storage: a cleared credential is
/// observed immediately on the next tap, never reused from a cached state.
abstract interface class TranslationTransport {
  Future<String> translate(String text, {required String targetLanguage});

  /// Translates every entry of [texts]; the result has the same length and
  /// order. Entries must be non-blank.
  Future<List<String>> translateAll(
    List<String> texts, {
    required String targetLanguage,
  });
}

/// Engines without a native batch call translate one text at a time, in
/// order, so a batch costs exactly as many requests as it has entries.
mixin SequentialBatchTranslation implements TranslationTransport {
  @override
  Future<List<String>> translateAll(
    List<String> texts, {
    required String targetLanguage,
  }) async {
    final results = <String>[];
    for (final text in texts) {
      results.add(await translate(text, targetLanguage: targetLanguage));
    }
    return results;
  }
}
