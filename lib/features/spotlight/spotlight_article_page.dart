import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/navigation/routes.dart';
import '../../app/pixiv_image.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../core/spotlight/spotlight_article_controller.dart';
import '../../core/spotlight/spotlight_models.dart';
import '../../core/spotlight/spotlight_store.dart';
import '../../l10n/context.dart';

/// In-app pixivision article reader: renders the parsed [SpotlightBlock]s —
/// headings, link-aware paragraphs, images and `.illust` artwork cards —
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entry = ref.watch(spotlightArticleStoreProvider)[articleId];
    final async = ref.watch(
      spotlightArticleBodyProvider((id: articleId, url: _url)),
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(
          entry?.title ?? context.l10n.spotlightTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: async.when(
        loading: () => const FeedLoading(),
        error: (error, _) => FeedError(
          title: context.l10n.spotlightArticleLoadFailed,
          error: error,
          retryLabel: context.l10n.retry,
          onRetry: () => ref.invalidate(
            spotlightArticleBodyProvider((id: articleId, url: _url)),
          ),
        ),
        data: (body) => ListView(
          key: PageStorageKey('spotlight-article-$articleId'),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            if (body.title.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  body.title,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
            if (body.description != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
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
      SpotlightHeading(:final text, :final level) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 6),
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
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text.rich(
          TextSpan(
            style: theme.textTheme.bodyMedium,
            children: _linkSpans(context, segments, theme),
          ),
        ),
      ),
      SpotlightImage(:final url) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
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
/// (PixivImage); pixivision's own CDN does not, so it goes through
/// CachedNetworkImage.
class _ArticleImage extends StatelessWidget {
  const _ArticleImage({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    final host = Uri.tryParse(url)?.host ?? '';
    if (host.endsWith('pximg.net')) {
      return PixivImage(url: url, fit: BoxFit.contain);
    }
    return CachedNetworkImage(imageUrl: url, fit: BoxFit.contain);
  }
}

class _SpotlightIllustCardView extends StatelessWidget {
  const _SpotlightIllustCardView({required this.card});

  final SpotlightIllustCard card;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => openIllust(context, card.illustId),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              if (card.imageUrl != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    width: 72,
                    height: 72,
                    child: _ArticleImage(url: card.imageUrl!),
                  ),
                ),
              if (card.imageUrl != null) const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      card.title,
                      style: theme.textTheme.titleSmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (card.userName != null)
                      GestureDetector(
                        onTap: card.userId == null
                            ? null
                            : () => openUser(context, card.userId!),
                        child: Text(
                          card.userName!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: card.userId == null
                                ? null
                                : theme.colorScheme.primary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
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
