/// Classified API failures.
///
/// Every subclass keeps diagnostics safe: `toString` never includes auth
/// headers, tokens or cookies, so errors can be logged or surfaced directly.
sealed class ApiError implements Exception {
  const ApiError();

  @override
  String toString() => '$runtimeType($message)';

  String get message => '';
}

/// DNS, socket or TLS-level failure. Certificate failures surface here and
/// are never retried or downgraded.
class ApiNetworkError extends ApiError {
  const ApiNetworkError(this.cause);

  final Object cause;

  @override
  String get message => 'network error';
}

/// Request or response exceeded the configured timeout.
class ApiTimeout extends ApiError {
  const ApiTimeout();
}

/// The caller cancelled the request before completion.
class ApiCancelled extends ApiError {
  const ApiCancelled();
}

/// Non-2xx HTTP response outside the auth/rate-limit classes.
class ApiHttpError extends ApiError {
  const ApiHttpError(this.statusCode, [this.detail]);

  final int statusCode;
  final String? detail;

  @override
  String get message => 'http $statusCode${detail == null ? '' : ': $detail'}';
}

/// Authentication failure after the refresh/retry protocol was exhausted,
/// or an invalid refresh. The account needs re-authentication.
class ApiUnauthorized extends ApiError {
  const ApiUnauthorized([this.detail]);

  final String? detail;

  @override
  String get message => 'unauthorized${detail == null ? '' : ': $detail'}';
}

/// Rate limited. [retryAfter] carries a server-provided hint when present.
class ApiRateLimited extends ApiError {
  const ApiRateLimited(this.retryAfter);

  final Duration? retryAfter;

  @override
  String get message =>
      'rate limited${retryAfter == null ? '' : ', retry after ${retryAfter!.inSeconds}s'}';
}

/// Response body could not be parsed into the expected schema.
class ApiParseError extends ApiError {
  const ApiParseError(this.cause);

  final Object cause;

  /// The cause rides along: release builds obfuscate [runtimeType], so the
  /// extractor's own diagnostics ("missing bootstrap script", "no value
  /// entry") are the only way to tell WHICH parse stage failed from a
  /// user report. Causes are FormatExceptions or short literals — never
  /// headers, tokens or cookies — and are capped so an HTML page fragment
  /// cannot flood an error surface.
  @override
  String get message {
    final detail = '$cause';
    final trimmed = detail.length <= 160
        ? detail
        : '${detail.substring(0, 157)}…';
    return 'response parse error: $trimmed';
  }
}
