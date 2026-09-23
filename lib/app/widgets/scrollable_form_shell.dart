import 'package:material_ui/material_ui.dart';

import '../layout/content_widths.dart';
import 'replica_scaffold.dart';

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
///
/// Consumers: onboarding welcome/language/theme pages and the login page.
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
  /// (e.g. a "set up later" skip button).
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
        builder: (context, constraints) {
          // Same inset model the welcome page proved out: proportional
          // horizontal padding capped so ultra-wide surfaces stop growing
          // margins, and a viewport minus padding floor so spaceBetween
          // can pin the action slot to the bottom.
          final horizontal = (constraints.maxWidth * .1).clamp(24.0, 48.0);
          final minHeight = (constraints.maxHeight - 48).clamp(
            0.0,
            double.infinity,
          );
          return SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(horizontal, 24, horizontal, 24),
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: contentMaxWidth,
                  minHeight: minHeight,
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SizedBox(height: 48),
                        header,
                        const SizedBox(height: 48),
                        content,
                      ],
                    ),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SizedBox(height: 48),
                        primaryAction,
                        if (secondary != null) ...[
                          const SizedBox(height: 8),
                          secondary!,
                        ],
                        const SizedBox(height: 24),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
