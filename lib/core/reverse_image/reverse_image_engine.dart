import 'package:flutter/foundation.dart';

import 'image_input.dart';
import 'reverse_image_navigation_policy.dart';

/// How an engine receives the image. A property of the engine, not a user
/// choice: Cloudflare-fronted engines only work when a real browser submits
/// the form (see `design.md`).
enum ReverseImageTransport { headlessUpload, webViewUpload }

enum ReverseImageEngine {
  sauceNao,
  iqdb,
  ascii2d,
  tinEye;

  /// Parses a persisted engine name; unknown values return null so callers
  /// fall back to the default explicitly.
  static ReverseImageEngine? tryFromName(Object? value) {
    if (value is! String) return null;
    for (final engine in values) {
      if (engine.name == value) return engine;
    }
    return null;
  }
}

/// Declarative contract of one reverse-image engine: endpoints, the host set
/// the controlled WebView may navigate, and the input constraints the engine
/// enforces beyond the global [ReverseImageInputLimits].
@immutable
class ReverseImageEngineSpec {
  const ReverseImageEngineSpec({
    required this.engine,
    required this.displayName,
    required this.transport,
    this.uploadEndpoint,
    this.uploadPageUrl,
    required this.webViewHosts,
    this.resultBaseUrl,
    this.maxBytes = ReverseImageInputLimits.maxEncodedBytes,
    this.allowedMimes = const {
      'image/png',
      'image/jpeg',
      'image/gif',
      'image/webp',
    },
    this.maxDimension = ReverseImageInputLimits.maxDimension,
  });

  final ReverseImageEngine engine;
  final String displayName;
  final ReverseImageTransport transport;

  /// headlessUpload: multipart POST endpoint.
  final String? uploadEndpoint;

  /// webViewUpload: engine page opened in the controlled WebView; the owned
  /// image is armed to the first file chooser.
  final String? uploadPageUrl;

  /// Hosts the controlled WebView may navigate to (result pages and their
  /// sub-resources). Lowercase, no scheme.
  final Set<String> webViewHosts;

  /// `loadHtmlString` base URL for service-rendered result pages.
  final String? resultBaseUrl;

  /// Per-engine input ceiling (bytes) — may be stricter than the global limit.
  final int maxBytes;
  final Set<String> allowedMimes;

  /// Per-engine pixel-dimension ceiling for both width and height.
  final int maxDimension;

  /// Navigation policy scoping this engine's controlled WebView to
  /// [webViewHosts] (Pixiv links still route in-app, other HTTPS goes to the
  /// external launcher).
  ReverseImageNavigationPolicy get navigationPolicy =>
      ReverseImageNavigationPolicy(webViewHosts);

  /// Whether [info] satisfies this engine's stricter-than-global
  /// constraints. Checked before any request is sent; an unsupported engine
  /// is disabled in the UI and fails fast in the provider.
  bool supportsInput(ReverseImageInputInfo info) {
    if (!allowedMimes.contains(info.mimeType)) return false;
    if (info.sizeBytes > maxBytes) return false;
    if (info.width > maxDimension || info.height > maxDimension) return false;
    return true;
  }
}

abstract final class ReverseImageEngineSpecs {
  static const sauceNao = ReverseImageEngineSpec(
    engine: ReverseImageEngine.sauceNao,
    displayName: 'SauceNAO',
    transport: ReverseImageTransport.headlessUpload,
    uploadEndpoint: _sauceNaoEndpoint,
    webViewHosts: {'saucenao.com', 'www.saucenao.com'},
    resultBaseUrl: _sauceNaoEndpoint,
  );

  /// IQDB is the only major engine without Cloudflare in front (verified
  /// 2026-09-16). Its documented limits are stricter than the global ones:
  /// JPEG/PNG/GIF only, 8192 KiB, 7500×7500.
  static const iqdb = ReverseImageEngineSpec(
    engine: ReverseImageEngine.iqdb,
    displayName: 'IQDB',
    transport: ReverseImageTransport.headlessUpload,
    uploadEndpoint: _iqdbEndpoint,
    webViewHosts: {'iqdb.org', 'www.iqdb.org'},
    resultBaseUrl: _iqdbEndpoint,
    maxBytes: 8 * 1024 * 1024,
    allowedMimes: {'image/jpeg', 'image/png', 'image/gif'},
    maxDimension: 7500,
  );

  /// Cloudflare-fronted (YetAnotherPicSearch #139 records headless 403s), so
  /// the browser submits the form. Result pages live at
  /// `/search/color/{hash}` and `/search/bovw/{hash}` — same-site navigation
  /// is allowed.
  static const ascii2d = ReverseImageEngineSpec(
    engine: ReverseImageEngine.ascii2d,
    displayName: 'Ascii2D',
    transport: ReverseImageTransport.webViewUpload,
    uploadPageUrl: _ascii2dUploadPage,
    webViewHosts: {'ascii2d.net', 'www.ascii2d.net'},
  );

  /// Also Cloudflare-fronted. The web form POSTs to `/api/v1/result_json/`
  /// and renders `/search/{query_key}`.
  static const tinEye = ReverseImageEngineSpec(
    engine: ReverseImageEngine.tinEye,
    displayName: 'TinEye',
    transport: ReverseImageTransport.webViewUpload,
    uploadPageUrl: _tinEyeUploadPage,
    webViewHosts: {'tineye.com', 'www.tineye.com'},
  );

  static const Map<ReverseImageEngine, ReverseImageEngineSpec> all = {
    ReverseImageEngine.sauceNao: sauceNao,
    ReverseImageEngine.iqdb: iqdb,
    ReverseImageEngine.ascii2d: ascii2d,
    ReverseImageEngine.tinEye: tinEye,
  };

  static const _sauceNaoEndpoint = 'https://saucenao.com/search.php';
  static const _iqdbEndpoint = 'https://iqdb.org/';
  static const _ascii2dUploadPage = 'https://ascii2d.net/';
  static const _tinEyeUploadPage = 'https://tineye.com/';
}
