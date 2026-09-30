import 'package:material_ui/material_ui.dart';
import '../theme/func_semantic_tokens.dart';

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

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: contentPadding,
        child: Row(
          children: [
            Expanded(child: title),
            Switch(value: value, onChanged: (_) => onTap()),
          ],
        ),
      ),
    );
  }
}
