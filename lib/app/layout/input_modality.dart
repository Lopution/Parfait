import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// Current primary interaction mode observed at the root pointer stream.
enum InputModality { touch, pointer }

/// Returns the sensible startup [InputModality] for [platform] before any
/// pointer event is observed.
InputModality defaultInputModalityFor(TargetPlatform platform) =>
    switch (platform) {
      TargetPlatform.windows ||
      TargetPlatform.macOS ||
      TargetPlatform.linux => InputModality.pointer,
      TargetPlatform.android ||
      TargetPlatform.iOS ||
      TargetPlatform.fuchsia => InputModality.touch,
    };

/// Maps a pointer's device kind to [InputModality], or null for `unknown`.
InputModality? inputModalityForPointerKind(PointerDeviceKind kind) =>
    switch (kind) {
      PointerDeviceKind.mouse ||
      PointerDeviceKind.trackpad => InputModality.pointer,
      PointerDeviceKind.touch ||
      PointerDeviceKind.stylus ||
      PointerDeviceKind.invertedStylus => InputModality.touch,
      PointerDeviceKind.unknown => null,
    };

/// Dynamically tracks whether the user is interacting via [InputModality.touch]
/// or [InputModality.pointer] across the subtree below it.
class InputModalityScope extends StatefulWidget {
  const InputModalityScope({
    super.key,
    this.initialModality,
    required this.child,
  });

  /// Optional override for initial modality; defaults from [defaultTargetPlatform].
  final InputModality? initialModality;
  final Widget child;

  static InputModality? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_InputModalityInherited>()
      ?.notifier
      ?.value;

  @override
  State<InputModalityScope> createState() => _InputModalityScopeState();
}

class _InputModalityScopeState extends State<InputModalityScope> {
  late final ValueNotifier<InputModality> _modality =
      ValueNotifier<InputModality>(
        widget.initialModality ??
            defaultInputModalityFor(defaultTargetPlatform),
      );

  @override
  void didUpdateWidget(InputModalityScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialModality != oldWidget.initialModality &&
        widget.initialModality != null) {
      _modality.value = widget.initialModality!;
    }
  }

  @override
  void dispose() {
    _modality.dispose();
    super.dispose();
  }

  void _trackPointer(PointerEvent event) {
    final next = inputModalityForPointerKind(event.kind);
    if (next != null && next != _modality.value) {
      _modality.value = next;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _trackPointer,
      onPointerHover: _trackPointer,
      onPointerMove: _trackPointer,
      onPointerPanZoomStart: _trackPointer,
      child: _InputModalityInherited(notifier: _modality, child: widget.child),
    );
  }
}

class _InputModalityInherited
    extends InheritedNotifier<ValueNotifier<InputModality>> {
  const _InputModalityInherited({
    required ValueNotifier<InputModality> super.notifier,
    required super.child,
  });
}
