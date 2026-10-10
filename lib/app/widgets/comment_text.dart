import 'package:material_ui/material_ui.dart';

import '../../core/comments/comment_assets.dart';
import '../../core/user/user_entity.dart';
import '../../l10n/context.dart';
import '../../l10n/lookup.dart';

/// Returns the localized display name used by comment rows, previews and
/// reply targets.
/// Deleted authors can remain in the API response without a usable profile id.
String commentAuthorDisplayName(BuildContext context, UserEntity user) {
  final name = user.name.trim();
  return name.isEmpty ? context.l10n.commentDeletedUser : name;
}

/// Renders beta56 `(emoji_name)` markers inline while leaving unknown markers
/// as ordinary text. Raw comment content remains the source of truth.
class CommentText extends StatelessWidget {
  const CommentText(
    this.text, {
    super.key,
    this.style,
    this.emojiScale = 1.3,
    this.maxLines,
  });

  final String text;
  final TextStyle? style;
  final double emojiScale;

  /// Null shows the whole comment; a preview caps it with an ellipsis.
  final int? maxLines;

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
    return Text.rich(
      TextSpan(style: baseStyle, children: spans),
      maxLines: maxLines,
      overflow: maxLines == null ? null : TextOverflow.ellipsis,
    );
  }
}

String commentText(BuildContext context, String key) =>
    l10nLookup(context.l10n, key);
