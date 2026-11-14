import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/settings/preference_keys.dart';
import '../motion/motion_tokens.dart';
import '../navigation/home_shell_metrics.dart';
import '../theme/func_semantic_tokens.dart';
import '../theme/func_tokens.dart';
import 'input_modality.dart';
import 'window_layout_spec.dart';

/// Two side-by-side panes for detail pages on landscape or foldable surfaces.
///
/// The [secondary] column takes [secondaryFraction] of the width, kept
/// between [secondaryMinWidth] and [secondaryMaxWidth] so text stays
/// readable on a turned phone and does not sprawl on a desktop; [primary]
/// takes the rest. Each pane is its own scroll region.
///
/// When a vertical book hinge ([FoldPosture.book]) splits the viewport, panes
/// align strictly to the left and right hinge edges so no widget crosses the
/// fold. On pointer devices with [resizable] enabled, dragging the seam adjusts
/// the split ratio and optionally persists it under [persistenceKey].
class TwoPane extends StatefulWidget {
  const TwoPane({
    super.key,
    required this.primary,
    required this.secondary,
    this.secondaryFraction = 0.38,
    this.secondaryMinWidth = 320,
    this.secondaryMaxWidth = 480,
    this.resizable = false,
    this.enableTabletop = false,
    this.persistenceKey,
  }) : assert(
         secondaryFraction > 0 && secondaryFraction < 1,
         'secondaryFraction must stay inside (0, 1)',
       );

  final Widget primary;
  final Widget secondary;
  final double secondaryFraction;
  final double secondaryMinWidth;
  final double secondaryMaxWidth;
  final bool resizable;
  final bool enableTabletop;
  final String? persistenceKey;

  /// The secondary column's width inside a [width]-wide two-pane layout.
  double secondaryWidthFor(double width) =>
      (width * secondaryFraction).clamp(secondaryMinWidth, secondaryMaxWidth);

  @override
  State<TwoPane> createState() => _TwoPaneState();
}

class _TwoPaneState extends State<TwoPane> {
  static const double _dragHandleHitWidth = FuncSpacing.sm;
  static const double _dividerLineWidth = 1;
  static const double _minPrimaryWidth = 280;
  static const double _minFoldSideWidth = 200;
  static const double _minTabletopSideHeight = 160;
  static const double _minFraction = 0.1;
  static const double _maxFraction = 0.7;

  static final Map<String, double> _sessionFractions = <String, double>{};

