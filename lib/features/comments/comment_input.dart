import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../app/motion/motion_tokens.dart';
import '../../app/motion/state_fade.dart';
import '../../app/pixiv_image.dart';
import '../../core/comments/comment_assets.dart';
import '../../l10n/context.dart';
import '../../app/theme/func_semantic_tokens.dart';

const double _panelCellSpacing = 8;

/// The composer's input surface — four mutually exclusive states. [keyboard]
/// is mirrored one-way from the framework focus node; [emoji] and [stamp] are
/// the picker panels; [none] is the resting surface. This enum is the single
/// source of truth for which surface is visible.
enum CommentComposerInputState { none, keyboard, emoji, stamp }

/// Beta56-compatible comment composer: text, an emoji picker and a stamp
/// picker. A reply context is explicit and can be cancelled.
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
  State<CommentComposer> createState() => CommentComposerState();
}

class CommentComposerState extends State<CommentComposer>
    with SingleTickerProviderStateMixin {
  /// Panel height before any real keyboard height is sampled — close to a
  /// typical soft-keyboard height.
  static const _fallbackPanelHeight = 280.0;

  /// How long a panel holds its height for a keyboard that may not come (a
  /// hardware keyboard, a floating IME): longer than an IME slides in.
  static const _keyboardHoldTimeout = Duration(milliseconds: 600);

  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  CommentComposerInputState _inputState = CommentComposerInputState.none;
  double _cachedKeyboardHeight = 0;
  bool _busy = false;

  /// How much of the panel height the bottom slot shows: 0 none, 1 all.
  late final AnimationController _panelReveal = AnimationController(
    vsync: this,
  );

  /// The panel the slot draws; kept through the collapse after the state
  /// has left it.
  CommentComposerInputState _shownPanel = CommentComposerInputState.emoji;

  /// Runs while a panel waits for the keyboard to cover it.
  Timer? _keyboardHold;

  bool get _disabled => widget.sending || _busy;

  bool get _panelVisible =>
      _inputState == CommentComposerInputState.emoji ||
      _inputState == CommentComposerInputState.stamp;

  /// Current input-surface state; exposed for the state-matrix tests.
  @visibleForTesting
  CommentComposerInputState get debugInputState => _inputState;

  @override
  void initState() {
    super.initState();
    // The focus node is the framework's authority for the keyboard leg; this
    // listener only mirrors it into the enum — a one-way convergence, never
    // a second judgement. Gaining focus collapses any open panel into
    // keyboard; losing it without a panel rests at none.
    _focusNode.addListener(_onFocusChange);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The keyboard has risen over the held panel: nothing of it shows any
    // more, so it goes at once.
    final hold = _keyboardHold;
    if (hold != null &&
        hold.isActive &&
        MediaQuery.viewInsetsOf(context).bottom >=
            _panelHeight * _panelReveal.value) {
      hold.cancel();
      _panelReveal.value = 0;
    }
  }

  @override
  void dispose() {
    _keyboardHold?.cancel();
    _panelReveal.dispose();
    _focusNode.removeListener(_onFocusChange);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  double get _panelHeight =>
      math.max(_cachedKeyboardHeight, _fallbackPanelHeight);

  /// Reply-pill entry point: converge to the keyboard leg — an open panel is
  /// replaced by the IME — and focus the field.
  void focusForReply() => _showKeyboard();

  void _showKeyboard() {
    _enter(CommentComposerInputState.keyboard);
    _focusNode.requestFocus();
  }

  void _onFocusChange() {
    if (_focusNode.hasFocus) {
      if (_inputState != CommentComposerInputState.keyboard) {
        _enter(CommentComposerInputState.keyboard);
      }
    } else if (_inputState == CommentComposerInputState.keyboard) {
      _enter(CommentComposerInputState.none);
    }
  }

  /// Moves to [next] and plays the panel's part of it. A panel opens from
  /// whatever height is already there (the keyboard's, when it replaces
  /// the keyboard) and closes on the sheet spring. A panel giving way to
  /// the keyboard holds still until the keyboard has risen over it, so the
  /// input row never drops and climbs back.
  void _enter(CommentComposerInputState next) {
    setState(() {
      _inputState = next;
      if (_panelVisible) _shownPanel = next;
    });
    _keyboardHold?.cancel();
    switch (next) {
      case CommentComposerInputState.emoji || CommentComposerInputState.stamp:
        final under = MediaQuery.viewInsetsOf(context).bottom / _panelHeight;
        _panelReveal.value = math.max(_panelReveal.value, under);
        _animatePanel(1);
      case CommentComposerInputState.keyboard when _panelReveal.value > 0:
        _panelReveal.stop();
        _keyboardHold = Timer(_keyboardHoldTimeout, () => _animatePanel(0));
      case CommentComposerInputState.keyboard:
        break;
      case CommentComposerInputState.none:
        _animatePanel(0);
    }
  }

  void _animatePanel(double target) {
    final (duration, curve) = MotionTokens.springCurve(
      context,
      MotionSpring.spatialDefault,
    );
    if (duration == Duration.zero) {
      _panelReveal.value = target;
    } else {
      _panelReveal.animateTo(target, duration: duration, curve: curve);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The viewInsets read is scoped to this subtree so per-frame IME
    // animation rebuilds stay inside the composer (search_page precedent).
    final viewInsetsBottom = MediaQuery.viewInsetsOf(context).bottom;
    // Sample the peak only while the field owns focus: some OEM IMEs fold
    // the nav-bar inset into viewInsets when nothing is focused, which
    // would poison the cache.
    if (_focusNode.hasFocus && viewInsetsBottom > _cachedKeyboardHeight) {
      _cachedKeyboardHeight = viewInsetsBottom;
    }
    final panelHeight = _panelHeight;
    return PopScope(
      // An open picker panel is a transient layer on this route: system back
      // collapses it instead of leaving (§5.4). The keyboard leg is never
      // vetoed — the IME/system consumes that back first.
      canPop: !_panelVisible,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || !mounted) return;
        _enter(CommentComposerInputState.none);
      },
      child: Material(
        color: theme.colorScheme.surface,
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.replyTo != null)
                Semantics(
                  // The reply context is one announcement unit — screen
                  // readers read "Reply to <name>" + the close affordance
                  // as a single block.
                  container: true,
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(
                      FuncSpacing.lg,
                      FuncSpacing.sm,
                      FuncSpacing.sm,
                      0,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            context.l10n.labelValue(
                              context.l10n.commentReplyTo,
                              widget.replyTo!,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                        IconButton(
                          tooltip: context.l10n.commentCancelReply,
                          onPressed: _disabled ? null : widget.onCancelReply,
                          icon: const Icon(Icons.close, size: 18),
                        ),
                      ],
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(FuncSpacing.sm),
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
                          hintText: context.l10n.commentInput,
                          isDense: true,
                          filled: true,
                          fillColor: theme.colorScheme.surfaceContainer,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: FuncSpacing.md,
                            vertical: FuncSpacing.sm,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: FuncShape.pill,
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: context.l10n.commentEmoji,
                      onPressed: _disabled
                          ? null
                          : () => _togglePanel(CommentComposerInputState.emoji),
                      icon: Icon(
                        Icons.emoji_emotions_outlined,
                        color: _inputState == CommentComposerInputState.emoji
                            ? theme.colorScheme.primary
                            : null,
                      ),
                    ),
                    if (_controller.text.trim().isEmpty)
                      IconButton(
                        tooltip: context.l10n.commentStamps,
                        onPressed: _disabled
                            ? null
                            : () =>
                                  _togglePanel(CommentComposerInputState.stamp),
                        icon: Icon(
                          Icons.image_outlined,
                          color: _inputState == CommentComposerInputState.stamp
                              ? theme.colorScheme.primary
                              : null,
                        ),
                      ),
                    IconButton(
                      tooltip: context.l10n.commentSend,
                      onPressed: _disabled || _controller.text.trim().isEmpty
                          ? null
                          : _sendText,
                      // While a send is in flight the affordance becomes a
                      // progress indicator — visible feedback for the
                      // non-optimistic wait (R6). `_busy` covers the gap
                      // where the store mutation key reports early false.
                      icon: _disabled
                          ? Semantics(
                              label: context.l10n.commentSending,
                              child: const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            )
                          : const Icon(Icons.send_outlined),
                    ),
                  ],
                ),
              ),
              // The bottom extent slot does all avoidance in layout: the
              // IME rides over a plain spacer, and a panel swaps into the
              // same slot at keyboard height so IME ↔ panel switches do
              // not jump (the feed list is only compressed, never doubly
              // padded — design 「避让责任唯一」). A panel rises from the
              // slot's bottom edge like the keyboard: its top shows first.
              AnimatedBuilder(
                animation: _panelReveal,
                // Built per composer build, not per frame of the reveal.
                child: StateFade(
                  kind: _shownPanel,
                  child: _buildPanel(context),
                ),
                builder: (context, panel) {
                  final reveal = _panelReveal.value;
                  return SizedBox(
                    height: math.max(viewInsetsBottom, panelHeight * reveal),
                    child: reveal == 0
                        ? null
                        : ClipRect(
                            child: OverflowBox(
                              alignment: Alignment.topCenter,
                              minHeight: panelHeight,
                              maxHeight: panelHeight,
                              child: panel,
                            ),
                          ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPanel(BuildContext context) {
    final isEmoji = _shownPanel == CommentComposerInputState.emoji;
    return LayoutBuilder(
      builder: (context, constraints) {
        // Width-driven columns: emoji cells keep a ~48dp touch target,
        // stamps ~96dp — clamped so narrow panes never shrink below a
        // usable grid and wide panes cap at the densest useful count.
        final crossAxisCount = isEmoji
            ? (constraints.maxWidth / 48).floor().clamp(3, 10).toInt()
            : (constraints.maxWidth / 96).floor().clamp(2, 5).toInt();
        final cellWidth =
            (constraints.maxWidth -
                2 * FuncSpacing.sm -
                _panelCellSpacing * (crossAxisCount - 1)) /
            crossAxisCount;
        // One labelled button per cell — the images stay decorative-only.
        return Semantics(
          container: true,
          child: GridView.builder(
            padding: const EdgeInsets.all(FuncSpacing.sm),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: crossAxisCount,
              crossAxisSpacing: _panelCellSpacing,
              mainAxisSpacing: _panelCellSpacing,
            ),
            itemCount: isEmoji
                ? commentEmojiNames.length
                : commentStampIds.length,
            itemBuilder: (context, index) {
              if (isEmoji) {
                final name = commentEmojiNames[index];
                return Semantics(
                  button: true,
                  label: name,
                  child: InkResponse(
                    onTap: () => _insertEmoji(name),
                    child: Padding(
                      padding: const EdgeInsets.all(FuncSpacing.xxs),
                      child: ExcludeSemantics(
                        child: Image.asset(commentEmojiAsset(name)),
                      ),
                    ),
                  ),
                );
              }
              final id = commentStampIds[index];
              return Semantics(
                button: true,
                label: context.l10n.commentStampLabel(id),
                child: InkResponse(
                  onTap: () => _sendStamp(id),
                  child: ExcludeSemantics(
                    child: PixivImage.feed(
                      commentStampUrl(id),
                      layoutWidth: cellWidth,
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  void _togglePanel(CommentComposerInputState panel) {
    if (_inputState == panel) {
      // Toggling the active panel's button rests the surface.
      _enter(CommentComposerInputState.none);
      return;
    }
    // Entering a panel releases the IME. The focus listener cannot race this:
    // the focus change reaches it after the panel state has landed, and in
    // a panel state it is a no-op.
    _focusNode.unfocus();
    _enter(panel);
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
    // Decision D2: inserting restores the keyboard leg — the panel closes and
    // the field regains focus so typing continues without a second tap.
    _showKeyboard();
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
      if (mounted) _enter(CommentComposerInputState.none);
    } on Object catch (error) {
      widget.onError?.call(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
