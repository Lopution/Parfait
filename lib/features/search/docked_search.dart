import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../app/motion/app_overlays.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../app/widgets/page_header.dart';
import '../../core/debug/frame_probe.dart';
import '../../core/search/search_models.dart';
import '../../core/search/search_shortcut.dart';
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
/// input page instead (R10). The keyword is exactly as typed — handing it
/// over must not trim it — and the filter drafts come along too.
final class DockedSearchNarrowed extends DockedSearchOutcome {
  const DockedSearchNarrowed({
    required this.keyword,
    required this.type,
    this.illustFilters,
    this.novelFilters,
  });

  final String keyword;
  final SearchResultType type;
  final IllustSearchFilters? illustFilters;
  final NovelSearchFilters? novelFilters;
}

/// What the draft names by id or link: the host opens it once the panel is
/// out of the way (R10).
final class DockedSearchShortcut extends DockedSearchOutcome {
  const DockedSearchShortcut(this.shortcut);

  final SearchShortcut shortcut;
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
/// runs to the bottom of the content area. [anchorOf] answers where the
/// trigger is *now*, so a window that resizes while the panel is open keeps
/// the panel under it; without it the panel keeps the rectangle it opened
/// with. It closes with an outcome: the user searched, opened what a draft
/// names, or the window became a phone's layout and the draft has to move to
/// the full page.
Future<DockedSearchOutcome?> showDockedSearch(
  BuildContext context, {
  required Rect anchor,
  Rect? Function()? anchorOf,
  String initialKeyword = '',
  SearchResultType type = SearchResultType.illust,
}) {
  final overlay =
      Navigator.of(
            context,
            rootNavigator: true,
          ).overlay!.context.findRenderObject()!
          as RenderBox;
  // The root navigator: the panel is modal over the whole shell, so the
  // rail cannot switch branches underneath it.
  return showAppPanel<DockedSearchOutcome>(
    context: context,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    builder: (context) => _DockedSearchLayer(
      overlay: overlay,
      anchor: anchor,
      anchorOf: anchorOf,
      child: DockedSearchPanel(
        initialKeyword: initialKeyword,
        initialType: type,
      ),
    ),
  );
}

/// Places and sizes the panel inside the overlay, and follows the trigger
/// when the window resizes: the page below lays out after this build, so a
/// post-frame pass re-anchors to where it actually landed (R10).
class _DockedSearchLayer extends StatefulWidget {
  const _DockedSearchLayer({
    required this.overlay,
    required this.anchor,
    required this.child,
    this.anchorOf,
  });

  final RenderBox overlay;
  final Rect anchor;
  final Rect? Function()? anchorOf;
  final Widget child;

  @override
  State<_DockedSearchLayer> createState() => _DockedSearchLayerState();
}

class _DockedSearchLayerState extends State<_DockedSearchLayer> {
  Size? _viewSize;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final size = MediaQuery.sizeOf(context);
    if (size == _viewSize) return;
    _viewSize = size;
    // The first drop is the opening layout. Later ones are a resize: the
    // trigger moves this frame, but its render box still holds the old
    // place until layout, so ask again once the frame is laid out.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    // The live anchor when the trigger is still mounted; the opening one
    // otherwise (the panel is closing then anyway).
    final global = widget.anchorOf?.call() ?? widget.anchor;
    final topLeft = widget.overlay.globalToLocal(global.topLeft);
    final rect = _rectFor(topLeft & global.size, widget.overlay.size);
    return Stack(
      children: [Positioned.fromRect(rect: rect, child: widget.child)],
    );
  }
}

/// The panel's place in the content area: under [trigger], at least
/// [dockedSearchMinWidth] wide, right-aligned when the trigger is narrower,
/// down to the bottom edge.
Rect _rectFor(Rect trigger, Size area) {
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
  void initState() {
    super.initState();
    // QUAL-05: the panel is a scene of its own — its fade is marked by the
    // route (app_overlays), its whole session here.
    FrameProbe.instance
      ..enter('docked search')
      ..mark('docked search open');
  }

  @override
  void dispose() {
    FrameProbe.instance
      ..mark('docked search end')
      ..exit('docked search');
    super.dispose();
  }

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
        // An id or a link leaves the panel before the page it names opens,
        // so the detail page is never left under the panel (R10).
        onShortcut: (shortcut) =>
            Navigator.of(context).pop(DockedSearchShortcut(shortcut)),
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
  /// the full input page with it — the text as typed, the kind, and the
  /// filter edits made here.
  void _narrowToFullPage() {
    if (_narrowing) return;
    _narrowing = true;
    final state = _engine.currentState;
    final keyword = state?.draft ?? widget.initialKeyword;
    final type = state?.type ?? widget.initialType;
    final illustFilters = state?.illustFilters;
    final novelFilters = state?.novelFilters;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final navigator = Navigator.of(context);
      final panel = ModalRoute.of(context);
      if (panel == null) return;
      // A filter sheet (or another surface the panel opened) sits above the
      // panel: close it first, or its scrim outlives the panel and blocks
      // the full page. Only the panel then closes with the draft.
      while (!panel.isCurrent && navigator.canPop()) {
        navigator.pop();
      }
      if (!panel.isCurrent) return;
      navigator.pop(
        DockedSearchNarrowed(
          keyword: keyword,
          type: type,
          illustFilters: illustFilters,
          novelFilters: novelFilters,
        ),
      );
    });
  }
}
