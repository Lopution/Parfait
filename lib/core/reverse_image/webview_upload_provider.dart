import '../network/pixiv_http_client.dart';
import 'image_input.dart';
import 'reverse_image_engine.dart';
import 'reverse_image_provider.dart';

/// Provider for Cloudflare-fronted engines (Ascii2D, TinEye). It performs no
/// HTTP itself: [search] validates the input against the engine spec and
/// returns a [ReverseImageSearchWebUpload] describing the engine's upload
/// page. The controlled WebView then opens that page and the still-owned
/// image is armed to its first file chooser, so the browser itself submits
/// the form and any challenge runs in a real JS/cookie context.
class WebViewUploadProvider implements ReverseImageProvider {
  WebViewUploadProvider({
    required this.spec,
    DateTime Function() now = DateTime.now,
    this.observedAt = '2026-09-16',
  }) : _now = now;

  final ReverseImageEngineSpec spec;
  final DateTime Function() _now;
  final String observedAt;

  @override
  ReverseImageProviderCapability get capability =>
      ReverseImageProviderCapability(
        name: '${spec.displayName} (WebView upload)',
        kind: ReverseImageProviderKind.interactiveWebView,
        enabled: true,
        observedAt: observedAt,
        reason:
            '${spec.displayName} is Cloudflare-fronted; the browser submits '
            'the upload form so challenges can be solved interactively',
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
    if (!spec.supportsInput(input.info)) {
      return ReverseImageSearchFailure(
        code: ReverseImageProviderFailureCode.unsupportedInput,
        message:
            'image does not satisfy ${spec.displayName} upload constraints',
      );
    }
    final page = spec.uploadPageUrl;
    if (page == null) {
      return const ReverseImageSearchFailure(
        code: ReverseImageProviderFailureCode.providerUnavailable,
        message: 'engine upload page is not configured',
      );
    }
    return ReverseImageSearchWebUpload(
      engine: spec.engine,
      uploadPageUrl: Uri.parse(page),
      imagePath: input.info.path,
      imageMimeType: input.info.mimeType,
      observedAt: _now().toIso8601String(),
    );
  }
}