  double? _fraction;
  Offset? _measuredOrigin;
  bool _originCheckScheduled = false;
  bool _hoveringDivider = false;
  bool _draggingDivider = false;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    final key = widget.persistenceKey;
    if (key != null) {
      _fraction = _sessionFractions[key];
      if (_fraction == null) {
        unawaited(_loadPersistedFraction(key));
      }
    }
  }

  @override
  void didUpdateWidget(TwoPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.persistenceKey != oldWidget.persistenceKey) {
      final key = widget.persistenceKey;
      _fraction = key == null ? null : _sessionFractions[key];
      if (key != null && _fraction == null) {
        unawaited(_loadPersistedFraction(key));
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> _loadPersistedFraction(String key) async {
    try {
      final value = await SharedPreferencesAsync().getDouble(key);
      if (_disposed || !mounted || value == null) return;
      final clamped = value.clamp(_minFraction, _maxFraction);
      _sessionFractions[key] = clamped;
      setState(() => _fraction = clamped);
    } catch (_) {
      // Standalone widget tests without a preferences plugin keep the default.
    }
  }

  Future<void> _savePersistedFraction() async {
    final key = widget.persistenceKey;
    final value = _fraction;
    if (key == null || value == null) return;
    _sessionFractions[key] = value;
    try {
      await SharedPreferencesAsync().setDouble(key, value);
    } catch (_) {
      // Ignore storage errors outside the app container.
    }
  }

  void _scheduleOriginCheck() {
    if (_originCheckScheduled || _disposed) return;
    _originCheckScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _originCheckScheduled = false;
      if (_disposed || !mounted) return;
      final renderObject = context.findRenderObject();
      if (renderObject is! RenderBox || !renderObject.attached) return;
      final origin = renderObject.localToGlobal(Offset.zero);
      if (_measuredOrigin == null ||
          (origin.dx - _measuredOrigin!.dx).abs() > 0.5 ||
          (origin.dy - _measuredOrigin!.dy).abs() > 0.5) {
        setState(() => _measuredOrigin = origin);
      }
    });
  }

  double _resolveLeftOrigin(BuildContext context, WindowLayoutSpec spec) {
    final rail = HomeShellChrome.maybeOf(context)?.railExtent ?? 0;
    final defaultDx = Directionality.of(context) == TextDirection.ltr
        ? rail
        : 0.0;
    final measured = _measuredOrigin;
    if (measured == null || !measured.dx.isFinite) return defaultDx;
    return measured.dx;
  }

  double _resolveTopOrigin() {
    final measured = _measuredOrigin;
    if (measured == null || !measured.dy.isFinite) return 0;
    return measured.dy;
  }

  Widget _buildBookLayout(
    double maxWidth,
    Rect hinge,
    double leftOrigin,
    double defaultSecondaryWidth,
  ) {
    final localLeft = hinge.left - leftOrigin;
    final localRight = hinge.right - leftOrigin;
    final rightRemaining = maxWidth - localRight;
    if (localLeft < _minFoldSideWidth || rightRemaining < _minFoldSideWidth) {
      return _buildStandardRow(defaultSecondaryWidth);
    }
    final gap = math.max(0.0, localRight - localLeft);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(width: localLeft, child: widget.primary),
        if (gap > 0) SizedBox(width: gap),
        Expanded(child: widget.secondary),
      ],
    );
  }

  Widget? _buildTabletopLayout(double maxHeight, Rect hinge, double topOrigin) {
    final localTop = hinge.top - topOrigin;
    final localBottom = hinge.bottom - topOrigin;
    final bottomRemaining = maxHeight - localBottom;
    if (localTop < _minTabletopSideHeight ||
        bottomRemaining < _minTabletopSideHeight) {
      return null;
    }
    final gap = math.max(0.0, localBottom - localTop);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(height: localTop, child: widget.primary),
        if (gap > 0) SizedBox(height: gap),
        Expanded(child: widget.secondary),
      ],
    );
  }

  Widget _buildStandardRow(double secondaryWidth) => Row(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Expanded(child: widget.primary),
      SizedBox(width: secondaryWidth, child: widget.secondary),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final spec = WindowLayoutSpec.of(context);
    if (spec.hingeBounds != null) {
      _scheduleOriginCheck();
    }
    final fraction = _fraction ?? widget.secondaryFraction;

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        final maxAllowedSecondary = math.max(
          0.0,
          maxWidth - math.min(_minPrimaryWidth, maxWidth * 0.45),
        );
        final minSecondary = math.min(
          widget.secondaryMinWidth,
          maxAllowedSecondary,
        );
        final maxSecondary = math.max(
          minSecondary,
          math.min(widget.secondaryMaxWidth, maxAllowedSecondary),
        );
        final secondaryWidth = (maxWidth * fraction).clamp(
          minSecondary,
          maxSecondary,
        );

        final hinge = spec.hingeBounds;
        if (hinge != null && spec.posture == FoldPosture.book) {
          return _buildBookLayout(
            maxWidth,
            hinge,
            _resolveLeftOrigin(context, spec),
            secondaryWidth,
          );
        }

        if (widget.enableTabletop &&
            hinge != null &&
            spec.posture == FoldPosture.tabletop) {
          final tabletop = _buildTabletopLayout(
            constraints.maxHeight,
            hinge,
            _resolveTopOrigin(),
          );
          if (tabletop != null) return tabletop;
        }

        final row = _buildStandardRow(secondaryWidth);
        if (!widget.resizable) return row;

        final canResize =
            spec.inputModality == InputModality.pointer &&
            maxSecondary > minSecondary + 1;
        final rtl = Directionality.of(context) == TextDirection.rtl;
        final sign = rtl ? 1.0 : -1.0;
        final colors = Theme.of(context).colorScheme;
        final highlight = _draggingDivider || _hoveringDivider;

        return Stack(
          fit: StackFit.expand,
          children: [
            row,
            if (canResize)
              PositionedDirectional(
                end: secondaryWidth - _dragHandleHitWidth / 2,
                top: 0,
                bottom: 0,
                width: _dragHandleHitWidth,
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeColumn,
                  onEnter: (_) => setState(() => _hoveringDivider = true),
                  onExit: (_) => setState(() => _hoveringDivider = false),
                  child: GestureDetector(
                    key: const ValueKey('two-pane-resize-handle'),
                    behavior: HitTestBehavior.translucent,
                    onHorizontalDragStart: (_) =>
                        setState(() => _draggingDivider = true),
                    onHorizontalDragUpdate: (details) {
                      if (maxWidth <= 0) return;
                      final nextWidth =
                          (secondaryWidth + sign * details.delta.dx).clamp(
                            minSecondary,
                            maxSecondary,
                          );
                      final nextFraction = (nextWidth / maxWidth).clamp(
                        _minFraction,
                        _maxFraction,
                      );
                      setState(() => _fraction = nextFraction);
                      final key = widget.persistenceKey;
                      if (key != null) _sessionFractions[key] = nextFraction;
                    },
                    onHorizontalDragEnd: (_) {
                      setState(() => _draggingDivider = false);
                      unawaited(_savePersistedFraction());
                    },
                    onHorizontalDragCancel: () =>
                        setState(() => _draggingDivider = false),
                    child: Center(
                      child: AnimatedContainer(
                        duration: MotionTokens.resolve(
                          context,
                          MotionTokens.stateFade,
                        ),
                        width: _dividerLineWidth,
                        color: highlight
                            ? colors.primary.withValues(alpha: 0.7)
                            : FuncTokens.transparent,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Adaptive detail split pane with hinge avoidance, tabletop posture support,
/// pointer drag-resizing (340–460dp default band), and persisted ratio.
class AdaptiveTwoPane extends StatelessWidget {
  const AdaptiveTwoPane({
    super.key,
    required this.primary,
    required this.secondary,
    this.secondaryFraction = 0.38,
    this.secondaryMinWidth = 340,
    this.secondaryMaxWidth = 460,
    this.resizable = true,
    this.enableTabletop = true,
    this.persistenceKey = PreferenceKeys.twoPaneSecondaryFraction,
  });

  final Widget primary;
  final Widget secondary;
  final double secondaryFraction;
  final double secondaryMinWidth;
  final double secondaryMaxWidth;
  final bool resizable;
  final bool enableTabletop;
  final String? persistenceKey;

  @override
  Widget build(BuildContext context) => TwoPane(
    primary: primary,
    secondary: secondary,
    secondaryFraction: secondaryFraction,
    secondaryMinWidth: secondaryMinWidth,
    secondaryMaxWidth: secondaryMaxWidth,
    resizable: resizable,
    enableTabletop: enableTabletop,
    persistenceKey: persistenceKey,
  );
}
