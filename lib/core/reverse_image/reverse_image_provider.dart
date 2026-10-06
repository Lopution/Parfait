import 'package:flutter/foundation.dart';

import '../network/pixiv_http_client.dart';
import 'image_input.dart';
import 'reverse_image_engine.dart';

enum ReverseImageProviderKind { structuredApi, interactiveWebView, unavailable }

@immutable
class ReverseImageProviderCapability {
  const ReverseImageProviderCapability({
    required this.name,
    required this.kind,
    required this.enabled,
    required this.observedAt,
    required this.reason,
  });

  final String name;
  final ReverseImageProviderKind kind;
  final bool enabled;
  final String observedAt;
  final String reason;
}

enum ReverseImageProviderFailureCode {
  providerUnavailable,
  cancelled,
  network,
  rateLimited,
  dailyLimit,
  challenge,
  malformedResponse,

  /// The prepared input violates the selected engine's own constraints
  /// (format, size or dimensions). Fail fast — no request is sent.
  unsupportedInput,
}

class ReverseImageProviderException implements Exception {
  const ReverseImageProviderException(this.code, this.message);

  final ReverseImageProviderFailureCode code;
  final String message;

  @override
  String toString() => 'ReverseImageProviderException($code, $message)';
}

sealed class ReverseImageSearchOutcome {
  const ReverseImageSearchOutcome();
}

/// The provider detected a definitive no-match page (SauceNAO "no results",
/// IQDB "No relevant matches"): a terminal success with nothing to show. The
/// app no longer renders a native hit list — every engine's results surface
/// inside the engine's own page ([ReverseImageSearchWebView]) or upload
/// flow ([ReverseImageSearchWebUpload]).
class ReverseImageSearchSuccess extends ReverseImageSearchOutcome {
  const ReverseImageSearchSuccess();
}

/// SauceNAO-style interactive result: the service-rendered page is shown in
/// a controlled WebView (D1). Exactly one of [html] / [resultUrl] is set.
/// No HTML parsing happens in Dart; a challenge or error page is never
/// converted into an empty success.
class ReverseImageSearchWebView extends ReverseImageSearchOutcome {
  const ReverseImageSearchWebView({
    this.html,
    this.resultUrl,
    required this.observedAt,
  }) : assert(html != null || resultUrl != null);

  final String? html;
  final Uri? resultUrl;
  final String observedAt;
}

/// Cloudflare-fronted engine outcome (Ascii2D, TinEye): the engine's upload
/// page is opened in a controlled WebView and the still-owned input image is
/// armed to the first file chooser. The browser itself submits the form, so
/// JavaScript challenges run with a real cookie/JS context, which headless
/// multipart cannot provide.
class ReverseImageSearchWebUpload extends ReverseImageSearchOutcome {
  const ReverseImageSearchWebUpload({
    required this.engine,
    required this.uploadPageUrl,
    required this.imagePath,
    required this.imageMimeType,
    required this.observedAt,
    this.armedUri,
  });

  final ReverseImageEngine engine;
  final Uri uploadPageUrl;
  final String imagePath;
  final String imageMimeType;
  final String observedAt;

  /// Content URI armed to the WebView file chooser (set by the controller,
  /// not the provider). Null when the platform cannot intercept the chooser
  /// — the desktop degrade where the page's native picker re-picks the file.
  final String? armedUri;
}

class ReverseImageSearchFailure extends ReverseImageSearchOutcome {
  const ReverseImageSearchFailure({
    required this.code,
    required this.message,
    this.retryable = false,
    this.retryAfter,
  });

  final ReverseImageProviderFailureCode code;
  final String message;
  final bool retryable;
  final Duration? retryAfter;
}

abstract interface class ReverseImageProvider {
  ReverseImageProviderCapability get capability;

  Future<ReverseImageSearchOutcome> search(
    OwnedReverseImageInput input, {
    CancelToken? cancelToken,
  });
}

/// Explicitly represents the current research decision. It is not a fake
/// result provider: callers receive a terminal, visible failure and must not
/// render an empty success state.
class UnavailableReverseImageProvider implements ReverseImageProvider {
  UnavailableReverseImageProvider({
    required this.reason,
    this.name = 'reverse-image-provider',
    this.observedAt = '2026-08-28',
  });

  final String name;
  final String reason;
  final String observedAt;

  @override
  ReverseImageProviderCapability get capability =>
      ReverseImageProviderCapability(
        name: name,
        kind: ReverseImageProviderKind.unavailable,
        enabled: false,
        observedAt: observedAt,
        reason: reason,
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
    return ReverseImageSearchFailure(
      code: ReverseImageProviderFailureCode.providerUnavailable,
      message: reason,
    );
  }
}

/// Shared detection for Cloudflare/CAPTCHA challenge pages returned with a
/// 200 status by service-rendered engines. Only challenge-specific markers
/// match: a genuine SauceNAO result page embeds the Cloudflare Web Analytics
/// beacon, so the bare word "cloudflare" must not qualify.
abstract final class ReverseImageChallengeDetector {
  static bool isChallengeHtml(String html) {
    final normalized = html.toLowerCase();
    return normalized.contains('cf-chl-') ||
        normalized.contains('cf_chl_opt') ||
        normalized.contains('cf-turnstile') ||
        normalized.contains('challenges.cloudflare.com') ||
        normalized.contains('/cdn-cgi/challenge-platform/') ||
        normalized.contains('<title>just a moment...') ||
        normalized.contains('attention required! | cloudflare') ||
        normalized.contains('checking your browser before accessing') ||
        (normalized.contains('captcha') &&
            (normalized.contains('verify') ||
                normalized.contains('challenge') ||
                normalized.contains('human')));
  }

  /// Parses a `Retry-After` header into a bounded wait hint.
  static Duration? retryAfter(String? value) {
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
