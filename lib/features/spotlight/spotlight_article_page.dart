import 'dart:async';
import 'dart:ui' show Codec, ImmutableBuffer;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:octo_image/octo_image.dart';

import '../../app/layout/app_breakpoints.dart';
import '../../app/layout/content_widths.dart';
import '../../app/motion/spring_size.dart';
import '../../app/navigation/route_facade.dart';
import '../../app/pixiv_image.dart';
import '../../app/widgets/app_snack_bar.dart';
import '../../app/widgets/app_top_bar.dart';
import '../../app/widgets/author_row.dart';
import '../../app/widgets/errors/error_details.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/smooth_wheel_scroll.dart';
import '../../core/network/http_client_providers.dart';
import '../../core/network/api_error.dart';
import '../../core/platform/android_intent_channel.dart';
import '../../core/share/share_service.dart';
import '../../core/spotlight/spotlight_article_controller.dart';
import '../../core/spotlight/spotlight_models.dart';
import '../../core/spotlight/spotlight_repository.dart';
import '../../core/spotlight/spotlight_store.dart';
import '../../l10n/context.dart';
import 'spotlight_challenge_view.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../app/icons/app_icons.dart';

/// In-app pixivision article reader: renders the parsed [SpotlightBlock]s —
/// headings, link-aware paragraphs, images and `.am__work` artwork cards —
/// instead of a full webview. Pixiv artwork/user links route natively;
/// everything else opens externally.
class SpotlightArticlePage extends ConsumerStatefulWidget {
  const SpotlightArticlePage({
    super.key,
    required this.articleId,
    this.articleUrl,
  });

  final int articleId;

  /// `?url=` override; falls back to the canonical pixivision URL.
  final String? articleUrl;

  /// The cover takes at most this share of the page's height, so a landscape
  /// window still opens on the article's first lines instead of a
  /// full-screen image. It is the page body's viewport, bar excluded.
  static const coverViewportShare = 0.5;

  @override
  ConsumerState<SpotlightArticlePage> createState() =>
      _SpotlightArticlePageState();
}

class _SpotlightArticlePageState extends ConsumerState<SpotlightArticlePage> {
  // Latch the cover source the first time the parsed body actually renders:
  // when opened from a feed or search card the store entry is already loaded
  // (`PAGE-06`), whereas a deep link renders the article's `og:image` first
  // and must not later unmount that loaded image if a background branch warms
  // `spotlightFeedProvider`.
  bool _coverLocked = false;
  String? _coverUrl;

  String get _url =>
      widget.articleUrl ?? 'https://www.pixivision.net/a/${widget.articleId}';

