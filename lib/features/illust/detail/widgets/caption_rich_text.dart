import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/navigation/routes.dart';
import '../../../../app/widgets/app_snack_bar.dart';
import '../../../../core/entity/illust_caption.dart';
import '../../../../core/platform/android_intent_channel.dart';
import '../../../../l10n/context.dart';

/// Renders a parsed HTML caption with clickable links (U6).
///
/// pixiv-internal links (www.pixiv.net users/artworks) navigate inside the
/// app with the same right-in rhythm as feed cards; anything else opens via
/// the outbound Android intent.
class CaptionRichText extends ConsumerWidget {
  const CaptionRichText({super.key, required this.caption});

  final String caption;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final linkColor = theme.colorScheme.primary;
    final parsed = parseIllustCaption(caption);

    final spans = <InlineSpan>[];
    for (final span in parsed.spans) {
      switch (span) {
        case CaptionText(:final text):
          spans.add(TextSpan(text: text));
        case CaptionBreak():
          spans.add(const TextSpan(text: '\n'));
        case CaptionLink(:final href, :final text):
          final target = _resolvePixivRoute(href);
          spans.add(
            WidgetSpan(
              alignment: PlaceholderAlignment.top,
              child: GestureDetector(
                onTap: () {
                  if (target != null) {
                    _openPixivRoute(context, target);
                    return;
                  }
                  final opener = ref.read(outboundUrlOpenerProvider);
                  unawaited(
                    opener.openExternal(href).catchError((Object error) {
                      if (context.mounted) {
                        showAppSnackBar(
                          context,
                          context.l10n.illustDetailOpenLinkFailed(
                            error.toString(),
                          ),
                        );
                      }
                    }),
                  );
                },
                child: Text(
                  text.isEmpty ? href : text,
                  style: TextStyle(
                    color: linkColor,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
            ),
          );
      }
    }

    return Text.rich(
      TextSpan(children: spans),
      style: theme.textTheme.bodyMedium,
    );
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
