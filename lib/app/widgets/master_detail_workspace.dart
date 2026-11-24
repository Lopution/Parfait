import 'package:material_ui/material_ui.dart';

import '../layout/app_breakpoints.dart';
import '../layout/window_layout_spec.dart';
import '../navigation/home_shell_metrics.dart';
import '../theme/func_semantic_tokens.dart';
import '../window/desktop_command_bar_scope.dart' show DesktopCommandBarScope;
import 'app_top_bar.dart' show EmbeddedHeaderScope;
import 'scroll_edge_fade.dart';

/// Shared wide-screen master-detail workspace skeleton (`280dp` left index on
/// `surfaceContainerLow`, a `1dp brandHairline` split, and flush `52dp` top
/// headers across both panes with an [EmbeddedHeaderScope] detail area).
class MasterDetailWorkspace extends StatelessWidget {
  const MasterDetailWorkspace({
    super.key,
    required this.title,
    this.masterTop,
    required this.masterBody,
    required this.detail,
    this.showMasterBack,
  });

  static const double masterWidth = 280.0;
  static const double headerHeight = 52.0;

  final Widget title;
  final Widget? masterTop;
  final Widget masterBody;
  final Widget detail;
  final bool? showMasterBack;

  static const double _minBookPaneWidth = 240.0;

  static BookHingeSplit? _bookSplitOf(BuildContext context) {
    final content = HomeShellChrome.contentSizeOf(context);
    final rail = HomeShellChrome.maybeOf(context)?.railExtent ?? 0.0;
    final leftOrigin = Directionality.of(context) == TextDirection.ltr
        ? rail
        : 0.0;
    return WindowLayoutSpec.of(context).bookSplitFor(
      content.width,
      leftOrigin: leftOrigin,
      minSideWidth: _minBookPaneWidth,
    );
  }

  /// Wide landscape layouts with enough room for both the `280dp` index pane
  /// and a comfortable detail workspace (`>= 840x480` content and not tall
  /// portrait), or a [FoldPosture.book] foldable split cleanly along its hinge.
  static bool canDisplay(BuildContext context) {
    final content = HomeShellChrome.contentSizeOf(context);
    if (content.height < AppBreakpoints.compactHeight) return false;
    if (_bookSplitOf(context) != null) return true;
    final viewport = MediaQuery.sizeOf(context);
    return content.width >= AppBreakpoints.expanded &&
        viewport.width >= viewport.height * 0.75;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final tokens = FuncSemanticTokens.of(context);
    final desktopOwned = DesktopCommandBarScope.isActiveOf(context);
    final effectiveBack =
        showMasterBack ??
        (!desktopOwned &&
            (ModalRoute.of(context)?.impliesAppBarDismissal ?? false));
    final titleStyle =
        (theme.appBarTheme.titleTextStyle ??
                theme.textTheme.titleLarge ??
                const TextStyle())
            .copyWith(fontWeight: FontWeight.w700, color: colors.onSurface);

    final bookSplit = _bookSplitOf(context);
    final effectiveMasterWidth = bookSplit?.leftWidth ?? masterWidth;
    final hingeGap = bookSplit?.hingeGap ?? 0.0;

    return Material(
      color: colors.surface,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: effectiveMasterWidth,
            child: ColoredBox(
              color: colors.surfaceContainerLow,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SafeArea(
                    right: false,
                    bottom: false,
                    child: Container(
                      height: headerHeight,
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(color: tokens.brandHairline),
                        ),
                      ),
                      padding: EdgeInsetsDirectional.fromSTEB(
                        effectiveBack ? FuncSpacing.xs : FuncSpacing.lg,
                        0,
                        FuncSpacing.lg,
                        0,
                      ),
                      child: Row(
                        children: [
                          if (effectiveBack) ...[
                            BackButton(
                              onPressed: () => Navigator.maybePop(context),
                            ),
                            const SizedBox(width: FuncSpacing.xs),
                          ],
                          Expanded(
                            child: Semantics(
                              header: true,
                              child: DefaultTextStyle(
                                style: titleStyle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                child: title,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Expanded(
                    child: Column(
                      // Lay out masterTop visually above masterBody while
                      // keeping masterBody ahead of masterTop in widget order
                      // so scroll queries target the index list first.
                      verticalDirection: VerticalDirection.up,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: ScrollEdgeFade(
                            axis: Axis.vertical,
                            fadeExtent: FuncSpacing.lg,
                            child: masterBody,
                          ),
                        ),
                        ?masterTop,
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (hingeGap > 1)
            SizedBox(
              width: hingeGap,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: 1,
                    child: ColoredBox(color: tokens.brandHairline),
                  ),
                  const Spacer(),
                  SizedBox(
                    width: 1,
                    child: ColoredBox(color: tokens.brandHairline),
                  ),
                ],
              ),
            )
          else
            SizedBox(width: 1, child: ColoredBox(color: tokens.brandHairline)),
          Expanded(child: EmbeddedHeaderScope(child: detail)),
        ],
      ),
    );
  }
}
