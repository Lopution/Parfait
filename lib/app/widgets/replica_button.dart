import 'package:material_ui/material_ui.dart';

import '../theme/func_semantic_tokens.dart';

class ReplicaButton extends StatelessWidget {
  const ReplicaButton({
    super.key,
    required this.label,
    required this.onPressed,
    required this.backgroundColor,
    required this.foregroundColor,
    this.borderColor,
  });

  final String label;
  final VoidCallback onPressed;
  final Color backgroundColor;
  final Color foregroundColor;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    const radius = FuncShape.pill;
    return Material(
      color: backgroundColor,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: borderColor == null
            ? BorderSide.none
            : BorderSide(color: borderColor!),
      ),
      child: InkWell(
        borderRadius: radius,
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: FuncSpacing.lg),
          child: Center(
            child: Text(
              label,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: foregroundColor,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
