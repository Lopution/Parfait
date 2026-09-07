import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../network/pixiv_http_client.dart';
import 'image_input.dart';
import 'reverse_image_provider.dart';

/// SauceNAO zero-config WebView/HTML provider (D1).
///
/// The provider only uploads the owned temporary file to the public
/// `search.php` form (anonymous, no api_key) and hands the service-rendered
/// result page back to the UI as a webview outcome. It never parses HTML,
/// never extracts image bytes into long-lived memory and never sends Pixiv
/// credentials, account ids or device identifiers.
///
/// External facts (re-verified 2026-09-07, see the task's
/// `research/anonymous-policy.md`): the public `search.php` form still
/// accepts anonymous multipart uploads and renders a result page; the JSON
/// API (`output_type=2`) refuses anonymous callers ("The anonymous account
/// type does not permit API usage"), which is why this provider is the HTML
/// route. Unregistered limits are tracked per IP (4 searches / 30 s and 150
/// / day as documented by SauceNAO's own limit pages); they surface as 429
/// with `retry-after` or as a rendered "Daily Search Limit Exceeded" /
/// "Search Rate Too High" page.
///
/// The endpoint stays exactly `https://saucenao.com/search.php`; quota
/// numbers are never hardcoded into the UI, only the observed response is
/// surfaced.
class SauceNaoWebViewProvider implements ReverseImageProvider {
  SauceNaoWebViewProvider({
    http.Client? client,
    this.endpoint = defaultEndpoint,
    DateTime Function() now = DateTime.now,
    this.observedAt = '2026-09-03',
  }) : _client = client ?? http.Client(),
       _now = now;

  static const String defaultEndpoint = 'https://saucenao.com/search.php';

  /// Hard bound on a server-rendered result page; a challenge/error page
  /// beyond this is still a visible failure, never an empty success.
  static const int maxResultPageBytes = 4 * 1024 * 1024;

  /// Bound on a redirect target (anonymous results stay on saucenao.com).
  static const int maxRedirectUrlLength = 2048;

  final http.Client _client;
  final String endpoint;
  final DateTime Function() _now;
  final String observedAt;

