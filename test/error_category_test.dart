import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:parfait/core/download/download_recovery.dart';
import 'package:parfait/core/errors/error_category.dart';
import 'package:parfait/core/network/api_error.dart';
import 'package:parfait/core/network/compat/network_contracts.dart';
import 'package:parfait/core/network/next_page_parser.dart';

void main() {
  test('categorizeError puts each error in its category', () {
    for (final (error, category) in <(Object, ErrorCategory)>[
      // Transport-level failures are network.
      (const ApiNetworkError('no route'), ErrorCategory.network),
      (const SocketException('closed'), ErrorCategory.network),
      (const HandshakeException('tls'), ErrorCategory.network),
      // NetworkFailureException refines only the timeout kind.
      for (final kind in NetworkFailureKind.values)
        (
          NetworkFailureException(kind),
          kind == NetworkFailureKind.timeout
              ? ErrorCategory.timeout
              : ErrorCategory.network,
        ),
      (const ApiTimeout(), ErrorCategory.timeout),
      (TimeoutException('slow'), ErrorCategory.timeout),
      (const ApiRateLimited(null), ErrorCategory.rateLimited),
      (const ApiUnauthorized(), ErrorCategory.unauthorized),
      // ApiHttpError splits by status; other 4xx have no user-actionable
      // bucket.
      (const ApiHttpError(404), ErrorCategory.notFound),
      for (final status in [500, 502, 503, 599])
        (ApiHttpError(status), ErrorCategory.server),
      for (final status in [400, 403, 418, 499])
        (ApiHttpError(status), ErrorCategory.unknown),
      (const ApiParseError('nope'), ErrorCategory.parse),
      (const FormatException('bad json'), ErrorCategory.parse),
      (const NextPageParseError('missing cursor'), ErrorCategory.parse),
      (const FileSystemException('denied', '/tmp/x'), ErrorCategory.storage),
      // Callers must not surface a deliberate cancel as a failure; if one
      // leaks through anyway it reads as a generic failure, never a lie
      // about the network.
      (const ApiCancelled(), ErrorCategory.unknown),
      (StateError('x'), ErrorCategory.unknown),
      ('plain string', ErrorCategory.unknown),
    ]) {
      expect(categorizeError(error), category, reason: '$error');
    }
  });

  test('categorizeDownloadFailure maps five kinds; the rest stay unknown', () {
    // Download-specific and non-error kinds are covered by download copy
    // or hidden.
    const mapped = {
      DownloadFailureKind.auth: ErrorCategory.unauthorized,
      DownloadFailureKind.rateLimit: ErrorCategory.rateLimited,
      DownloadFailureKind.network: ErrorCategory.network,
      DownloadFailureKind.storage: ErrorCategory.storage,
      DownloadFailureKind.decode: ErrorCategory.parse,
    };
    for (final kind in DownloadFailureKind.values) {
      expect(
        categorizeDownloadFailure(kind),
        mapped[kind] ?? ErrorCategory.unknown,
        reason: '$kind',
      );
    }
  });
}
