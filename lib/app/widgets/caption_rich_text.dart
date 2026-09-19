import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../navigation/routes.dart';
import 'app_snack_bar.dart';
import '../../core/entity/illust_caption.dart';
import '../../core/platform/android_intent_channel.dart';
import '../../l10n/context.dart';

/// Renders a parsed HTML caption with clickable links (U6).
///
/// pixiv-internal links (www.pixiv.net users/artworks) navigate inside the
/// app with the same right-in rhythm as feed cards; anything else opens via
/// the outbound Android intent.
class CaptionRichText extends ConsumerStatefulWidget {
  const CaptionRichText({super.key, required this.caption});

  final String caption;

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

  void _openLink(String href, ({String kind, String id})? target) {
    if (target != null) {
      _openPixivRoute(context, target);
      return;
    }
    final opener = ref.read(outboundUrlOpenerProvider);
    unawaited(
      opener.openExternal(href).catchError((Object error) {
        if (mounted) {
          showAppSnackBar(
            context,
            context.l10n.illustDetailOpenLinkFailed(error.toString()),
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
            () =>
                TapGestureRecognizer()
                  ..onTap = () => _openLink(href, _resolvePixivRoute(href)),
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

    return Text.rich(TextSpan(children: spans), style: bodyStyle);
  }
}

/// Resolves a pixiv web URL to an internal route, or null for external.
({String kind, String id})? _resolvePixivRoute(String href) {
  final uri = Uri.tryParse(href);
  if (uri == null) return null;
  final host = uri.host.toLowerCase();
  if (host != 'www.pixiv.net' && host != 'pixiv.net') return null;
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segments.isEmpty) return null;
  // Strip a leading language segment (en/, ja/, ...).
  final start =
      segments.length >= 2 &&
          segments[0].length == 2 &&
          !RegExp(r'^\d+$').hasMatch(segments[0])
      ? 1
      : 0;
  if (segments.length <= start) return null;
  return switch (segments[start]) {
    'users' when segments.length > start + 1 => (
      kind: 'user',
      id: segments[start + 1],
    ),
    'artworks' || 'illusts' when segments.length > start + 1 => (
      kind: 'illust',
      id: segments[start + 1],
    ),
    _ => null,
  };
}

void _openPixivRoute(BuildContext context, ({String kind, String id}) target) {
  final id = int.tryParse(target.id);
  if (id == null || id <= 0) return;
  switch (target.kind) {
    case 'user':
      // The facade pushes its own route with the right-in rhythm.
      openUser(context, id);
    case 'illust':
      openIllust(context, id);
  }
}