  @override
  void didUpdateWidget(covariant SpotlightArticlePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.articleId != widget.articleId ||
        oldWidget.articleUrl != widget.articleUrl) {
      _coverLocked = false;
      _coverUrl = null;
    }
  }

  String? _resolveCoverUrl(SpotlightArticle? entry) {
    if (!_coverLocked) {
      _coverLocked = true;
      _coverUrl = entry?.thumbnailUrl;
    }
    return _coverUrl;
  }

  /// Shares the resolved article link. Platforms without a sharesheet fall
  /// back to the clipboard inside the service — surface that copy outcome.
  Future<void> _share(BuildContext context, String url) async {
    final title =
        ref.read(spotlightArticleStoreProvider)[widget.articleId]?.title ??
        ref
            .read(
              spotlightArticleBodyProvider((id: widget.articleId, url: _url)),
            )
            .value
            ?.title ??
        context.l10n.spotlightTitle;
    final outcome = await ref
        .read(shareServiceProvider)
        .share(
          SharePayload(title: title, author: 'pixivision', url: url),
          sharePositionOrigin: shareOriginOf(context),
        );
    if (outcome == ShareOutcome.copiedToClipboard && context.mounted) {
      showAppSnackBar(context, context.l10n.linkCopied);
    }
  }

  @override
  Widget build(BuildContext context) {
    final entry = ref.watch(
      spotlightArticleStoreProvider.select((s) => s[widget.articleId]),
    );
    final async = ref.watch(
      spotlightArticleBodyProvider((id: widget.articleId, url: _url)),
    );
    final resolvedTitle = entry?.title ?? async.value?.title;
    final validArticleUri = _tryValidArticleUri(_url);
    return Scaffold(
      appBar: AppTopBar(
        contentWidth: ContentWidths.article,
        title: Text(
          resolvedTitle ?? context.l10n.spotlightTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          Builder(
            builder: (buttonContext) => IconButton(
              icon: const Icon(AppIcons.share),
              tooltip: context.l10n.share,
              onPressed: validArticleUri == null
                  ? null
                  : () => unawaited(
                      _share(buttonContext, validArticleUri.toString()),
                    ),
            ),
          ),
          IconButton(
            icon: const Icon(AppIcons.externalLink),
            tooltip: context.l10n.openInBrowser,
            onPressed: validArticleUri == null
                ? null
                : () => unawaited(
                    _openExternalUrl(context, ref, validArticleUri.toString()),
                  ),
          ),
        ],
      ),
      body: async.when(
        loading: () => const ContentWidthCap(
          maxWidth: ContentWidths.article,
          child: FeedLoading(),
        ),
        error: (error, _) =>
            error is ApiChallengeRequired && validArticleUri != null
            ? SpotlightChallengeView(
                uri: validArticleUri,
                contentBuilder: (body) =>
                    _articleBody(context, body, _resolveCoverUrl(entry)),
              )
            : ContentWidthCap(
                maxWidth: ContentWidths.article,
                child: FeedError(
                  title: context.l10n.spotlightArticleLoadFailed,
                  error: error,
                  retryLabel: context.l10n.retry,
                  onRetry: () => ref.invalidate(
                    spotlightArticleBodyProvider((
                      id: widget.articleId,
                      url: _url,
                    )),
                  ),
                ),
              ),
        // Article-width cap (a ContentWidths role, not a breakpoint): the
        // column stays top-centered and readable on wide surfaces while
        // narrow phones keep full width.
        data: (body) => _articleBody(context, body, _resolveCoverUrl(entry)),
      ),
    );
  }

  Widget _articleBody(
    BuildContext context,
    SpotlightArticleBody body,
    String? coverUrl,
  ) => LayoutBuilder(
    builder: (context, constraints) {
      // Phone portraits keep their established cover treatment; tablet and
      // desktop surfaces cap it in either orientation so the first lines
      // remain on the opening screen.
      final coverMaxHeight = constraints.maxWidth >= AppBreakpoints.medium
          ? constraints.maxHeight * SpotlightArticlePage.coverViewportShare
          : null;
      return Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: ContentWidths.article),
          // One selection region for the whole article: text is plain Text,
          // so no paragraph owns a Scrollable the app-wide bouncing physics
          // could leak into, and a selection can span paragraphs.
          child: SelectionArea(
            child: SmoothWheelScroll(
              builder: (context, controller, physics) => ListView(
                key: PageStorageKey('spotlight-article-${widget.articleId}'),
                controller: controller,
                physics: physics,
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
                      child: Text(
                        body.title,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                    ),
                  if (body.description != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: FuncSpacing.md),
                      child: Text(
                        body.description!,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  for (final block in body.blocks)
                    _SpotlightBlockView(
                      block: block,
                      coverUrl: coverUrl,
                      coverMaxHeight: coverMaxHeight,
                      onOpenLink: (href) =>
                          _openSpotlightLink(context, ref, href),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _SpotlightBlockView extends StatefulWidget {
  const _SpotlightBlockView({
    required this.block,
    required this.onOpenLink,
    this.coverUrl,
    this.coverMaxHeight,
  });

  final SpotlightBlock block;
  final void Function(String href) onOpenLink;

  /// The list entry's pximg cover; a deep-linked article has none and keeps
  /// the page's own.
  final String? coverUrl;

  /// Height cap for the article's cover image; null leaves it at its own
  /// ratio.
  final double? coverMaxHeight;

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
      SpotlightHeading(:final text, :final level) => Padding(
        padding: const EdgeInsets.only(
          top: FuncSpacing.lg,
          bottom: FuncSpacing.xs,
        ),
        child: Text(
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
        child: Text.rich(
          TextSpan(
            style: theme.textTheme.bodyMedium,
            children: _linkSpans(context, segments, theme),
          ),
        ),
      ),
      SpotlightImage(:final url, :final cover) => Padding(
        padding: const EdgeInsets.symmetric(vertical: FuncSpacing.sm),
        // Rounded like the work images further down; pass the radius into
        // `_ArticleImage` so desktop height-capped covers clip tightly around
        // the image bounds rather than the full-width `Center`.
        child: _ArticleImage(
          url: cover ? widget.coverUrl ?? url : url,
          maxHeight: cover ? widget.coverMaxHeight : null,
          borderRadius: FuncShape.card,
        ),
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
        ..onTap = () => widget.onOpenLink(href);
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
///
/// The page names no image sizes, so an image holds a square until it
/// decodes, then takes its own ratio; the box springs between the two. No
/// crossfade: the placeholder dissolving over an image of another height
/// read as the image loading in bands.
class _ArticleImage extends ConsumerWidget {
  const _ArticleImage({required this.url, this.maxHeight, this.borderRadius});

  final String url;

  /// The tallest the image (and its placeholder) may be drawn: the cover's
  /// height cap. The image keeps its ratio at that height and centres in
  /// the column; null draws it at its own ratio, full column width.
  final double? maxHeight;

  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final placeholder = AspectRatio(
      aspectRatio: 1,
      child: ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
      ),
    );
    final host = Uri.tryParse(url)?.host ?? '';
    final image = SpringSize(
      child: host.endsWith('pximg.net')
          ? PixivImage(
              url: url,
              fit: BoxFit.contain,
              sizeToImage: true,
              fade: false,
              placeholderWidget: placeholder,
            )
          : OctoImage(
              image: _ThirdPartyImage(
                ref.watch(thirdPartyHttpClientProvider),
                url,
              ),
              fit: BoxFit.contain,
              imageBuilder: (_, child) => AspectFitBox(child: child),
              placeholderBuilder: (_) => placeholder,
              errorBuilder: (_, _, _) => const Icon(AppIcons.illustBroken),
              fadeInDuration: Duration.zero,
              fadeOutDuration: Duration.zero,
            ),
    );
    final clipped = borderRadius == null
        ? image
        : ClipRRect(borderRadius: borderRadius!, child: image);
    final maxHeight = this.maxHeight;
    if (maxHeight == null) return clipped;
    // Both paths size themselves within a bounded height (AspectFitBox for
    // the pixels, AspectRatio for the placeholder), so the same cap holds
    // the loading box; centring keeps the narrower image in the column.
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: clipped,
      ),
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
              child: _WorkImage(
                url: imageUrl,
                onTap: () => openIllust(context, card.illustId),
              ),
            ),
          const SizedBox(height: FuncSpacing.sm),
          InkWell(
            borderRadius: FuncShape.badge,
            onTap: () => openIllust(context, card.illustId),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: FuncSpacing.xxs),
              child: Text(
                card.title,
                style: theme.textTheme.titleSmall,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
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

/// A work's image, centered at its own ratio up to [_maxHeightFactor] ×
/// the column width: a tall work is drawn narrower, as pixivision does,
/// rather than boxed in bars. The corners and the ripple follow the image.
class _WorkImage extends StatelessWidget {
  const _WorkImage({required this.url, required this.onTap});

  final String url;
  final VoidCallback onTap;

  static const _maxHeightFactor = 1.5;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: constraints.maxWidth * _maxHeightFactor,
        ),
        child: ClipRRect(
          borderRadius: FuncShape.card,
          child: Stack(
            children: [
              _ArticleImage(url: url),
              Positioned.fill(
                child: Material(
                  type: MaterialType.transparency,
                  child: InkWell(onTap: onTap),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

final _artworksPattern = RegExp(r'/artworks/(\d+)');
final _usersPattern = RegExp(r'/users/(\d+)');
const _pixivHosts = {'pixiv.net', 'www.pixiv.net', 'www.pixivision.net'};

Uri? _tryValidArticleUri(String raw) {
  try {
    return PixivSpotlightRepository.articleUri(raw);
  } on ApiParseError {
    return null;
  }
}

Future<void> _openExternalUrl(
  BuildContext context,
  WidgetRef ref,
  String url,
) async {
  try {
    await ref.read(outboundUrlOpenerProvider).openExternal(url);
  } on Object catch (error) {
    if (!context.mounted) return;
    showErrorSnackBar(
      context,
      action: context.l10n.illustDetailOpenLinkFailed,
      error: error,
    );
  }
}

/// Link dispatch for article paragraphs: only http(s) links are accepted;
/// Pixiv artwork and user links open the native detail pages, and other
/// http(s) links go through [outboundUrlOpenerProvider].
void _openSpotlightLink(BuildContext context, WidgetRef ref, String href) {
  final parsed = Uri.tryParse(href.trim());
  if (parsed == null) return;
  final resolved = Uri.parse('https://www.pixivision.net/').resolveUri(parsed);
  if ((!resolved.isScheme('http') && !resolved.isScheme('https')) ||
      resolved.host.isEmpty) {
    return;
  }
  if (_pixivHosts.contains(resolved.host.toLowerCase())) {
    final artwork = _artworksPattern.firstMatch(resolved.path);
    if (artwork != null) {
      unawaited(openIllust(context, int.parse(artwork.group(1)!)));
      return;
    }
    final user = _usersPattern.firstMatch(resolved.path);
    if (user != null) {
      unawaited(openUser(context, int.parse(user.group(1)!)));
      return;
    }
  }
  unawaited(_openExternalUrl(context, ref, resolved.toString()));
}
