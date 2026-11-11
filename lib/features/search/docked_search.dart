import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../app/motion/app_overlays.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../app/widgets/page_header.dart';
import '../../core/search/search_models.dart';
import 'search_page.dart' show SearchInputEngine, SearchInputEngineState;

/// What the docked search panel decided when it closed.
sealed class DockedSearchOutcome {
  const DockedSearchOutcome();
}

/// The user searched [query]: the host moves to the results (R10).
final class DockedSearchSubmitted extends DockedSearchOutcome {
  const DockedSearchSubmitted(this.query);

  final SearchQuery query;
}

/// The window narrowed to the phone layout: carry the draft to the full
/// input page instead (R10).
final class DockedSearchNarrowed extends DockedSearchOutcome {
  const DockedSearchNarrowed({required this.keyword, required this.type});

  final String keyword;
  final SearchResultType type;
}

/// A docked panel is at least this wide, however narrow its trigger is.
const double dockedSearchMinWidth = 360;

/// The panel's outer margin from the content area's edges.
const double _edge = 12;

/// Space between the trigger's bottom and the panel.
const double _gap = 8;

/// Opens the search input as a panel under [anchor] — the trigger's global
/// rectangle — over the whole shell and its scrim (R10).
///
/// The panel is as wide as the trigger, at least [dockedSearchMinWidth], and
/// runs to the bottom of the content area. It closes with an outcome: the
/// user searched, or the window became a phone's layout and the draft has to
/// move to the full page.
Future<DockedSearchOutcome?> showDockedSearch(
  BuildContext context, {
  required Rect anchor,
  String initialKeyword = '',
  SearchResultType type = SearchResultType.illust,
}) {
  final overlay =
      Navigator.of(
            context,
            rootNavigator: true,
          ).overlay!.context.findRenderObject()!
          as RenderBox;
  final topLeft = overlay.globalToLocal(anchor.topLeft);
  final trigger = topLeft & anchor.size;
  final rect = _panelRect(trigger, overlay.size);
  // The root navigator: the panel is modal over the whole shell, so the
  // rail cannot switch branches underneath it.
  return showAppPanel<DockedSearchOutcome>(
    context: context,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    builder: (context) => Stack(
      children: [
        Positioned.fromRect(
          rect: rect,
          child: DockedSearchPanel(
            initialKeyword: initialKeyword,
            initialType: type,
          ),
        ),
      ],
    ),
  );
}

/// The panel's place in the content area: under [trigger], at least
/// [dockedSearchMinWidth] wide, right-aligned when the trigger is narrower,
/// down to the bottom edge.
Rect _panelRect(Rect trigger, Size area) {
  final available = math.max(0.0, area.width - 2 * _edge);
  final width = math.min(
    math.max(dockedSearchMinWidth, trigger.width),
    available,
  );
  var left = trigger.left;
  if (width > trigger.width || left + width > area.width - _edge) {
    left = trigger.right - width;
  }
  left = left.clamp(_edge, math.max(_edge, area.width - width - _edge));
  final top = trigger.bottom + _gap;
  final height = math.max(0.0, area.height - top - _edge);
  return Rect.fromLTWH(left, top, width, height);
}

/// The docked search input (R10): the full page's field, kinds, filters,
/// history and suggestions in a panel under the trigger.
///
/// A phone's layout has no rail and no docked input: when the window narrows
/// that far the panel closes and hands the typed draft to the full page.
class DockedSearchPanel extends StatefulWidget {
  const DockedSearchPanel({
    super.key,
    this.initialKeyword = '',
    this.initialType = SearchResultType.illust,
  });

  final String initialKeyword;
  final SearchResultType initialType;

  @override
  State<DockedSearchPanel> createState() => _DockedSearchPanelState();
}

class _DockedSearchPanelState extends State<DockedSearchPanel> {
  final _engine = GlobalKey<SearchInputEngineState>();
  var _narrowing = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The rail is what the panel hangs on; a window that loses it has no
    // docked input (PageHeader.isWide reads the MediaQuery size).
    if (!PageHeader.isWide(context)) _narrowToFullPage();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainer,
      elevation: 8,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: SearchInputEngine(
        key: _engine,
        initialKeyword: widget.initialKeyword,
        initialType: widget.initialType,
        onSubmit: (query) =>
            Navigator.of(context).pop(DockedSearchSubmitted(query)),
        builder: (context, parts) => Column(
          children: [
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(
                FuncSpacing.md,
                FuncSpacing.md,
                FuncSpacing.sm,
                FuncSpacing.sm,
              ),
              child: Row(
                children: [
                  Expanded(child: parts.field),
                  parts.filterButton,
                ],
              ),
            ),
            parts.tabs,
            Expanded(child: parts.body),
          ],
        ),
      ),
    );
  }

  /// The phone layout took over: close with the draft so the host can open
  /// the full input page with it.
  void _narrowToFullPage() {
    if (_narrowing) return;
    _narrowing = true;
    final state = _engine.currentState;
    final keyword = state?.keyword ?? widget.initialKeyword;
    final type = state?.type ?? widget.initialType;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(
        context,
      ).pop(DockedSearchNarrowed(keyword: keyword, type: type));
    });
  }
}
