import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../motion/motion_tokens.dart';
import '../motion/state_fade.dart';
import '../pixiv_image.dart';
import 'app_snack_bar.dart';
import 'comment_text.dart';
import 'edge_icon_buttons.dart';
import '../../core/auth/account_store.dart';
import '../../core/comments/comment_actions.dart';
import '../../core/comments/comment_assets.dart';
import '../../core/settings/keyboard_heights.dart';
import '../../l10n/context.dart';
import '../theme/func_semantic_tokens.dart';

const double _panelCellSpacing = 8;

/// Says why a comment send failed.
void showCommentSendError(BuildContext context, Object error) {
  final key = error is CommentPermissionException
      ? 'commentPermissionDenied'
      : 'commentSendFailed';
  showAppSnackBar(context, commentText(context, key));
}

/// Unsent comment text by the work it was written for
/// (`CommentFeedQuery.workKey`): a composer closed before sending keeps
/// it for the next one on that work. Held for the session.
final commentDraftsProvider =
    NotifierProvider<CommentDrafts, Map<String, String>>(CommentDrafts.new);

class CommentDrafts extends Notifier<Map<String, String>> {
  @override
  Map<String, String> build() {
    ref.watch(accountStoreProvider.select((async) => async.value?.current?.id));
    return const {};
  }

  void keep(String workKey, String text) {
    if ((state[workKey] ?? '') == text) return;
    state = text.isEmpty
        ? ({...state}..remove(workKey))
        : {...state, workKey: text};
  }
}

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
    this.keyboardHeights,
    this.initialText = '',
    this.onChanged,
    this.onGone,
  });

  final Future<void> Function(String text) onSend;
  final Future<void> Function(int stampId) onStampSend;
  final String? replyTo;
  final VoidCallback? onCancelReply;
  final bool sending;
  final ValueChanged<Object>? onError;

  /// Where the keyboard's height is kept between composers and runs; the
  /// panels take it. Without one they take a default until the keyboard
  /// has shown in this composer.
  final KeyboardHeightMemory? keyboardHeights;

  /// The text the field starts with: a draft kept from an earlier visit.
  final String initialText;

  /// The field's text after each edit, and '' after a send.
  final ValueChanged<String>? onChanged;

  /// Set for a composer that lives only on its input surface (the detail
  /// page's): it stands on the keyboard or the panel as it rises and
  /// falls, shows over the upper half of that travel, and calls [onGone]
  /// once the surface it opened on has gone down. Without it the composer
  /// rests above the navigation bar when no surface is up.
  final VoidCallback? onGone;

  /// How long to wait for a keyboard that may not come (a hardware
  /// keyboard, a floating IME): longer than an IME takes to slide in.
  static const keyboardWait = Duration(milliseconds: 600);

  @override
  State<CommentComposer> createState() => CommentComposerState();
}

