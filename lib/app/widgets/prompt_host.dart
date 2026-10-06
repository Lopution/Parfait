import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/logging/crash_log.dart';
import '../../core/platform/accessibility.dart';
import '../motion/motion_tokens.dart';
import '../theme/func_semantic_tokens.dart';
import 'prompt_anchor.dart';

/// Dwell time of a prompt without an explicit duration (Material's
/// SnackBar default), before the system's accessibility scaling.
const defaultPromptDuration = Duration(seconds: 4);

/// The single button a prompt may carry.
@immutable
class PromptAction {
  const PromptAction({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;
}

/// The app's one surface for transient messages, installed once in
/// `MaterialApp.builder` above every navigator.
///
/// One host instead of a messenger per branch: a prompt outlives the page
/// that raised it (a Snackbar belongs to the Activity on Android), rests
/// above the bottom chrome actually on screen ([PromptAnchor]), and makes
/// room for the keyboard. Dwell time follows the system's "time to take
/// action" setting; an action pins the prompt only while TalkBack explores
/// by touch — the MDC rules. Callers go through `showAppSnackBar`.
class PromptHost extends StatefulWidget {
  const PromptHost({
    super.key,
    required this.accessibility,
    required this.child,
  });

  /// Source of the system's recommended dwell time.
  final AppAccessibility accessibility;

  final Widget child;

  /// The prompt on screen, for tests to find it.
  @visibleForTesting
  static const promptKey = ValueKey<String>('PromptHost.prompt');

  /// The host above [context]. Throws when there is none: a prompt that
  /// silently goes nowhere hides a broken tree.
  static PromptHostState of(BuildContext context) {
    final host = maybeOf(context);
    if (host == null) {
      throw FlutterError.fromParts([
        ErrorSummary('PromptHost.of() called without a PromptHost above.'),
        ErrorDescription(
          'The app installs one in MaterialApp.builder; a test that shows '
          'prompts must install one too.',
        ),
        context.describeElement('The context used was'),
      ]);
    }
    return host;
  }

  static PromptHostState? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_PromptHostScope>()?.host;

  @override
  State<PromptHost> createState() => PromptHostState();
}

class PromptHostState extends State<PromptHost>
    with SingleTickerProviderStateMixin {
  final _anchors = PromptAnchors();
  final _cover = _ModalCover();
  final _queue = Queue<_Prompt>();
  late final AnimationController _presence = AnimationController(vsync: this)
    ..addStatusListener(_onPresenceStatus);
  late final Animation<double> _scale = _presence.drive(
    Tween<double>(
      begin: MotionTokens.promptEnterScale,
      end: 1,
    ).chain(CurveTween(curve: MotionTokens.promptScaleCurve)),
  );
  _Prompt? _current;
  Timer? _dwell;
  bool _touchExploration = false;

  /// Shows [message] for [duration], scaled by the system's accessibility
  /// timeout. By default it replaces whatever is showing and drops queued
  /// prompts; [replaceCurrent] false queues it behind them instead, for
  /// messages that report ordered steps.
  void show(
    String message, {
    Duration duration = defaultPromptDuration,
    PromptAction? action,
    bool replaceCurrent = true,
  }) {
    final prompt = _Prompt(
      message: message,
      duration: duration,
      action: action,
      // A TalkBack user needs time to reach the button; everyone else gets
      // a prompt that times out, action or not.
      persist: action != null && _touchExploration,
    );
    if (replaceCurrent) _queue.clear();
    _queue.add(prompt);
    final current = _current;
    if (current == null) {
      _showNext();
    } else if (replaceCurrent) {
      _hide(current);
    }
  }

  /// Hides the prompt on screen; the next queued one follows.
  void hideCurrent() {
    final current = _current;
    if (current != null) _hide(current);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Below TouchExplorationScope this is TalkBack, not any service.
    _touchExploration = MediaQuery.accessibleNavigationOf(context);
    // TalkBack gets no flight, like Material's SnackBar.
    Duration resolve(Duration base) =>
        _touchExploration ? Duration.zero : MotionTokens.resolve(context, base);
    _presence
      ..duration = resolve(MotionTokens.promptEnter)
      ..reverseDuration = resolve(MotionTokens.fast);
  }

  @override
  void dispose() {
    _dwell?.cancel();
    _presence.dispose();
    _anchors.dispose();
    _cover.dispose();
    super.dispose();
  }

  void _showNext() {
    _dwell?.cancel();
    _dwell = null;
    final next = _queue.isEmpty ? null : _queue.removeFirst();
    setState(() => _current = next);
    if (next == null) return;
    unawaited(_resolveTimeout(next));
    _presence.forward(from: 0);
  }

  void _hide(_Prompt prompt) {
    if (!identical(prompt, _current) || prompt.hiding) return;
    prompt.hiding = true;
    _dwell?.cancel();
    _dwell = null;
    if (_presence.isDismissed) {
      _showNext();
    } else {
      _presence.reverse();
    }
  }

  void _onPresenceStatus(AnimationStatus status) {
    final current = _current;
    if (current == null) return;
    if (status.isCompleted && !current.hiding) {
      _startDwell(current);
    } else if (status.isDismissed && current.hiding) {
      _showNext();
    }
  }

  /// The dwell starts once the prompt is fully in, like Material's.
  void _startDwell(_Prompt prompt) {
    if (prompt.persist) return;
    _dwell?.cancel();
    _dwell = Timer(prompt.duration, () {
      // The system may ask for longer than the base duration; the extra
      // time runs on after the base elapses, so a late reply still counts.
      final extra = (prompt.timeout ?? prompt.duration) - prompt.duration;
      if (extra > Duration.zero) {
        _dwell = Timer(extra, () => _hide(prompt));
      } else {
        _hide(prompt);
      }
    });
  }

  Future<void> _resolveTimeout(_Prompt prompt) async {
    final flags =
        AppAccessibility.contentText |
        (prompt.action == null ? 0 : AppAccessibility.contentControls);
    try {
      final ms = await widget.accessibility.recommendedTimeoutMillis(
        prompt.duration.inMilliseconds,
        flags,
      );
      prompt.timeout = Duration(milliseconds: ms);
    } on Object catch (error, stack) {
      // The base duration still applies; the failure stays visible in the
      // crash log.
      CrashLog.record(error, stack);
    }
  }

  void _runAction(_Prompt prompt) {
    if (prompt.actionTriggered) return;
    setState(() => prompt.actionTriggered = true);
    prompt.action!.onPressed();
    _hide(prompt);
  }

  /// The Dismissible already flew the card out: drop it without an exit.
  void _onSwiped(_Prompt prompt) {
    if (!identical(prompt, _current)) return;
    prompt.hiding = true;
    _presence.value = 0;
  }

  @override
  Widget build(BuildContext context) {
    final prompt = _current;
    return _PromptHostScope(
      host: this,
      child: PromptAnchorScope(
        anchors: _anchors,
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            widget.child,
            if (prompt != null)
              Positioned.fill(
                // The Builder keeps the inset dependencies off the host:
                // only the visible prompt relayouts with the keyboard.
                child: Builder(
                  builder: (context) => CustomSingleChildLayout(
                    delegate: _PromptLayout(
                      anchors: _anchors,
                      padding: MediaQuery.paddingOf(context),
                      viewInsets: MediaQuery.viewInsetsOf(context),
                    ),
                    child: _CoveredByModals(
                      cover: _cover,
                      child: FadeTransition(
                        opacity: _presence,
                        child: ScaleTransition(
                          scale: _scale,
                          child: _PromptCard(
                            prompt: prompt,
                            onAction: () => _runAction(prompt),
                            onDismiss: () => _hide(prompt),
                            onSwiped: () => _onSwiped(prompt),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Prompt {
  _Prompt({
    required this.message,
    required this.duration,
    required this.action,
    required this.persist,
  });

  final String message;
  final Duration duration;
  final PromptAction? action;
  final bool persist;

  /// The system's recommended dwell, once the platform answers.
  Duration? timeout;
  bool hiding = false;
  bool actionTriggered = false;
}

class _PromptHostScope extends InheritedWidget {
  const _PromptHostScope({required this.host, required super.child});

  final PromptHostState host;

  @override
  bool updateShouldNotify(_PromptHostScope oldWidget) =>
      !identical(host, oldWidget.host);
}

/// Bottom-anchored placement: centered, at most [_maxWidth] wide, resting
/// [_margin] above the tallest of the anchored chrome, the safe area and
/// the keyboard.
class _PromptLayout extends SingleChildLayoutDelegate {
  _PromptLayout({
    required this.anchors,
    required this.padding,
    required this.viewInsets,
  }) : super(relayout: anchors);

  /// Compose M3's snackbar container width cap.
  static const _maxWidth = 600.0;
  static const _margin = FuncSpacing.lg;

  final PromptAnchors anchors;
  final EdgeInsets padding;
  final EdgeInsets viewInsets;

  double get _bottom =>
      math.max(anchors.extent, math.max(padding.bottom, viewInsets.bottom)) +
      _margin;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final width = math.min(
      _maxWidth,
      constraints.maxWidth - padding.horizontal - 2 * _margin,
    );
    return BoxConstraints.tightFor(width: math.max(0, width)).copyWith(
      minHeight: 0,
      maxHeight: math.max(
        0,
        constraints.maxHeight - _bottom - padding.top - _margin,
      ),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final room = size.width - padding.horizontal;
    return Offset(
      padding.left + (room - childSize.width) / 2,
      size.height - _bottom - childSize.height,
    );
  }

  @override
  bool shouldRelayout(_PromptLayout oldDelegate) =>
      !identical(anchors, oldDelegate.anchors) ||
      padding != oldDelegate.padding ||
      viewInsets != oldDelegate.viewInsets;
}

/// The Material 3 floating snackbar card, themed by `SnackBarThemeData`;
/// the fallbacks are the app theme's own values.
class _PromptCard extends StatelessWidget {
  const _PromptCard({
    required this.prompt,
    required this.onAction,
    required this.onDismiss,
    required this.onSwiped,
  });

  /// Material's single-line vertical padding.
  static const _verticalPadding = 14.0;
  static const _horizontalPadding = FuncSpacing.lg;
  static const _actionMargin = FuncSpacing.sm;

  /// Material's `actionOverflowThreshold`: an action wider than this share
  /// of the card moves to its own row.
  static const _actionOverflowThreshold = 0.25;

  final _Prompt prompt;
  final VoidCallback onAction;
  final VoidCallback onDismiss;
  final VoidCallback onSwiped;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final snackBarTheme = theme.snackBarTheme;
    final action = prompt.action;
    final actionColor = snackBarTheme.actionTextColor ?? colors.inversePrimary;
    final message = Padding(
      padding: const EdgeInsets.symmetric(vertical: _verticalPadding),
      child: DefaultTextStyle(
        style:
            snackBarTheme.contentTextStyle ??
            theme.textTheme.bodyMedium!.copyWith(
              color: colors.onInverseSurface,
            ),
        child: Text(prompt.message),
      ),
    );
    final button = action == null
        ? null
        : Padding(
            padding: const EdgeInsets.symmetric(horizontal: _actionMargin),
            child: TextButton(
              style: TextButton.styleFrom(
                foregroundColor: actionColor,
                disabledForegroundColor: actionColor,
                overlayColor: actionColor,
                padding: const EdgeInsets.symmetric(
                  horizontal: _horizontalPadding,
                ),
              ),
              onPressed: prompt.actionTriggered ? null : onAction,
              child: Text(action.label),
            ),
          );
    return Semantics(
      key: PromptHost.promptKey,
      container: true,
      liveRegion: true,
      onDismiss: onDismiss,
      child: Dismissible(
        key: ObjectKey(prompt),
        direction: DismissDirection.down,
        resizeDuration: null,
        behavior: HitTestBehavior.deferToChild,
        onDismissed: (_) => onSwiped(),
        child: Material(
          color: snackBarTheme.backgroundColor ?? colors.inverseSurface,
          elevation: snackBarTheme.elevation ?? 0,
          shape:
              snackBarTheme.shape ??
              const RoundedRectangleBorder(borderRadius: FuncShape.card),
          child: Padding(
            padding: EdgeInsetsDirectional.only(
              start: _horizontalPadding,
              end: button == null ? _horizontalPadding : 0,
            ),
            child: button == null
                ? message
                : LayoutBuilder(
                    builder: (context, constraints) =>
                        _actionOverflows(context, constraints.maxWidth)
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Padding(
                                padding: const EdgeInsetsDirectional.only(
                                  end: _horizontalPadding,
                                ),
                                child: message,
                              ),
                              Padding(
                                padding: const EdgeInsets.only(
                                  bottom: _actionMargin,
                                ),
                                child: Align(
                                  alignment: AlignmentDirectional.centerEnd,
                                  child: button,
                                ),
                              ),
                            ],
                          )
                        : Row(
                            children: [
                              Expanded(child: message),
                              button,
                            ],
                          ),
                  ),
          ),
        ),
      ),
    );
  }

  bool _actionOverflows(BuildContext context, double width) {
    final painter = TextPainter(
      text: TextSpan(
        text: prompt.action!.label,
        style: Theme.of(context).textTheme.labelLarge,
      ),
      textScaler: MediaQuery.textScalerOf(context),
      textDirection: Directionality.of(context),
      maxLines: 1,
    )..layout();
    final actionWidth = painter.width + 2 * _horizontalPadding + _actionMargin;
    painter.dispose();
    return actionWidth / width > _actionOverflowThreshold;
  }
}

/// How visible prompts may be under the modal surfaces currently open: 1
/// when none is, falling to 0 as a covering sheet or dialog finishes
/// entering, rising again as it leaves.
class _ModalCover extends Animation<double>
    with
        AnimationEagerListenerMixin,
        AnimationLocalListenersMixin,
        AnimationLocalStatusListenersMixin {
  final _modals = <Animation<double>>[];
  AnimationStatus _lastStatus = AnimationStatus.completed;

  void add(Animation<double> modal) {
    _modals.add(modal);
    modal.addListener(_changed);
    _changed();
  }

  void remove(Animation<double> modal) {
    if (!_modals.remove(modal)) return;
    modal.removeListener(_changed);
    _changed();
  }

  void _changed() {
    notifyListeners();
    final status = this.status;
    if (status != _lastStatus) {
      _lastStatus = status;
      notifyStatusListeners(status);
    }
  }

  @override
  double get value {
    var covered = 0.0;
    for (final modal in _modals) {
      covered = math.max(covered, modal.value);
    }
    return 1 - covered;
  }

  @override
  AnimationStatus get status => switch (value) {
    1.0 => AnimationStatus.completed,
    0.0 => AnimationStatus.dismissed,
    _ => AnimationStatus.forward,
  };

  @override
  void dispose() {
    for (final modal in _modals) {
      modal.removeListener(_changed);
    }
    _modals.clear();
    super.dispose();
  }
}

/// Fades the prompt with [cover] and keeps it from taking taps while any
/// modal surface covers it — the taps belong to the sheet or its scrim.
class _CoveredByModals extends StatelessWidget {
  const _CoveredByModals({required this.cover, required this.child});

  final Animation<double> cover;
  final Widget child;

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: cover,
    child: _CoverHitGate(cover: cover, child: child),
  );
}

class _CoverHitGate extends SingleChildRenderObjectWidget {
  const _CoverHitGate({required this.cover, super.child});

  final Animation<double> cover;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderCoverHitGate(cover);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderCoverHitGate renderObject,
  ) => renderObject.cover = cover;
}

class _RenderCoverHitGate extends RenderProxyBox {
  _RenderCoverHitGate(this.cover);

  Animation<double> cover;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) =>
      cover.value == 1 && super.hitTest(result, position: position);
}

/// Marks a modal surface that must cover prompts.
///
/// The host draws prompts above every navigator, so a sheet or dialog
/// would otherwise open under a prompt still on screen. While this widget
/// is mounted the prompt fades out with [animation] — the modal route's
/// own entrance — and back in as the route leaves, the way a dialog window
/// covers a Snackbar on Android. The app's sheet and dialog routes wrap
/// their barrier in it. Without a host above, it does nothing.
class PromptCover extends StatefulWidget {
  const PromptCover({super.key, required this.animation, required this.child});

  final Animation<double> animation;
  final Widget child;

  @override
  State<PromptCover> createState() => _PromptCoverState();
}

class _PromptCoverState extends State<PromptCover> {
  _ModalCover? _cover;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final cover = PromptHost.maybeOf(context)?._cover;
    if (identical(cover, _cover)) return;
    _cover?.remove(widget.animation);
    _cover = cover?..add(widget.animation);
  }

  @override
  void didUpdateWidget(PromptCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.animation, widget.animation)) return;
    _cover
      ?..remove(oldWidget.animation)
      ..add(widget.animation);
  }

  @override
  void dispose() {
    _cover?.remove(widget.animation);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
