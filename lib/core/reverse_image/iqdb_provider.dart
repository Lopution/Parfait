import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../network/pixiv_http_client.dart';
import 'image_input.dart';
import 'reverse_image_engine.dart';
import 'reverse_image_provider.dart';

/// IQDB zero-config headless provider.
///
/// IQDB is the only major reverse-image engine without Cloudflare in front
/// (verified 2026-09-16), so a plain multipart POST to `https://iqdb.org/`
/// returns the service-rendered result page directly. Documented input
/// limits are stricter than the global ones — JPEG/PNG/GIF, 8192 KiB,
/// 7500×7500 — and are enforced by [ReverseImageEngineSpecs.iqdb] before any
/// request is sent.
///
/// The provider never parses HTML, never keeps image bytes in long-lived
/// memory and never sends Pixiv credentials or identifiers.
class IqdbWebViewProvider implements ReverseImageProvider {
  IqdbWebViewProvider({
    http.Client? client,
    DateTime Function() now = DateTime.now,
    this.observedAt = '2026-09-16',
  }) : _client = client ?? http.Client(),
       _now = now;

  static const _spec = ReverseImageEngineSpecs.iqdb;

  /// Hard bound on a server-rendered result page; a challenge/error page
  /// beyond this is still a visible failure, never an empty success.
  static const int maxResultPageBytes = 4 * 1024 * 1024;

  /// Bound on a redirect target (results stay on iqdb.org).
  static const int maxRedirectUrlLength = 2048;

  final http.Client _client;
  final DateTime Function() _now;
  final String observedAt;

  @override
  ReverseImageProviderCapability get capability =>
      ReverseImageProviderCapability(
        name: 'IQDB (anonymous WebView search)',
        kind: ReverseImageProviderKind.interactiveWebView,
        enabled: true,
        observedAt: observedAt,
        reason:
            'IQDB accepts anonymous uploads; the result page is '
            'service-rendered and shown in a controlled WebView',
      );

