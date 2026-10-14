import 'package:flutter/widgets.dart';

/// Content-width roles shared by capped-width pages.
///
/// Content width answers "how wide may the readable column be" inside
/// whatever layout the breakpoints selected — it is a per-role constant,
/// not a breakpoint. `AppBreakpoints` decides *when* a layout changes;
/// `ContentWidths` decides how wide content may grow within it. Width caps
/// must read these constants rather than inventing per-page numbers or
/// reusing breakpoint values.
///
/// Role table frozen by the ui-interaction-consistency review (parent
/// design §5.5). New roles register here first.
abstract final class ContentWidths {
  /// Forms and onboarding flows (welcome/language/theme, login, profile
  /// and bookmark editors).
  static const double form = 520;

  /// Settings pages — option lists stay dense rather than stretching to
  /// the full wide surface.
  static const double settings = 600;

  /// Articles and long-form documents (Spotlight, user agreement).
  /// bodyMedium at 14sp reads best around 45-55 CJK characters per line,
  /// which maps to roughly 640-760dp — 700 sits in that band.
  static const double article = 700;

  /// Management lists (history, watch-later, follows, downloads) — denser
  /// than an article so actions stay close to their rows.
  static const double management = 840;
}

/// Centres [child] at no more than [maxWidth]; narrower surfaces pass
/// through unchanged. The child keeps tight constraints either way.
class ContentWidthCap extends StatelessWidget {
  const ContentWidthCap({
    super.key,
    required this.maxWidth,
    required this.child,
  });

  final double maxWidth;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final inset = (constraints.maxWidth - maxWidth) / 2;
        return Padding(
          padding: EdgeInsets.symmetric(horizontal: inset > 0 ? inset : 0),
          child: child,
        );
      },
    );
  }
}
