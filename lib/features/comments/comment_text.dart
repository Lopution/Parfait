import 'package:flutter/material.dart';

import '../../core/comments/comment_assets.dart';
import '../../core/i18n/replica_strings.dart';

/// Renders beta56 `(emoji_name)` markers inline while leaving unknown markers
/// as ordinary text. Raw comment content remains the source of truth.
class CommentText extends StatelessWidget {
  const CommentText(this.text, {super.key, this.style, this.emojiScale = 1.3});

  final String text;
  final TextStyle? style;
  final double emojiScale;

  @override
  Widget build(BuildContext context) {
    final baseStyle = style ?? DefaultTextStyle.of(context).style;
    final fontSize = baseStyle.fontSize ?? 14;
    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final match in RegExp(r'\(([A-Za-z0-9_]+)\)').allMatches(text)) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, match.start)));
      }
      final name = match.group(1)!;
      if (commentEmojiNames.contains(name)) {
        final size = fontSize * emojiScale;
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: SizedBox(
              width: size,
              height: size,
              child: Image.asset(commentEmojiAsset(name), fit: BoxFit.contain),
            ),
          ),
        );
      } else {
        spans.add(TextSpan(text: match.group(0)));
      }
      cursor = match.end;
    }
    if (cursor < text.length) spans.add(TextSpan(text: text.substring(cursor)));
    if (spans.isEmpty) spans.add(TextSpan(text: text));
    return Text.rich(TextSpan(style: baseStyle, children: spans));
  }
}

String commentText(BuildContext context, String key) => ReplicaStrings.fromTag(
  Localizations.localeOf(context).toLanguageTag(),
  key,
);
