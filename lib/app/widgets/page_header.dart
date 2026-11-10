import 'package:material_ui/material_ui.dart';

import '../../core/search/search_models.dart';
import '../../l10n/context.dart';
import '../icons/app_icons.dart';
import '../layout/app_breakpoints.dart';
import '../layout/form_factor.dart';
import '../navigation/home_shell_metrics.dart';
import '../navigation/routes.dart';
import '../theme/func_semantic_tokens.dart';
import 'func_bottom_nav.dart';
import 'search_field_button.dart';

/// How page top bars are laid out on the shell's larger forms (NAV-20).
abstract final class PageHeader {
  /// Whether bars take the wide layout: wherever the shell shows its rail.
  static bool isWide(BuildContext context) =>
      FormFactor.of(context).hasRail(MediaQuery.sizeOf(context).width);

  /// Whether the content area — the window less the rail — has room for a
  /// top bar's full search field rather than its icon (R7): the expanded
  /// window class.
  static bool fitsSearchField(BuildContext context) =>
      HomeShellChrome.contentSizeOf(context).width >= AppBreakpoints.expanded;

  /// Width of a top bar's search field look-alike: the full one where the
  /// content area [fitsSearchField], the narrow one below it (R9).
  static double searchFieldWidth(BuildContext context) =>
      fitsSearchField(context) ? 360 : 240;
}

/// A destination's way into the search input on the shell's larger forms
/// (R7): a field-shaped button where the content area has room for it, an
/// icon below that. Only a destination's own root page carries one; a page
/// pushed over it is not a destination and shows none (R8).
class HeaderSearch extends StatelessWidget {
  const HeaderSearch({super.key, this.type = SearchResultType.illust});

  /// The kind the input opens on; the search destination passes its
  /// selected tab.
  final SearchResultType type;

  /// Off the bar's own edge, as the field's rounded end needs.
  static const EdgeInsetsGeometry _padding = EdgeInsetsDirectional.only(
    start: FuncSpacing.sm,
    end: FuncSpacing.lg,
  );

  @override
  Widget build(BuildContext context) {
    if (!PageHeader.isWide(context) ||
        BranchRootScope.maybeOf(context) == null) {
      return const SizedBox.shrink();
    }
    final l10n = context.l10n;
    return Padding(
      padding: _padding,
      child: PageHeader.fitsSearchField(context)
          ? SizedBox(
              width: PageHeader.searchFieldWidth(context),
              child: SearchFieldButton(
                text: l10n.searchBarHint,
                isHint: true,
                onTap: () => openSearchInput(context, type: type),
              ),
            )
          : IconButton(
              tooltip: l10n.searchTitle,
              icon: const Icon(AppIcons.search),
              onPressed: () => openSearchInput(context, type: type),
            ),
    );
  }
}
