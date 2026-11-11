import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../layout/app_breakpoints.dart';
import '../layout/content_widths.dart';
import 'ambient_wash.dart';
import 'replica_scaffold.dart';
import '../theme/func_semantic_tokens.dart';

/// Shared shell for form/onboarding-style pages: a scrollable,
/// width-capped column whose primary action stays reachable at any
/// viewport height.
///
/// Structure: `ReplicaScaffold` → `SingleChildScrollView` → `Center` →
/// `ConstrainedBox(maxWidth: contentMaxWidth, minHeight: viewport)` →
/// `Column(spaceBetween, stretch)`.
///
/// - Slots: [header] (top, scrolls with content), [content] (middle),
///   [primaryAction] (pinned to the bottom when content is shorter than
///   the viewport; flows right after content when it overflows),
///   [secondary] (optional affordance under the primary action).
/// - [contentMaxWidth] is a role-based content width (see
///   [ContentWidths]), not a breakpoint.
/// - On a short, wide window (`AppBreakpoints.useSideBySideForm`) the
///   header moves beside the form.
/// - [brandGlow] lights the page behind the header with the app icon's
///   own colour.
///
/// Consumers: onboarding welcome/language pages and the login page.
class ScrollableFormShell extends StatelessWidget {
  const ScrollableFormShell({
    super.key,
    required this.header,
    required this.content,
    required this.primaryAction,
    this.secondary,
    this.contentMaxWidth = ContentWidths.form,
    this.title,
    this.actions,
    this.brandGlow = false,
  });

  /// Top slot — brand lockup or page heading. Scrolls with the content.
  final Widget header;

  /// Middle slot — the form or option list body.
  final Widget content;

  /// Bottom-anchored primary action. When the content is shorter than the
  /// viewport it pins to the bottom edge on a compact window, and centres
  /// with the rest of the group on a large one; on short viewports it
  /// flows after the content so it always remains reachable by scrolling.
  final Widget primaryAction;

  /// Optional secondary affordance rendered under [primaryAction]
  /// (e.g. a secondary sign-in choice).
  final Widget? secondary;

  /// Role-based content width cap — a `ContentWidths` role constant, not
  /// a breakpoint. Defaults to [ContentWidths.form].
  final double contentMaxWidth;

  /// AppBar title forwarded to [ReplicaScaffold].
  final Widget? title;

  /// AppBar actions forwarded to [ReplicaScaffold].
  final List<Widget>? actions;