  @override
  ReverseImageProviderCapability get capability =>
      ReverseImageProviderCapability(
        name: 'SauceNAO (anonymous WebView search)',
        kind: ReverseImageProviderKind.interactiveWebView,
        enabled: true,
        observedAt: observedAt,
        reason:
            'SauceNAO allows anonymous searches; the result page is '
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
    if (size > ReverseImageInputLimits.maxEncodedBytes) {
      return const ReverseImageSearchFailure(
        code: ReverseImageProviderFailureCode.malformedResponse,
        message: 'temporary image exceeds the size limit',
      );
    }

    final request = http.MultipartRequest('POST', Uri.parse(endpoint))
      ..files.add(
        http.MultipartFile(
          'file',
          file.openRead(),
          size,
          filename: 'reverse.png',
          // MediaType is validated against the input MIME; format and MIME
          // were already shown to be consistent by the input validator.
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
                message: 'SauceNAO returned an unusable result page',
              );
            }
            body.addAll(chunk);
          }
        } on Object {
          return const ReverseImageSearchFailure(
            code: ReverseImageProviderFailureCode.malformedResponse,
            message: 'SauceNAO returned an unusable result page',
          );
        }
        if (body.isEmpty || body.length > maxResultPageBytes) {
          return const ReverseImageSearchFailure(
            code: ReverseImageProviderFailureCode.malformedResponse,
            message: 'SauceNAO returned an unusable result page',
          );
        }
        final contentType = response.headers['content-type'] ?? '';
        if (!contentType.toLowerCase().contains('text/html')) {
          // A JSON error or challenge body must not render as an empty list.
          return const ReverseImageSearchFailure(
            code: ReverseImageProviderFailureCode.malformedResponse,
            message: 'SauceNAO did not return a result page',
          );
        }
        final html = utf8.decode(body, allowMalformed: true);
        final htmlFailure = _classifyHtml(html);
        if (htmlFailure != null) return htmlFailure;
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
            !_allowedResultHost(uri.host) ||
            uri.userInfo.isNotEmpty ||
            uri.hasFragment ||
            uri.toString().length > maxRedirectUrlLength) {
          return const ReverseImageSearchFailure(
            code: ReverseImageProviderFailureCode.malformedResponse,
            message: 'SauceNAO redirect is not accessible',
          );
        }
        return ReverseImageSearchWebView(
          resultUrl: uri,
          observedAt: _now().toIso8601String(),
        );
      case 429:
        return ReverseImageSearchFailure(
          code: ReverseImageProviderFailureCode.rateLimited,
          message: 'SauceNAO anonymous rate limit reached',
          retryable: true,
          retryAfter: _retryAfter(response.headers['retry-after']),
        );
      case 403:
        return const ReverseImageSearchFailure(
          code: ReverseImageProviderFailureCode.providerUnavailable,
          message: 'SauceNAO rejected anonymous search',
        );
      default:
        return ReverseImageSearchFailure(
          code: ReverseImageProviderFailureCode.providerUnavailable,
          message: 'SauceNAO unavailable (HTTP ${response.statusCode})',
          retryable: true,
        );
    }
  }

  Future<http.StreamedResponse?> _send(
    http.BaseRequest request,
    CancelToken? cancelToken,
  ) async {
    try {
      final future = _client.send(request).timeout(const Duration(seconds: 25));
      // Cooperative cancellation: the platform request is not interrupted,
      // but the result is dropped when the token fired meanwhile.
      final response = await future;
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

  static bool _allowedResultHost(String host) {
    final normalized = host.toLowerCase();
    return normalized == 'saucenao.com' || normalized == 'www.saucenao.com';
  }

  /// A 200 HTML response can still be a CAPTCHA/rate-limit/no-match page.
  /// Those pages are not a successful search result and must remain visible
  /// as a classified failure instead of entering the WebView success state.
  static ReverseImageSearchFailure? _classifyHtml(String html) {
    final normalized = html.toLowerCase();
    // "Daily Search Limit Exceeded." / "Search Rate Too High." are the
    // strings SauceNAO renders for the per-day and per-30-second limits.
    if (normalized.contains('too many requests') ||
        normalized.contains('rate limit') ||
        normalized.contains('search limit') ||
        normalized.contains('search rate too high')) {
      return const ReverseImageSearchFailure(
        code: ReverseImageProviderFailureCode.rateLimited,
        message: 'SauceNAO anonymous rate limit reached',
        retryable: true,
      );
    }
    // Only challenge-page markers. A genuine result page embeds the
    // Cloudflare Web Analytics beacon (`static.cloudflareinsights.com`), so
    // the bare word "cloudflare" must not be treated as a challenge
    // (fixture: test/fixtures/saucenao/anonymous_result_page.html).
    final challenge =
        normalized.contains('cf-chl-') ||
        normalized.contains('cf_chl_opt') ||
        normalized.contains('/cdn-cgi/challenge-platform/') ||
        normalized.contains('<title>just a moment...') ||
        normalized.contains('attention required! | cloudflare') ||
        normalized.contains('checking your browser before accessing') ||
        (normalized.contains('captcha') &&
            (normalized.contains('verify') ||
                normalized.contains('challenge') ||
                normalized.contains('human')));
    if (challenge) {
      return const ReverseImageSearchFailure(
        code: ReverseImageProviderFailureCode.providerUnavailable,
        message: 'SauceNAO returned a challenge page',
      );
    }
    if (normalized.contains('no results') ||
        normalized.contains('no matches') ||
        normalized.contains('nothing found') ||
        normalized.contains('no image match') ||
        normalized.contains('没有匹配') ||
        normalized.contains('没有结果')) {
      return const ReverseImageSearchFailure(
        code: ReverseImageProviderFailureCode.malformedResponse,
        message: 'SauceNAO found no matching results',
      );
    }
    return null;
  }

  static String _mediaTypeFor(String mimeType) {
    final normalized = mimeType.trim().toLowerCase();
    switch (normalized) {
      case 'image/jpeg':
      case 'image/png':
      case 'image/gif':
      case 'image/webp':
        return normalized;
      default:
        return 'image/png';
    }
  }

  static Duration? _retryAfter(String? value) {
    if (value == null) return null;
    final seconds = int.tryParse(value.trim());
    if (seconds != null && seconds >= 0) {
      return Duration(seconds: seconds);
    }
    final httpDate = DateTime.tryParse(value.trim());
    if (httpDate != null) {
      final delta = httpDate.difference(DateTime.now());
      return delta.isNegative ? const Duration(seconds: 1) : delta;
    }
    return null;
  }
}
