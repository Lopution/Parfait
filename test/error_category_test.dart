import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:parfait/core/download/download_recovery.dart';
import 'package:parfait/core/errors/error_category.dart';
import 'package:parfait/core/network/api_error.dart';
import 'package:parfait/core/network/compat/network_contracts.dart';
import 'package:parfait/core/network/next_page_parser.dart';

void main() {
  group('categorizeError', () {
    test('transport-level failures are network', () {
      expect(
        categorizeError(const ApiNetworkError('no route')),
        ErrorCategory.network,
      );
      expect(
        categorizeError(const SocketException('closed')),
        ErrorCategory.network,
      );
      expect(
        categorizeError(const HandshakeException('tls')),
        ErrorCategory.network,
      );
    });

    test('NetworkFailureException refines only the timeout kind', () {
      expect(
        categorizeError(
          const NetworkFailureException(NetworkFailureKind.timeout),
        ),
        ErrorCategory.timeout,
      );
      for (final kind in NetworkFailureKind.values.where(
        (k) => k != NetworkFailureKind.timeout,
      )) {
        expect(
          categorizeError(NetworkFailureException(kind)),
          ErrorCategory.network,
          reason: 'kind $kind stays the coarse network bucket',
        );
      }
    });

    test('timeout family', () {
      expect(categorizeError(const ApiTimeout()), ErrorCategory.timeout);
      expect(categorizeError(TimeoutException('slow')), ErrorCategory.timeout);
    });

    test('rate limit and auth', () {
      expect(
        categorizeError(const ApiRateLimited(null)),
        ErrorCategory.rateLimited,
      );
      expect(
        categorizeError(const ApiUnauthorized()),
        ErrorCategory.unauthorized,
      );
    });

    test('ApiHttpError splits by status', () {
      expect(categorizeError(const ApiHttpError(404)), ErrorCategory.notFound);
      for (final status in [500, 502, 503, 599]) {
        expect(
          categorizeError(ApiHttpError(status)),
          ErrorCategory.server,
          reason: 'HTTP $status',
        );
      }
      for (final status in [400, 403, 418, 499]) {
        expect(
          categorizeError(ApiHttpError(status)),
          ErrorCategory.unknown,
          reason: 'HTTP $status has no user-actionable bucket',
        );
      }
    });

    test('parse family', () {
      expect(categorizeError(const ApiParseError('nope')), ErrorCategory.parse);
      expect(
        categorizeError(const FormatException('bad json')),
        ErrorCategory.parse,
      );
      expect(
        categorizeError(const NextPageParseError('missing cursor')),
        ErrorCategory.parse,
      );
    });

    test('storage', () {
      expect(
        categorizeError(const FileSystemException('denied', '/tmp/x')),
        ErrorCategory.storage,
      );
    });

    test('cancel and anything else fall to unknown', () {
      // Callers must not surface a deliberate cancel as a failure; if one
      // leaks through anyway it reads as a generic failure, never a lie
      // about the network.
      expect(categorizeError(const ApiCancelled()), ErrorCategory.unknown);
      expect(categorizeError(StateError('x')), ErrorCategory.unknown);
      expect(categorizeError('plain string'), ErrorCategory.unknown);
    });
  });

  group('categorizeDownloadFailure', () {
    test('mapped kinds', () {
      expect(
        categorizeDownloadFailure(DownloadFailureKind.auth),
        ErrorCategory.unauthorized,
      );
      expect(
        categorizeDownloadFailure(DownloadFailureKind.rateLimit),
        ErrorCategory.rateLimited,
      );
      expect(
        categorizeDownloadFailure(DownloadFailureKind.network),
        ErrorCategory.network,
      );
      expect(
        categorizeDownloadFailure(DownloadFailureKind.storage),
        ErrorCategory.storage,
      );
      expect(
        categorizeDownloadFailure(DownloadFailureKind.decode),
        ErrorCategory.parse,
      );
    });

    test('download-specific and non-error kinds stay unknown', () {
      for (final kind in [
        DownloadFailureKind.permission,
        DownloadFailureKind.resource,
        DownloadFailureKind.ownership,
        DownloadFailureKind.unknown,
        DownloadFailureKind.canceled,
        DownloadFailureKind.paused,
      ]) {
        expect(
          categorizeDownloadFailure(kind),
          ErrorCategory.unknown,
          reason: 'kind $kind is covered by download copy or hidden',
        );
      }
    });
  });
}