  /// The first-run pages' backdrop (THEME-19): the app icon's ambient
  /// light glowing behind the header.
  final bool brandGlow;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      // The outer layout includes the toolbar; use the same body height the
      // Scaffold will give the form so short-window geometry is unchanged.
      final bodyConstraints = constraints.copyWith(
        minHeight: (constraints.minHeight - kToolbarHeight).clamp(
          0.0,
          double.infinity,
        ),
        maxHeight: (constraints.maxHeight - kToolbarHeight).clamp(
          0.0,
          double.infinity,
        ),
      );
      final beside = AppBreakpoints.useSideBySideForm(bodyConstraints.biggest);
      final form = beside
          ? _sideBySide(bodyConstraints)
          : _stacked(bodyConstraints);
      final body = !brandGlow
          ? form
          : Stack(
              fit: StackFit.expand,
              children: [
                _BrandGlow(beside: beside, maxExtent: contentMaxWidth),
                form,
              ],
            );
      return ReplicaScaffold(
        title: title,
        actions: actions,
        // The form occupies the right half in a short side-by-side window;
        // a centred full-page inset would put the bar over neither column.
        contentWidth: beside ? null : contentMaxWidth,
        child: body,
      );
    },
  );

  /// Proportional horizontal padding, capped so ultra-wide surfaces stop
  /// growing margins.
  static double _horizontalPadding(double width) =>
      (width * .1).clamp(24.0, 48.0);

  /// The viewport less the vertical padding: the floor that lets
  /// spaceBetween pin the action slot to the bottom.
  static double _minColumnHeight(double height) =>
      (height - 2 * FuncSpacing.xl).clamp(0.0, double.infinity);

  Widget _stacked(BoxConstraints constraints) {
    final horizontal = _horizontalPadding(constraints.maxWidth);
    final centered = constraints.maxWidth >= AppBreakpoints.expanded;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        horizontal,
        FuncSpacing.xl,
        horizontal,
        FuncSpacing.xl,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: contentMaxWidth,
            minHeight: _minColumnHeight(constraints.maxHeight),
          ),
          // On a large window header, form and action read as one group,
          // centred instead of pinned to the window's two edges (C7); the
          // compact forms keep the action at the bottom, where a thumb
          // reaches it. A group taller than the window still scrolls.
          child: centered
              ? Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    header,
                    const SizedBox(height: FuncSpacing.xl),
                    content,
                    _actionColumn(gap: FuncSpacing.xl),
                  ],
                )
              : Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SizedBox(height: FuncSpacing.xxxl),
                        header,
                        const SizedBox(height: FuncSpacing.xxxl),
                        content,
                      ],
                    ),
                    _actionColumn(),
                  ],
                ),
        ),
      ),
    );
  }

  /// A short, wide window (a phone held sideways) has no room to stack the
  /// header above the form: the header takes the start half, the form and
  /// its action the end half, so the action is on the first screen.
  Widget _sideBySide(BoxConstraints constraints) {
    final half = constraints.maxWidth / 2;
    final horizontal = _horizontalPadding(half);
    final padding = EdgeInsets.fromLTRB(
      horizontal,
      FuncSpacing.xl,
      horizontal,
      FuncSpacing.xl,
    );
    return Row(
      children: [
        Expanded(
          child: Center(
            child: SingleChildScrollView(padding: padding, child: header),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: padding,
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: contentMaxWidth,
                  minHeight: _minColumnHeight(constraints.maxHeight),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [content, _actionColumn()],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _actionColumn({double gap = FuncSpacing.xxxl}) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SizedBox(height: gap),
      primaryAction,
      if (secondary != null) ...[
        const SizedBox(height: FuncSpacing.sm),
        secondary!,
      ],
      const SizedBox(height: FuncSpacing.xl),
    ],
  );
}

/// The app icon through the ambient tone lock, blurred, fading out
/// radially into the page from where the header sits, and in from the
/// body's top edge so the bar above does not cut it. Opaque, like the page
/// under it.
class _BrandGlow extends StatelessWidget {
  const _BrandGlow({required this.beside, required this.maxExtent});

  /// The header's place: beside the form, or above it.
  final bool beside;

  /// The glow's scale is the shorter side of the page, up to this (the
  /// form's width), so a tablet's glow stays the size of its form.
  final double maxExtent;

  /// The stacked header starts under the top padding; the glow centres a
  /// little into it, whatever the page height.
  static const _stackedHeadCenter =
      FuncSpacing.xl + FuncSpacing.xxxl + FuncSpacing.xxxl + FuncSpacing.lg;

  /// The fade in from the top edge: the stacked header's top padding.
  static const _topFade = FuncSpacing.xl + FuncSpacing.xxxl;

  @override
  Widget build(BuildContext context) {
    final direction = Directionality.of(context);
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final scale = math.min(size.shortestSide, maxExtent);
        final fromStart = beside ? size.width / 4 : size.width / 2;
        final center = Offset(switch (direction) {
          TextDirection.ltr => fromStart,
          TextDirection.rtl => size.width - fromStart,
        }, beside ? size.height / 2 : _stackedHeadCenter);
        final icon = scale * 0.9;
        return ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (rect) => ui.Gradient.linear(
            Offset.zero,
            const Offset(0, _topFade),
            const [Color(0x00000000), Color(0xFF000000)],
          ),
          child: ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (rect) => ui.Gradient.radial(
              center,
              scale * 0.95,
              const [Color(0xFF000000), Color(0x8C000000), Color(0x00000000)],
              const [0, 0.5, 1],
            ),
            // The icon is placed on the page rather than covering it, so
            // it is blurred and toned as a widget (AmbientWash takes a
            // cover image). The page sits still: no swipe repeats these
            // layers.
            child: ClipRect(
              child: ColoredBox(
                color: theme.colorScheme.surface,
                child: ImageFiltered(
                  imageFilter: ui.ImageFilter.blur(
                    sigmaX: 48,
                    sigmaY: 48,
                    tileMode: TileMode.clamp,
                  ),
                  child: ColorFiltered(
                    colorFilter: AmbientTone.of(theme),
                    child: Stack(
                      children: [
                        Positioned(
                          left: center.dx - icon / 2,
                          top: center.dy - icon / 2,
                          width: icon,
                          height: icon,
                          child: Image.asset(
                            'assets/branding/parfait_icon.png',
                            excludeFromSemantics: true,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
