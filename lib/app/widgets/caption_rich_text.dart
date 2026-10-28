import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../navigation/routes.dart';
import 'errors/error_details.dart';
import 'expandable_text.dart';
import '../../core/entity/illust_caption.dart';
import '../../core/platform/android_intent_channel.dart';
import '../../core/platform/intent_router.dart';
import '../../l10n/context.dart';

/// Renders a parsed HTML caption with clickable links (U6).
///
/// Links resolve as deep links do ([IntentRouter.route]): a user or work,
/// on www.pixiv.net or as `pixiv://`, opens inside the app with the same
/// right-in rhythm as feed cards; any other app link (`pixiv://account`
/// included) does nothing; anything else opens via the outbound Android
/// intent.
class CaptionRichText extends ConsumerStatefulWidget {
  const CaptionRichText({super.key, required this.caption, this.maxLines});

  final String caption;

  /// Collapses a longer caption to this many lines behind a Show more
  /// toggle ([ExpandableText]); null shows it in full.
  final int? maxLines;

  @override
  ConsumerState<CaptionRichText> createState() => _CaptionRichTextState();
}

class _CaptionRichTextState extends ConsumerState<CaptionRichText> {
  /// One recognizer per distinct href, reused across rebuilds. TextSpan
  /// recognizers are not pooled — each must be disposed with the state.
  final Map<String, TapGestureRecognizer> _recognizers = {};

  @override
  void dispose() {
    for (final recognizer in _recognizers.values) {
      recognizer.dispose();
    }
    super.dispose();
  }

  void _openLink(String href) {
    final uri = Uri.tryParse(href);
    switch (uri == null ? null : _route(uri)) {
      case UserRoute(:final userId):
        // The facade pushes its own route with the right-in rhythm.
        openUser(context, userId);
      case IllustRoute(:final illustId):
        openIllust(context, illustId);
      case _ when uri?.scheme == 'pixiv' || uri?.scheme == 'parfait':
        // No page here for it; Android would only hand it back.
        break;
      case _:
        _openExternal(href);
    }
  }

  /// The deep-link allowlist refuses anything after a work or user id
  /// (`/artworks/1?p=2`, `/users/7/illustrations`). A caption link to such
  /// a page opened in the app before, so its kind and id alone are routed
  /// too, after an optional language segment.
  static DeepLinkRoute _route(Uri uri) {
    final route = IntentRouter.route(uri);
    if (route is! UnknownRoute ||
        !const {'http', 'https'}.contains(uri.scheme)) {
      return route;
    }
    // Raw segments: the router decodes them and refuses what is not UTF-8.
    final segments = uri.path.split('/').where((s) => s.isNotEmpty);
    final kept = segments.firstOrNull?.length == 2 ? 3 : 2;
    return IntentRouter.route(
      Uri(
        scheme: uri.scheme,
        host: uri.host,
        path: '/${segments.take(kept).join('/')}',
      ),
    );
  }

  void _openExternal(String href) {
    final opener = ref.read(outboundUrlOpenerProvider);
    unawaited(
      opener.openExternal(href).catchError((Object error) {
        if (mounted) {
          showErrorSnackBar(
            context,
            action: context.l10n.illustDetailOpenLinkFailed,
            error: error,
          );
        }
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bodyStyle = theme.textTheme.bodyMedium;
    // Links stay ordinary inline text: they wrap mid-token with the rest of
    // the caption and inherit the body style — a WidgetSpan renders as an
    // atomic box that can only break at its own edge and falls back to
    // DefaultTextStyle, which is what made link text look oversized.
    final linkStyle = bodyStyle?.copyWith(
      color: theme.colorScheme.primary,
      decoration: TextDecoration.underline,
      decorationColor: theme.colorScheme.primary,
    );
    final parsed = parseIllustCaption(widget.caption);

    final spans = <InlineSpan>[];
    for (final span in parsed.spans) {
      switch (span) {
        case CaptionText(:final text):
          spans.add(TextSpan(text: text));
        case CaptionBreak():
          spans.add(const TextSpan(text: '\n'));
        case CaptionLink(:final href, :final text):
          final recognizer = _recognizers.putIfAbsent(
            href,
            () => TapGestureRecognizer()..onTap = () => _openLink(href),
          );
          spans.add(
            TextSpan(
              text: text.isEmpty ? href : text,
              style: linkStyle,
              recognizer: recognizer,
            ),
          );
      }
    }

    final text = TextSpan(children: spans);
    final maxLines = widget.maxLines;
    if (maxLines == null) return Text.rich(text, style: bodyStyle);
    return ExpandableText(text, maxLines: maxLines, style: bodyStyle);
  }
}
