import 'dart:async';
import 'dart:io';

import '../download/download_recovery.dart';
import '../network/api_error.dart';
import '../network/compat/network_contracts.dart';
import '../network/next_page_parser.dart';

/// The user-facing error taxonomy (C8/D1).
///
/// UI surfaces never print raw exception text: each category maps to one
/// localized sentence via `errorCategoryText`, while the original error is
/// recorded to `CrashLog` or offered behind the collapsible "details"
/// disclosure (`ErrorDetails`).
enum ErrorCategory {
  /// DNS, socket, TLS or other transport-level failure.
  network,

  /// A request or connection exceeded the configured timeout.
  timeout,

  /// The server asked the client to slow down.
  rateLimited,

  /// Authentication failed; the account needs to sign in again.
  unauthorized,

  /// The server answered with a 5xx status.
  server,

  /// The requested resource does not exist (HTTP 404).
  notFound,

  /// The response could not be parsed into the expected schema.
  parse,

  /// Local storage could not be read or written.
  storage,

  /// Anything not covered above — including cancellations, which callers
  /// are not supposed to surface anyway.
  unknown,
}

/// Classifies an arbitrary error object into an [ErrorCategory].
///
/// The mapping mirrors `TransportFailureClassifier`'s transport taxonomy,
/// flattened to the handful of buckets a user can act on: only the
/// unambiguous `NetworkFailureKind.timeout` refines the coarse `network`
/// bucket.
ErrorCategory categorizeError(Object error) => switch (error) {
  ApiTimeout() || TimeoutException() => ErrorCategory.timeout,
  ApiChallengeRequired() => ErrorCategory.network,
  ApiRateLimited() => ErrorCategory.rateLimited,
  ApiUnauthorized() => ErrorCategory.unauthorized,
  ApiHttpError(:final statusCode) => switch (statusCode) {
    404 => ErrorCategory.notFound,
    >= 500 && < 600 => ErrorCategory.server,
    _ => ErrorCategory.unknown,
  },
  ApiParseError() ||
  FormatException() ||
  NextPageParseError() => ErrorCategory.parse,
  ApiNetworkError() ||
  SocketException() ||
  HandshakeException() => ErrorCategory.network,
  NetworkFailureException(:final kind) =>
    kind == NetworkFailureKind.timeout
        ? ErrorCategory.timeout
        : ErrorCategory.network,
  FileSystemException() => ErrorCategory.storage,
  _ => ErrorCategory.unknown,
};

/// Classifies a persisted [DownloadFailureKind] the same way the download
/// page presents it. Kinds that have no generic category
/// (permission/resource/ownership/unknown) map to [ErrorCategory.unknown];
/// callers show download-specific copy for those, and `canceled`/`paused`
/// are not errors at all.
ErrorCategory categorizeDownloadFailure(DownloadFailureKind kind) =>
    switch (kind) {
      DownloadFailureKind.auth => ErrorCategory.unauthorized,
      DownloadFailureKind.rateLimit => ErrorCategory.rateLimited,
      DownloadFailureKind.network => ErrorCategory.network,
      DownloadFailureKind.storage => ErrorCategory.storage,
      DownloadFailureKind.decode => ErrorCategory.parse,
      _ => ErrorCategory.unknown,
    };
