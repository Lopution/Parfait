import 'package:material_ui/material_ui.dart';

import '../layout/app_breakpoints.dart';
import '../layout/content_widths.dart';
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
  });

  /// Top slot — brand lockup or page heading. Scrolls with the content.
  final Widget header;

  /// Middle slot — the form or option list body.
  final Widget content;

  /// Bottom-anchored primary action. When the content is shorter than the
  /// viewport it pins to the bottom edge; on short viewports it flows
  /// after the content so it always remains reachable by scrolling.
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

  @override
  Widget build(BuildContext context) {
    return ReplicaScaffold(
      title: title,
      actions: actions,
      child: LayoutBuilder(
        builder: (context, constraints) =>
            AppBreakpoints.useSideBySideForm(constraints.biggest)
            ? _sideBySide(constraints)
            : _stacked(constraints),
      ),
    );
  }

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
          child: Column(
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

  Widget _actionColumn() => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SizedBox(height: FuncSpacing.xxxl),
      primaryAction,
      if (secondary != null) ...[
        const SizedBox(height: FuncSpacing.sm),
        secondary!,
      ],
      const SizedBox(height: FuncSpacing.xl),
    ],
  );
}
