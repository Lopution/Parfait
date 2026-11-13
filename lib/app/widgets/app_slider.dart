import 'package:material_ui/material_ui.dart';

import '../haptics/app_haptics.dart';

/// The app's only [Slider]. With [divisions] every step the user moves the
/// thumb across plays one tick haptic (AppHaptics throttles a fast fling).
/// A continuous slider stays silent: without steps there is nothing
/// discrete to confirm, and per-frame vibration would be noise.
///
/// Defaults [canRequestFocus] to `false` so pointer drags (such as the viewer's
/// page scrubber) never steal focus away from keyboard shortcuts (`ArrowLeft` /
/// `ArrowRight`). Pass [canRequestFocus]: `true`, [autofocus]: `true`, or an
/// explicit [focusNode] when keyboard focus is desired.
class AppSlider extends StatefulWidget {
  const AppSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 1,
    this.divisions,
    this.label,
    this.onChangeEnd,
    this.focusNode,
    this.autofocus = false,
    this.canRequestFocus = false,
  });

  final double value;
  final ValueChanged<double>? onChanged;
  final double min;
  final double max;
  final int? divisions;
  final String? label;
  final ValueChanged<double>? onChangeEnd;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool canRequestFocus;

  @override
  State<AppSlider> createState() => _AppSliderState();
}

class _AppSliderState extends State<AppSlider> {
  FocusNode? _ownFocusNode;

  bool get _allowFocus => widget.canRequestFocus || widget.autofocus;

  FocusNode get _effectiveFocusNode {
    if (widget.focusNode != null) return widget.focusNode!;
    return _ownFocusNode ??= FocusNode(
      debugLabel: 'AppSlider',
      canRequestFocus: _allowFocus,
      skipTraversal: !_allowFocus,
    );
  }

  @override
  void didUpdateWidget(AppSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focusNode != null && _ownFocusNode != null) {
      _ownFocusNode!.dispose();
      _ownFocusNode = null;
    } else if (widget.focusNode == null && _ownFocusNode != null) {
      _ownFocusNode!
        ..canRequestFocus = _allowFocus
        ..skipTraversal = !_allowFocus;
    }
  }

  @override
  void dispose() {
    _ownFocusNode?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final onChanged = widget.onChanged;
    return Slider(
      value: widget.value,
      min: widget.min,
      max: widget.max,
      divisions: widget.divisions,
      label: widget.label,
      onChangeEnd: widget.onChangeEnd,
      focusNode: _effectiveFocusNode,
      autofocus: widget.autofocus,
      onChanged: onChanged == null
          ? null
          : (next) {
              if (widget.divisions != null && next != widget.value) {
                AppHaptics.tick();
              }
              onChanged(next);
            },
    );
  }
}
