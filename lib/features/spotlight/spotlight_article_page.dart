import 'dart:async';
import 'dart:convert' show jsonDecode;
import 'dart:ui' show Codec, ImmutableBuffer;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:octo_image/octo_image.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../app/layout/content_widths.dart';
import '../../app/motion/motion_tokens.dart';
import '../../app/navigation/routes.dart';
import '../../app/pixiv_image.dart';
import '../../app/widgets/app_snack_bar.dart';
import '../../app/widgets/app_top_bar.dart';
import '../../app/widgets/author_row.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../core/network/http_client_providers.dart';
import '../../core/network/api_error.dart';
import '../../core/share/share_service.dart';
import '../../core/spotlight/spotlight_article_controller.dart';
import '../../core/spotlight/article_parser.dart';
import '../../core/spotlight/spotlight_models.dart';
import '../../core/spotlight/spotlight_store.dart';
import '../../l10n/context.dart';
import '../../app/theme/func_semantic_tokens.dart';

/// In-app pixivision article reader: renders the parsed [SpotlightBlock]s —
/// headings, link-aware paragraphs, images and `.am__work` artwork cards —
/// instead of a full webview. Pixiv artwork/user links route natively;
/// everything else opens externally.
class SpotlightArticlePage extends ConsumerWidget {
  const SpotlightArticlePage({
    super.key,
    required this.articleId,
    this.articleUrl,
  });

  final int articleId;

  /// `?url=` override; falls back to the canonical pixivision URL.
  final String? articleUrl;

  String get _url => articleUrl ?? 'https://www.pixivision.net/a/$articleId';

  /// Shares the resolved article link. Platforms without a sharesheet fall
  /// back to the clipboard inside the service — surface that copy outcome.
  Future<void> _share(BuildContext context, WidgetRef ref) async {
    final title =
        ref.read(spotlightArticleStoreProvider)[articleId]?.title ??
        context.l10n.spotlightTitle;
    final outcome = await ref
        .read(shareServiceProvider)
        .share(
          SharePayload(title: title, author: 'pixivision', url: _url),
          sharePositionOrigin: shareOriginOf(context),
        );
    if (outcome == ShareOutcome.copiedToClipboard && context.mounted) {
      showAppSnackBar(context, context.l10n.linkCopied);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entry = ref.watch(spotlightArticleStoreProvider)[articleId];
    final async = ref.watch(
      spotlightArticleBodyProvider((id: articleId, url: _url)),
    );
    return Scaffold(
      appBar: AppTopBar(
        title: Text(
          entry?.title ?? context.l10n.spotlightTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.share),
            tooltip: context.l10n.share,
            onPressed: () => unawaited(_share(context, ref)),
          ),
          IconButton(
            icon: const Icon(Icons.open_in_new),
            tooltip: context.l10n.openInBrowser,
            onPressed: () => unawaited(
              launchUrl(Uri.parse(_url), mode: LaunchMode.externalApplication),
            ),
          ),
        ],
      ),
      body: async.when(
        loading: () => const FeedLoading(),
        error: (error, _) => error is ApiChallengeRequired
            ? _SpotlightChallengeRecovery(
                url: _url,
                contentBuilder: (body) => _articleBody(context, body),
              )
            : FeedError(
                title: context.l10n.spotlightArticleLoadFailed,
                error: error,
                retryLabel: context.l10n.retry,
                onRetry: () => ref.invalidate(
                  spotlightArticleBodyProvider((id: articleId, url: _url)),
                ),
              ),
        // Article-width cap (a ContentWidths role, not a breakpoint): the
        // column stays top-centered and readable on wide surfaces while
        // narrow phones keep full width.
        data: (body) => _articleBody(context, body),
      ),
    );
  }

  Widget _articleBody(BuildContext context, SpotlightArticleBody body) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: ContentWidths.article),
      child: ListView(
        key: PageStorageKey('spotlight-article-$articleId'),
        padding: const EdgeInsets.fromLTRB(
          FuncSpacing.lg,
          FuncSpacing.sm,
          FuncSpacing.lg,
          FuncSpacing.xxl,
        ),
        children: [
          if (body.title.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: FuncSpacing.sm),
              child: SelectableText(
                body.title,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
          if (body.description != null)
            Padding(
              padding: const EdgeInsets.only(bottom: FuncSpacing.md),
              child: SelectableText(
                body.description!,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          for (final block in body.blocks) _SpotlightBlockView(block: block),
        ],
      ),
    ),
  );
}