  @override
  Future<ReverseImageSearchOutcome> search(
    OwnedReverseImageInput input, {
    CancelToken? cancelToken,
  }) async {
    if (cancelToken?.isCancelled ?? false) {
      return const ReverseImageSearchFailure(
        code: ReverseImageProviderFailureCode.cancelled,
        message: 'reverse image search was cancelled',
      );
    }
    if (!_spec.supportsInput(input.info)) {
      return const ReverseImageSearchFailure(
        code: ReverseImageProviderFailureCode.unsupportedInput,
        message: 'image does not satisfy IQDB constraints',
      );
    }
    final file = File(input.info.path);
    final int size;
    try {
      final stat = await file.stat();
      if (stat.size <= 0) {
        return const ReverseImageSearchFailure(
          code: ReverseImageProviderFailureCode.malformedResponse,
          message: 'temporary image is empty',
        );
      }
      size = stat.size;
    } on FileSystemException {
      return const ReverseImageSearchFailure(
        code: ReverseImageProviderFailureCode.malformedResponse,
        message: 'temporary image is no longer readable',
      );
    }

    final request =
        http.MultipartRequest('POST', Uri.parse(_spec.uploadEndpoint!))
          ..files.add(
            http.MultipartFile(
              'file',
              file.openRead(),
              size,
              filename: 'reverse.png',
              contentType: MediaType.parse(_mediaTypeFor(input.info.mimeType)),
            ),
          );
    final response = await _send(request, cancelToken);
    if (response == null) {
      return const ReverseImageSearchFailure(
        code: ReverseImageProviderFailureCode.network,
        message: 'reverse image search timed out',
        retryable: true,
      );
    }
    switch (response.statusCode) {
      case 200:
        final body = <int>[];
        try {
          await for (final chunk in response.stream) {
            if (body.length > maxResultPageBytes - chunk.length) {
              return const ReverseImageSearchFailure(
                code: ReverseImageProviderFailureCode.malformedResponse,
                message: 'IQDB returned an unusable result page',
              );
            }
            body.addAll(chunk);
          }
        } on Object {
          return const ReverseImageSearchFailure(
            code: ReverseImageProviderFailureCode.malformedResponse,
            message: 'IQDB returned an unusable result page',
          );
        }
        if (body.isEmpty || body.length > maxResultPageBytes) {
          return const ReverseImageSearchFailure(
            code: ReverseImageProviderFailureCode.malformedResponse,
            message: 'IQDB returned an unusable result page',
          );
        }
        final contentType = response.headers['content-type'] ?? '';
        if (!contentType.toLowerCase().contains('text/html')) {
          return const ReverseImageSearchFailure(
            code: ReverseImageProviderFailureCode.malformedResponse,
            message: 'IQDB did not return a result page',
          );
        }
        final html = utf8.decode(body, allowMalformed: true);
        final classified = _classifyHtml(html);
        if (classified != null) return classified;
        return ReverseImageSearchWebView(
          html: html,
          observedAt: _now().toIso8601String(),
        );
      case 301:
      case 302:
      case 303:
      case 307:
      case 308:
        final location = response.headers['location'];
        final uri = location == null || location.isEmpty
            ? null
            : Uri.tryParse(location);
        if (uri == null ||
            uri.scheme != 'https' ||
            uri.host.isEmpty ||
            !_spec.webViewHosts.contains(uri.host.toLowerCase()) ||
            uri.userInfo.isNotEmpty ||
            uri.hasFragment ||
            uri.toString().length > maxRedirectUrlLength) {
          return const ReverseImageSearchFailure(
            code: ReverseImageProviderFailureCode.malformedResponse,
            message: 'IQDB redirect is not accessible',
          );
        }
        return ReverseImageSearchWebView(
          resultUrl: uri,
          observedAt: _now().toIso8601String(),
        );
      case 429:
        return ReverseImageSearchFailure(
          code: ReverseImageProviderFailureCode.rateLimited,
          message: 'IQDB rate limit reached',
          retryable: true,
          retryAfter: ReverseImageChallengeDetector.retryAfter(
            response.headers['retry-after'],
          ),
        );
      case 403:
        return const ReverseImageSearchFailure(
          code: ReverseImageProviderFailureCode.challenge,
          message: 'IQDB rejected anonymous search',
        );
      default:
        return ReverseImageSearchFailure(
          code: ReverseImageProviderFailureCode.providerUnavailable,
          message: 'IQDB unavailable (HTTP ${response.statusCode})',
          retryable: true,
        );
    }
  }

  Future<http.StreamedResponse?> _send(
    http.BaseRequest request,
    CancelToken? cancelToken,
  ) async {
    try {
      final response = await _client
          .send(request)
          .timeout(const Duration(seconds: 25));
      if (cancelToken?.isCancelled ?? false) return null;
      return response;
    } on TimeoutException {
      return null;
    } on SocketException {
      return null;
    } on http.ClientException {
      return null;
    } on HttpException {
      return null;
    } on Object {
      return null;
    }
  }

  /// A 200 HTML response can still be a challenge or a no-match page. IQDB's
  /// no-match page renders "No relevant matches" — an explicit empty success
  /// so the UI shows "no results" instead of a red failure.
  static ReverseImageSearchOutcome? _classifyHtml(String html) {
    if (ReverseImageChallengeDetector.isChallengeHtml(html)) {
      return const ReverseImageSearchFailure(
        code: ReverseImageProviderFailureCode.challenge,
        message: 'IQDB returned a challenge page',
      );
    }
    final normalized = html.toLowerCase();
    if (normalized.contains('no relevant matches') ||
        normalized.contains('no matches')) {
      return const ReverseImageSearchSuccess([]);
    }
    return null;
  }

  static String _mediaTypeFor(String mimeType) {
    final normalized = mimeType.trim().toLowerCase();
    // IQDB only documents JPEG/PNG/GIF; anything else was already rejected by
    // supportsInput, so this fallback is unreachable in practice.
    return switch (normalized) {
      'image/jpeg' || 'image/png' || 'image/gif' => normalized,
      _ => 'image/png',
    };
  }
}
