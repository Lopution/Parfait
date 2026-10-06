import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Bottom chrome that prompts must clear, registered by the widgets that
/// draw it — the MDC `setAnchorView` equivalent for the app-wide
/// `PromptHost`.
///
/// [extent] is the largest live contribution: each anchor reports the
/// height it covers at the screen bottom right now, scaled by how present
/// its route is (see [PromptAnchor]). A hidden or covered anchor reports 0,
/// so the max settles on whatever chrome is actually on screen.
///
/// Listeners are notified synchronously whenever a contribution changes —
/// mid-build, from animation ticks and from unmounting — so they must only
/// schedule layout (a layout delegate's `relayout`), never rebuild.
class PromptAnchors extends ChangeNotifier {
  final _entries = <_AnchorEntry>{};

  double get extent {
    var extent = 0.0;
    for (final entry in _entries) {
      extent = math.max(extent, entry.contribution);
    }
    return extent;
  }

  _AnchorEntry _add(
    ValueListenable<double> extent,
    ModalRoute<dynamic>? route,
  ) {
    final entry = _AnchorEntry(extent, route, notifyListeners);
    _entries.add(entry);
    notifyListeners();
    return entry;
  }

  void _remove(_AnchorEntry entry) {
    if (!_entries.remove(entry)) return;
    entry.detach();
    notifyListeners();
  }
}

class _AnchorEntry {
  _AnchorEntry(this.extent, this.route, this._onChanged) {
    for (final source in _sources) {
      source.addListener(_onChanged);
    }
  }

  final ValueListenable<double> extent;
  final ModalRoute<dynamic>? route;
  final VoidCallback _onChanged;

  Iterable<Listenable> get _sources => [
    extent,
    ?route?.animation,
    ?route?.secondaryAnimation,
  ];

  /// The covered height, faded with the route: it rises as the route
  /// enters and sinks as a page route covers it. Flutter only drives
  /// `secondaryAnimation` for page-over-page transitions, so a sheet or
  /// dialog on top leaves the anchor in place.
  double get contribution {
    final route = this.route;
    if (route == null) return extent.value;
    final entered = route.animation?.value ?? 1;
    final covered = route.secondaryAnimation?.value ?? 0;
    return extent.value * entered * (1 - covered);
  }

  void detach() {
    for (final source in _sources) {
      source.removeListener(_onChanged);
    }
  }
}

/// Publishes [PromptAnchors] below the prompt host.
class PromptAnchorScope extends InheritedWidget {
  const PromptAnchorScope({
    super.key,
    required this.anchors,
    required super.child,
  });

  final PromptAnchors anchors;

  /// No dependency: the registry instance never changes.
  static PromptAnchors? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<PromptAnchorScope>()?.anchors;

  @override
  bool updateShouldNotify(PromptAnchorScope oldWidget) =>
      !identical(anchors, oldWidget.anchors);
}

/// Declares that [child] is bottom chrome covering [extent] logical pixels
/// at the screen bottom — the shell's navigation bar, a page's floating
/// action bar. Prompts rest above the tallest anchor on screen.
///
/// [extent] is read live, so chrome that slides publishes its current
/// height and the prompt moves in step. The contribution also follows the
/// enclosing route: it rises with the route's entrance and sinks while a
/// page route covers it. Outside a prompt host (tests, previews) the
/// anchor does nothing.
class PromptAnchor extends StatefulWidget {
  const PromptAnchor({super.key, required this.extent, required this.child});

  final ValueListenable<double> extent;
  final Widget child;

  @override
  State<PromptAnchor> createState() => _PromptAnchorState();
}

class _PromptAnchorState extends State<PromptAnchor> {
  PromptAnchors? _anchors;
  _AnchorEntry? _entry;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _register();
  }

  @override
  void didUpdateWidget(PromptAnchor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.extent, widget.extent)) _register();
  }

  void _register() {
    final anchors = PromptAnchorScope.maybeOf(context);
    final route = ModalRoute.of(context);
    final entry = _entry;
    if (identical(anchors, _anchors) &&
        entry != null &&
        identical(entry.route, route) &&
        identical(entry.extent, widget.extent)) {
      return;
    }
    _unregister();
    _anchors = anchors;
    _entry = anchors?._add(widget.extent, route);
  }

  void _unregister() {
    final entry = _entry;
    if (entry != null) _anchors?._remove(entry);
    _entry = null;
  }

  @override
  void dispose() {
    _unregister();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
