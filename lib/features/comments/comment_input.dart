import 'package:flutter/material.dart';

import '../../core/comments/comment_assets.dart';
import 'comment_text.dart';

enum CommentComposerPanel { emoji, stamps }

/// Beta56-compatible comment composer: text, a 10-column emoji picker and a
/// 5-column stamp picker. A reply context is explicit and can be cancelled.
class CommentComposer extends StatefulWidget {
  const CommentComposer({
    super.key,
    required this.onSend,
    required this.onStampSend,
    this.replyTo,
    this.onCancelReply,
    this.sending = false,
    this.onError,
  });

  final Future<void> Function(String text) onSend;
  final Future<void> Function(int stampId) onStampSend;
  final String? replyTo;
  final VoidCallback? onCancelReply;
  final bool sending;
  final ValueChanged<Object>? onError;

  @override
  State<CommentComposer> createState() => _CommentComposerState();
}

class _CommentComposerState extends State<CommentComposer> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  CommentComposerPanel? _panel;
  bool _busy = false;

  bool get _disabled => widget.sending || _busy;

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.replyTo != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${commentText(context, 'commentReplyTo')}: ${widget.replyTo}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    IconButton(
                      tooltip: commentText(context, 'commentCancelReply'),
                      onPressed: _disabled ? null : widget.onCancelReply,
                      icon: const Icon(Icons.close, size: 18),
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      focusNode: _focusNode,
                      minLines: 1,
                      maxLines: 5,
                      enabled: !_disabled,
                      textInputAction: TextInputAction.newline,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        hintText: commentText(context, 'commentInput'),
                        isDense: true,
                        filled: true,
                        fillColor: theme.colorScheme.surfaceContainerHighest,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: commentText(context, 'commentEmoji'),
                    onPressed: _disabled
                        ? null
                        : () => _togglePanel(CommentComposerPanel.emoji),
                    icon: Icon(
                      Icons.emoji_emotions_outlined,
                      color: _panel == CommentComposerPanel.emoji
                          ? theme.colorScheme.primary
                          : null,
                    ),
                  ),
                  if (_controller.text.trim().isEmpty)
                    IconButton(
                      tooltip: commentText(context, 'commentStamps'),
                      onPressed: _disabled
                          ? null
                          : () => _togglePanel(CommentComposerPanel.stamps),
                      icon: Icon(
                        Icons.image_outlined,
                        color: _panel == CommentComposerPanel.stamps
                            ? theme.colorScheme.primary
                            : null,
                      ),
                    ),
                  IconButton(
                    tooltip: commentText(context, 'commentSend'),
                    onPressed: _disabled || _controller.text.trim().isEmpty
                        ? null
                        : _sendText,
                    icon: const Icon(Icons.send_outlined),
                  ),
                ],
              ),
            ),
            if (_panel != null) _buildPanel(context),
          ],
        ),
      ),
    );
  }

  Widget _buildPanel(BuildContext context) {
    final isEmoji = _panel == CommentComposerPanel.emoji;
    return SizedBox(
      height: isEmoji ? 210 : 250,
      child: GridView.builder(
        padding: const EdgeInsets.all(8),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: isEmoji ? 10 : 5,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
        ),
        itemCount: isEmoji ? commentEmojiNames.length : commentStampIds.length,
        itemBuilder: (context, index) {
          if (isEmoji) {
            final name = commentEmojiNames[index];
            return InkResponse(
              onTap: () => _insertEmoji(name),
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Image.asset(commentEmojiAsset(name)),
              ),
            );
          }
          final id = commentStampIds[index];
          return InkResponse(
            onTap: () => _sendStamp(id),
            child: Image.asset(commentStampAsset(id)),
          );
        },
      ),
    );
  }

  void _togglePanel(CommentComposerPanel panel) {
    _focusNode.unfocus();
    setState(() => _panel = _panel == panel ? null : panel);
  }

  void _insertEmoji(String name) {
    final value = _controller.value;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    final start = selection.start;
    final end = selection.end;
    final token = '($name)';
    final text = value.text.replaceRange(start, end, token);
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: start + token.length),
    );
    setState(() => _panel = null);
  }

  Future<void> _sendText() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _disabled) return;
    setState(() => _busy = true);
    try {
      await widget.onSend(text);
      if (mounted) {
        _controller.clear();
        setState(() {});
      }
    } on Object catch (error) {
      widget.onError?.call(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendStamp(int id) async {
    if (_disabled) return;
    setState(() => _busy = true);
    try {
      await widget.onStampSend(id);
      if (mounted) setState(() => _panel = null);
    } on Object catch (error) {
      widget.onError?.call(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
