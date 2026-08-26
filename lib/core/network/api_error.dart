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
  String get message => 'rate limited${retryAfter == null ? '' : ', retry after ${retryAfter!.inSeconds}s'}';
}

/// Response body could not be parsed into the expected schema.
class ApiParseError extends ApiError {
  const ApiParseError(this.cause);

  final Object cause;

  @override
  String get message => 'response parse error';
}
