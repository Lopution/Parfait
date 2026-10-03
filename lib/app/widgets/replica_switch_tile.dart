import 'package:material_ui/material_ui.dart';
import '../theme/func_semantic_tokens.dart';
import '../haptics/app_haptics.dart';

/// Whole-row switch. Owns the toggle haptic for both the row and the
/// switch itself.
class ReplicaSwitchTile extends StatelessWidget {
  const ReplicaSwitchTile({
    super.key,
    required this.value,
    required this.title,
    required this.onTap,
    this.contentPadding = const EdgeInsets.symmetric(
      horizontal: FuncSpacing.lg,
      vertical: FuncSpacing.sm,
    ),
  });

  final bool value;
  final Widget title;
  final VoidCallback onTap;
  final EdgeInsetsGeometry contentPadding;

  void _toggle() {
    value ? AppHaptics.toggleOff() : AppHaptics.toggleOn();
    onTap();
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: _toggle,
      child: Padding(
        padding: contentPadding,
        child: Row(
          children: [
            Expanded(child: title),
            Switch(value: value, onChanged: (_) => _toggle()),
          ],
        ),
      ),
    );
  }
}