class CommentComposerState extends State<CommentComposer>
    with SingleTickerProviderStateMixin {
  /// Panel height, above the navigation bar, before any keyboard height is
  /// known — close to a typical soft keyboard's.
  static const _fallbackPanelHeight = 280.0;

  late final _controller = TextEditingController(text: widget.initialText);
  final _focusNode = FocusNode();
  CommentComposerInputState _inputState = CommentComposerInputState.none;

  /// The keyboard's height as last seen in this composer: the tallest
  /// inset of its last stretch of focus. Null before it has shown. Used
  /// only without a [CommentComposer.keyboardHeights] memory.
  double? _keyboardHeight;

  /// The tallest inset of the current stretch of focus.
  double _focusPeak = 0;

  /// A panel has opened: it stays built, offstage, so the next opening
  /// does not build its grid again.
  bool _panelBuilt = false;
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

  /// [CommentComposer.onGone] only: a surface has opened, so the composer
  /// can be gone; the tallest keyboard inset seen; the inset of the last
  /// build; no keyboard has risen for the keyboard leg (a hardware or
  /// floating one), so the composer rests above the navigation bar; the
  /// wait for that; and [CommentComposer.onGone] has been called.
  bool _opened = false;
  double _keyboardPeak = 0;
  double _lastInset = 0;
  bool _keyboardAbsent = false;
  Timer? _absentWait;
  bool _gone = false;

  bool get _onSurface => widget.onGone != null;

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
    // animateTo(0) ends as completed, not dismissed: the value says down.
    _panelReveal.addStatusListener((status) {
      if (!status.isAnimating && _panelReveal.value == 0) _goIfDown();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _warmEmojis());
  }

  /// Decodes the emoji images ahead of the panel, so its first opening
  /// does not wait on them. A failed image shows as such in the panel.
  void _warmEmojis() {
    if (!mounted) return;
    for (final name in commentEmojiNames) {
      unawaited(
        precacheImage(
          AssetImage(commentEmojiAsset(name)),
          context,
          onError: (_, _) {},
        ),
      );
    }
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
    if (_onSurface) _followKeyboard(MediaQuery.viewInsetsOf(context).bottom);
  }

  /// [CommentComposer.onGone] only: tracks the keyboard the composer
  /// stands on. One that went down under the focused field (system back,
  /// the IME's own key) takes the composer with it.
  void _followKeyboard(double inset) {
    final fell = _lastInset > 0 && inset == 0;
    _lastInset = inset;
    if (inset > _keyboardPeak) _keyboardPeak = inset;
    if (inset > 0) {
      _absentWait?.cancel();
      _keyboardAbsent = false;
    }
    if (!fell) return;
    // Not mid-build: leaving focus rebuilds the composer.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_inputState == CommentComposerInputState.keyboard) {
        _focusNode.unfocus();
      } else {
        _goIfDown();
      }
    });
  }

  /// [CommentComposer.onGone] only: closes the composer. The keyboard or
  /// panel goes down, taking the composer with it, and [onGone] follows.
  void dismiss() {
    _focusNode.unfocus();
    if (_inputState != CommentComposerInputState.none) {
      _enter(CommentComposerInputState.none);
    }
    _goIfDown();
  }

  /// Calls [CommentComposer.onGone] once nothing the composer stood on is
  /// up any more.
  void _goIfDown() {
    final onGone = widget.onGone;
    if (onGone == null || _gone || !_opened || !mounted) return;
    if (_inputState != CommentComposerInputState.none ||
        _panelReveal.value > 0 ||
        MediaQuery.viewInsetsOf(context).bottom > 0) {
      return;
    }
    _gone = true;
    onGone();
  }

  /// How much of the composer shows while it stands on a surface: none at
  /// the bottom, all from half the surface's height up.
  double _presence(double panelHeight) {
    if (_keyboardAbsent) return 1;
    final carrier = math.max(
      MediaQuery.viewInsetsOf(context).bottom,
      panelHeight * _panelReveal.value,
    );
    final full = math.max(_keyboardPeak, panelHeight);
    return (2 * carrier / full).clamp(0.0, 1.0);
  }

  @override
  void dispose() {
    _keyboardHold?.cancel();
    _absentWait?.cancel();
    _panelReveal.dispose();
    _focusNode.removeListener(_onFocusChange);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// The panels' height: the keyboard's, navigation bar included, so the
  /// input row stays put as one replaces the other. A memory, when given,
  /// is the one source: it knows the height per screen shape and drops
  /// the insets no docked keyboard has.
  double get _panelHeight {
    final memory = widget.keyboardHeights;
    final known = memory == null
        ? _keyboardHeight
        : memory.heightFor(MediaQuery.sizeOf(context));
    return known ??
        _fallbackPanelHeight + MediaQuery.viewPaddingOf(context).bottom;
  }

  /// Reply-pill entry point: converge to the keyboard leg — an open panel is
  /// replaced by the IME — and focus the field.
  void focusForReply() => _showKeyboard();

  /// Opens the composer on [surface]: the keyboard, or a panel with the
  /// keyboard down.
  void open(CommentComposerInputState surface) {
    if (surface == CommentComposerInputState.keyboard) {
      _showKeyboard();
      return;
    }
    _focusNode.unfocus();
    _enter(surface);
  }

  /// Ends a stretch of focus: its tallest inset is the keyboard's height.
  void _keepKeyboardHeight() {
    final peak = _focusPeak;
    _focusPeak = 0;
    if (peak == 0) return;
    final memory = widget.keyboardHeights;
    if (memory == null) {
      _keyboardHeight = peak;
    } else {
      memory.record(MediaQuery.sizeOf(context), peak);
    }
  }

  void _showKeyboard() {
    _enter(CommentComposerInputState.keyboard);
    _focusNode.requestFocus();
  }

  void _onFocusChange() {
    if (_focusNode.hasFocus) {
      if (_inputState != CommentComposerInputState.keyboard) {
        _enter(CommentComposerInputState.keyboard);
      }
      return;
    }
    _keepKeyboardHeight();
    if (_inputState == CommentComposerInputState.keyboard) {
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
    _absentWait?.cancel();
    if (next != CommentComposerInputState.none) _opened = true;
    if (_onSurface &&
        next == CommentComposerInputState.keyboard &&
        MediaQuery.viewInsetsOf(context).bottom == 0) {
      _absentWait = Timer(CommentComposer.keyboardWait, () {
        if (mounted && MediaQuery.viewInsetsOf(context).bottom == 0) {
          setState(() => _keyboardAbsent = true);
        }
      });
    }
    switch (next) {
      case CommentComposerInputState.emoji || CommentComposerInputState.stamp:
        // The keyboard is going down: what it showed sizes the panel.
        _keepKeyboardHeight();
        _panelBuilt = true;
        final under = _bottomInset(context) / _panelHeight;
        _panelReveal.value = math.max(_panelReveal.value, under);
        _animatePanel(1);
      case CommentComposerInputState.keyboard when _panelReveal.value > 0:
        _panelReveal.stop();
        _keyboardHold = Timer(
          CommentComposer.keyboardWait,
          () => _animatePanel(0),
        );
      case CommentComposerInputState.keyboard:
        break;
      case CommentComposerInputState.none:
        _animatePanel(0);
        WidgetsBinding.instance.addPostFrameCallback((_) => _goIfDown());
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
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    // Sample only while the field owns focus: some OEM IMEs fold the
    // nav-bar inset into viewInsets when nothing is focused.
    if (_focusNode.hasFocus && keyboard > _focusPeak) _focusPeak = keyboard;
    final bottomInset = _bottomInset(context);
    final panelHeight = _panelHeight;
    final composer = PopScope(
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
        // The bottom slot below takes the bottom inset itself.
        child: SafeArea(
          top: false,
          bottom: false,
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
                    // On the page's 16dp margin; the close glyph, not its
                    // target, ends on it (LAYOUT-15).
                    padding: const EdgeInsetsDirectional.fromSTEB(
                      FuncSpacing.lg,
                      FuncSpacing.sm,
                      FuncSpacing.lg - EdgeIconButtons.glyphInset,
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
                // The field starts on the page's 16dp margin and the send
                // glyph ends on it (LAYOUT-15).
                padding: const EdgeInsetsDirectional.fromSTEB(
                  FuncSpacing.lg,
                  FuncSpacing.sm,
                  FuncSpacing.lg - EdgeIconButtons.glyphInset,
                  FuncSpacing.sm,
                ),
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
                        onChanged: (text) {
                          setState(() {});
                          widget.onChanged?.call(text);
                        },
                        decoration: InputDecoration(
                          hintText: context.l10n.commentInput,
                          // Not dense: one line stands 48dp, as tall as the
                          // buttons beside it and the detail page's entry
                          // pill, its text centred on them.
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
              // The one bottom budget: this slot takes the keyboard, or
              // the navigation bar when no keyboard is up, or a panel at
              // the keyboard's height, navigation bar included, so the
              // input row stays put as they swap (the list above is only
              // compressed, never doubly padded — design 「避让责任唯一」).
              // A panel rises from the slot's bottom edge like the
              // keyboard: its top shows first.
              AnimatedBuilder(
                animation: _panelReveal,
                // Built per composer build, not per frame of the reveal.
                child: _panelBuilt
                    ? RepaintBoundary(
                        child: StateFade(
                          kind: _shownPanel,
                          child: _buildPanel(context),
                        ),
                      )
                    : null,
                builder: (context, panel) {
                  final reveal = _panelReveal.value;
                  return SizedBox(
                    height: math.max(bottomInset, panelHeight * reveal),
                    child: panel == null
                        ? null
                        : Offstage(
                            offstage: reveal == 0,
                            child: ClipRect(
                              child: OverflowBox(
                                alignment: Alignment.topCenter,
                                minHeight: panelHeight,
                                maxHeight: panelHeight,
                                child: panel,
                              ),
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
    return _fadeOnSurface(panelHeight, composer);
  }

  /// [CommentComposer.onGone] only: shows [composer] as far as it stands
  /// on a surface ([_presence]).
  Widget _fadeOnSurface(double panelHeight, Widget composer) {
    if (!_onSurface) return composer;
    return AnimatedBuilder(
      animation: _panelReveal,
      child: composer,
      builder: (context, child) =>
          Opacity(opacity: _presence(panelHeight), child: child),
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
        // The images, not their cells, line up with the 16dp margin; an
        // emoji sits 4dp inside its cell.
        final side = isEmoji
            ? FuncSpacing.lg - FuncSpacing.xxs
            : FuncSpacing.lg;
        final cellWidth =
            (constraints.maxWidth -
                2 * side -
                _panelCellSpacing * (crossAxisCount - 1)) /
            crossAxisCount;
        // One labelled button per cell — the images stay decorative-only.
        return Semantics(
          container: true,
          child: GridView.builder(
            // The last row clears the navigation bar the panel covers.
            padding: EdgeInsets.fromLTRB(
              side,
              FuncSpacing.sm,
              side,
              FuncSpacing.sm + MediaQuery.viewPaddingOf(context).bottom,
            ),
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
    // A programmatic edit fires no onChanged of the field's own.
    widget.onChanged?.call(text);
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
        widget.onChanged?.call('');
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

  /// What the slot holds with no panel up: the keyboard, or the
  /// navigation bar under the input row when none is up (a floating or
  /// hardware keyboard reports no inset). A composer on a surface stands
  /// on the keyboard alone, unless none has come.
  double _bottomInset(BuildContext context) {
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    if (_onSurface && !_keyboardAbsent) return keyboard;
    return math.max(keyboard, MediaQuery.viewPaddingOf(context).bottom);
  }
}