/// Runs a pixivision Cloudflare challenge in the browser engine. The first
/// 15 seconds keep the WebView at one pixel while the native article remains
/// the visible surface. If the managed challenge needs a tap or checkbox, the
/// same controller is promoted to a full-page interactive view.
class _SpotlightChallengeRecovery extends StatefulWidget {
  const _SpotlightChallengeRecovery({
    required this.url,
    required this.contentBuilder,
  });

  final String url;
  final Widget Function(SpotlightArticleBody body) contentBuilder;

  @override
  State<_SpotlightChallengeRecovery> createState() =>
      _SpotlightChallengeRecoveryState();
}

class _SpotlightChallengeRecoveryState
    extends State<_SpotlightChallengeRecovery> {
  static const _automaticTimeout = Duration(seconds: 15);

  late WebViewController _controller;
  Timer? _timeout;
  Timer? _inspectionTimer;
  SpotlightArticleBody? _body;
  Object? _failure;
  var _interactive = false;
  var _attempt = 0;
  var _inspectionInFlight = false;

  @override
  void initState() {
    super.initState();
    _begin();
  }

  @override
  void dispose() {
    _timeout?.cancel();
    _inspectionTimer?.cancel();
    super.dispose();
  }

  void _begin() {
    _timeout?.cancel();
    _inspectionTimer?.cancel();
    _interactive = false;
    _failure = null;
    _body = null;
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) => unawaited(_inspectDocument()),
          onWebResourceError: (error) {
            if (error.isForMainFrame == false) return;
            _setFailure(error.description);
          },
        ),
      );
    _timeout = Timer(_automaticTimeout, () {
      if (!mounted || _body != null || _failure != null) return;
      setState(() => _interactive = true);
    });
    _inspectionTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      unawaited(_inspectDocument());
    });
    unawaited(_loadDocument());
  }

  Future<void> _loadDocument() async {
    try {
      await _controller.loadRequest(Uri.parse(widget.url));
    } on Object catch (error) {
      _setFailure(error);
    }
  }

  Future<void> _inspectDocument() async {
    if (!mounted || _body != null || _inspectionInFlight) return;
    _inspectionInFlight = true;
    try {
      final result = await _controller.runJavaScriptReturningResult(
        'document.documentElement.outerHTML',
      );
      final html = _decodeJavaScriptString(result);
      // A challenge document can finish several times while its script swaps
      // frames. Only the rendered article is accepted as a successful hand-off.
      if (html.contains('_cf_chl_opt') || !html.contains('<article')) return;
      final body = parseSpotlightArticle(html);
      if (!mounted) return;
      _timeout?.cancel();
      _inspectionTimer?.cancel();
      SpotlightWebSession.markVerified();
      setState(() => _body = body);
    } on Object {
      // The WebView can be between documents while a challenge redirects;
      // keep polling until the timeout promotes it to the interactive state.
    } finally {
      _inspectionInFlight = false;
    }
  }

  String _decodeJavaScriptString(Object result) {
    if (result is! String) return '$result';
    try {
      final decoded = jsonDecode(result);
      return decoded is String ? decoded : result;
    } on FormatException {
      return result;
    }
  }

  void _setFailure(Object error) {
    if (!mounted || _body != null || _failure != null) return;
    _timeout?.cancel();
    _inspectionTimer?.cancel();
    setState(() => _failure = error);
  }

  void _retry() {
    setState(() {
      _attempt++;
      _begin();
    });
  }

  @override
  Widget build(BuildContext context) {
    final body = _body;
    if (body != null) return widget.contentBuilder(body);

    final failure = _failure;
    if (failure != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(FuncSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.public_off,
                size: 48,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: FuncSpacing.md),
              Text(
                context.l10n.spotlightChallengeFailed,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: FuncSpacing.md),
              StateActionButton(label: context.l10n.retry, onPressed: _retry),
              TextButton.icon(
                icon: const Icon(Icons.open_in_new),
                label: Text(context.l10n.openInBrowser),
                onPressed: () => unawaited(
                  launchUrl(
                    Uri.parse(widget.url),
                    mode: LaunchMode.externalApplication,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (_interactive) {
      return Column(
        children: [
          Material(
            color: Theme.of(context).colorScheme.surfaceContainer,
            child: Padding(
              padding: const EdgeInsets.all(FuncSpacing.sm),
              child: Text(
                context.l10n.spotlightChallengeManual,
                textAlign: TextAlign.center,
              ),
            ),
          ),
          Expanded(
            child: WebViewWidget(
              key: ValueKey(_attempt),
              controller: _controller,
            ),
          ),
        ],
      );
    }

    return Stack(
      children: [
        const FeedLoading(),
        Positioned(
          left: -1,
          top: -1,
          width: 1,
          height: 1,
          child: Opacity(
            opacity: 0,
            child: WebViewWidget(
              key: ValueKey(_attempt),
              controller: _controller,
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: FuncSpacing.xl,
          child: Text(
            context.l10n.spotlightChallengeVerifying,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

class _SpotlightBlockView extends StatefulWidget {
  const _SpotlightBlockView({required this.block});

  final SpotlightBlock block;

  @override
  State<_SpotlightBlockView> createState() => _SpotlightBlockViewState();
}

class _SpotlightBlockViewState extends State<_SpotlightBlockView> {
  /// Link recognizers owned by the current paragraph spans — kept here so
  /// they can be disposed instead of leaking across rebuilds.
  var _recognizers = <TapGestureRecognizer>[];

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return switch (widget.block) {
      // Paragraph-level selection (no SelectionArea — its AOT cost was
      // rejected): heading and paragraph text is selectable per block, and
      // span recognizers stay live inside SelectableText.
      SpotlightHeading(:final text, :final level) => Padding(
        padding: const EdgeInsets.only(
          top: FuncSpacing.lg,
          bottom: FuncSpacing.xs,
        ),
        child: SelectableText(
          text,
          style: switch (level) {
            2 => theme.textTheme.titleLarge,
            3 => theme.textTheme.titleMedium,
            _ => theme.textTheme.titleSmall,
          },
        ),
      ),
      SpotlightParagraph(:final segments) => Padding(
        padding: const EdgeInsets.symmetric(vertical: FuncSpacing.xs),
        child: SelectableText.rich(
          TextSpan(
            style: theme.textTheme.bodyMedium,
            children: _linkSpans(context, segments, theme),
          ),
        ),
      ),
      SpotlightImage(:final url) => Padding(
        padding: const EdgeInsets.symmetric(vertical: FuncSpacing.sm),
        child: _ArticleImage(url: url),
      ),
      final SpotlightIllustCard card => _SpotlightIllustCardView(card: card),
    };
  }

  /// TextSpan-per-segment with tap recognizers: the old WidgetSpan +
  /// GestureDetector links sat outside the text flow, so they broke text
  /// selection and screen-reader announcement of the paragraph.
  List<InlineSpan> _linkSpans(
    BuildContext context,
    List<({String text, String? href})> segments,
    ThemeData theme,
  ) {
    for (final r in _recognizers) {
      r.dispose();
    }
    final next = <TapGestureRecognizer>[];
    final spans = <InlineSpan>[];
    for (final segment in segments) {
      final href = segment.href;
      if (href == null) {
        spans.add(TextSpan(text: segment.text));
        continue;
      }
      final recognizer = TapGestureRecognizer()
        ..onTap = () => _openSpotlightLink(context, href);
      next.add(recognizer);
      spans.add(
        TextSpan(
          text: segment.text,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.primary,
          ),
          recognizer: recognizer,
        ),
      );
    }
    _recognizers = next;
    return spans;
  }
}

/// Article body images: pximg hosts need the Pixiv referer chain
/// (PixivImage); pixivision's own CDN does not, so it is plain third-party
/// traffic.
class _ArticleImage extends ConsumerWidget {
  const _ArticleImage({required this.url, this.placeholder});

  final String url;

  /// Shown until the image decodes; null keeps each widget's default.
  final Widget? placeholder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final placeholder = this.placeholder;
    final host = Uri.tryParse(url)?.host ?? '';
    if (host.endsWith('pximg.net')) {
      return PixivImage(
        url: url,
        fit: BoxFit.contain,
        placeholderWidget: placeholder,
      );
    }
    return OctoImage(
      image: _ThirdPartyImage(ref.watch(thirdPartyHttpClientProvider), url),
      fit: BoxFit.contain,
      placeholderBuilder: placeholder == null ? null : (_) => placeholder,
      errorBuilder: (_, _, _) => const Icon(Icons.broken_image),
      // PixivImage's load transition: the image at once, the placeholder
      // dissolving off it.
      fadeInDuration: Duration.zero,
      fadeOutDuration: MotionTokens.resolve(context, MotionTokens.imageFade),
      fadeOutCurve: MotionTokens.imageFadeCurve,
    );
  }
}

/// An image fetched through the third-party client: system routing, no
/// Pixiv network policy and no disk cache. Flutter's image cache keeps the
/// decode by client and URL.
@immutable
class _ThirdPartyImage extends ImageProvider<_ThirdPartyImage> {
  const _ThirdPartyImage(this.client, this.url);

  final http.Client client;
  final String url;

  @override
  Future<_ThirdPartyImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    _ThirdPartyImage key,
    ImageDecoderCallback decode,
  ) => MultiFrameImageStreamCompleter(
    codec: _load(decode),
    scale: 1,
    debugLabel: url,
    informationCollector: () => [DiagnosticsProperty('URL', url)],
  );

  Future<Codec> _load(ImageDecoderCallback decode) async {
    final uri = Uri.parse(url);
    final response = await client.get(uri);
    if (response.statusCode != 200) {
      throw NetworkImageLoadException(
        statusCode: response.statusCode,
        uri: uri,
      );
    }
    return decode(await ImmutableBuffer.fromUint8List(response.bodyBytes));
  }

  @override
  bool operator ==(Object other) =>
      other is _ThirdPartyImage &&
      identical(other.client, client) &&
      other.url == url;

  @override
  int get hashCode => Object.hash(identityHashCode(client), url);
}

/// A work from the article, the way pixivision shows it: the image at
/// full column width, then its title and author.
class _SpotlightIllustCardView extends StatelessWidget {
  const _SpotlightIllustCardView({required this.card});

  final SpotlightIllustCard card;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: FuncSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (card.imageUrl case final imageUrl?)
            Semantics(
              container: true,
              button: true,
              label: card.title,
              child: ClipRRect(
                borderRadius: FuncShape.card,
                child: Stack(
                  children: [
                    _WorkImage(url: imageUrl),
                    Positioned.fill(
                      child: Material(
                        type: MaterialType.transparency,
                        child: InkWell(
                          onTap: () => openIllust(context, card.illustId),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: FuncSpacing.sm),
          Text(
            card.title,
            style: theme.textTheme.titleSmall,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          if (card.userName case final userName?)
            if (card.userId case final userId?)
              AuthorRow(
                userId: userId,
                name: userName,
                avatarUrl: card.userAvatarUrl,
              )
            else
              Text(
                userName,
                style: theme.textTheme.bodySmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
        ],
      ),
    );
  }
}

/// Square while loading; once decoded, the image's own ratio up to
/// [_maxHeightFactor] × the width, letterboxed beyond that.
class _WorkImage extends StatelessWidget {
  const _WorkImage({required this.url});

  final String url;

  static const _maxHeightFactor = 1.5;

  @override
  Widget build(BuildContext context) {
    final background = Theme.of(context).colorScheme.surfaceContainerHighest;
    return LayoutBuilder(
      builder: (context, constraints) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: constraints.maxWidth * _maxHeightFactor,
        ),
        child: ColoredBox(
          color: background,
          child: _ArticleImage(
            url: url,
            placeholder: AspectRatio(
              aspectRatio: 1,
              child: ColoredBox(color: background),
            ),
          ),
        ),
      ),
    );
  }
}

final _artworksPattern = RegExp(r'/artworks/(\d+)');
final _usersPattern = RegExp(r'/users/(\d+)');
const _pixivHosts = {'pixiv.net', 'www.pixiv.net', 'www.pixivision.net'};

/// Link dispatch for article paragraphs: Pixiv artwork and user links open
/// the native detail pages; everything else goes to the external browser.
void _openSpotlightLink(BuildContext context, String href) {
  final resolved = Uri.parse('https://www.pixivision.net/').resolve(href);
  if (_pixivHosts.contains(resolved.host)) {
    final artwork = _artworksPattern.firstMatch(resolved.path);
    if (artwork != null) {
      openIllust(context, int.parse(artwork.group(1)!));
      return;
    }
    final user = _usersPattern.firstMatch(resolved.path);
    if (user != null) {
      openUser(context, int.parse(user.group(1)!));
      return;
    }
  }
  unawaited(launchUrl(resolved, mode: LaunchMode.externalApplication));
}
