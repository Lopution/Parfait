import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'home_shell_metrics.dart';

/// Keeps [child] on the [MediaQueryData], [HomeShellChrome] and
/// [BoxConstraints] it last saw while it is hidden. System bars showing or
/// hiding, the keyboard moving and the window resizing then rebuild only this
/// widget, and nothing under it rebuilds or lays out again. Shown again, it
/// takes the current values and constraints in that frame, before layout and
/// paint, so no frame shows the frozen ones.
///
/// A hidden subtree still builds and lays out: a route covered by an
/// opaque one and a branch in an `Offstage` stay attached, and the
/// pipeline lays out every dirty boundary in them. Each bar toggle of the
/// reader, each rail/window resize and each frame of a keyboard animation
/// rebuilt scaffolds and laid out slivers in hidden branches and tabs.
class FrozenWhileHidden extends StatefulWidget {
  /// Hidden while its [TickerMode] is off. In this app that is a page
  /// covered by an opaque route or in a hidden branch, and the branch a
  /// switch leaves, which paints from a snapshot.
  const FrozenWhileHidden({super.key, required this.child}) : hidden = null;

  /// Hidden while [hidden] holds.
  const FrozenWhileHidden.when({
    super.key,
    required bool this.hidden,
    required this.child,
  });

  final bool? hidden;
  final Widget child;

  @override
  State<FrozenWhileHidden> createState() => _FrozenWhileHiddenState();
}

class _FrozenWhileHiddenState extends State<FrozenWhileHidden> {
  late MediaQueryData _media;
  HomeShellChrome? _chrome;
  bool _seen = false;

  @override
  Widget build(BuildContext context) {
    final hidden = widget.hidden ?? !TickerMode.valuesOf(context).enabled;
    final media = MediaQuery.of(context);
    final chrome = HomeShellChrome.maybeOf(context);
    if (!hidden || !_seen) {
      _media = media;
      _chrome = chrome;
      _seen = true;
    }
    final child = MediaQuery(data: _media, child: widget.child);
    return _FreezeConstraints(
      hidden: hidden,
      child: _chrome?.over(child) ?? child,
    );
  }
}

class _FreezeConstraints extends SingleChildRenderObjectWidget {
  const _FreezeConstraints({required this.hidden, required super.child});

  final bool hidden;

  @override
  _RenderFreezeConstraints createRenderObject(BuildContext context) =>
      _RenderFreezeConstraints(hidden: hidden);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderFreezeConstraints renderObject,
  ) {
    renderObject.hidden = hidden;
  }
}

class _RenderFreezeConstraints extends RenderProxyBox {
  _RenderFreezeConstraints({required bool hidden}) : _hidden = hidden;

  bool _hidden;
  BoxConstraints? _lastChildConstraints;

  set hidden(bool value) {
    if (_hidden == value) return;
    _hidden = value;
    if (!_hidden) markNeedsLayout();
  }

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    if (_hidden &&
        child.hasSize &&
        _lastChildConstraints != null &&
        constraints != _lastChildConstraints) {
      // Skip child relayout when parent constraints change while hidden, while
      // keeping our own size within incoming bounds for RenderBox invariants.
      size = constraints.constrain(child.size);
      return;
    }
    _lastChildConstraints = constraints;
    child.layout(constraints, parentUsesSize: true);
    size = child.size;
  }
}
