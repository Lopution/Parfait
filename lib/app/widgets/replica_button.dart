import 'package:material_ui/material_ui.dart';

import '../theme/func_semantic_tokens.dart';

/// The large pill action of the onboarding and login pages: a brand fill,
/// or [outlined] in the accent for the second of two side-by-side actions.
/// Both take their colours from the theme, so they follow dark mode and
/// system colours.
class ReplicaButton extends StatelessWidget {
  const ReplicaButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.outlined = false,
  });

  final String label;
  final VoidCallback onPressed;
  final bool outlined;

  @override
  Widget build(BuildContext context) {
    const radius = FuncShape.pill;
    final scheme = Theme.of(context).colorScheme;
    final tokens = FuncSemanticTokens.of(context);
    return Material(
      color: outlined ? Colors.transparent : tokens.brand,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: outlined ? BorderSide(color: scheme.primary) : BorderSide.none,
      ),
      child: InkWell(
        borderRadius: radius,
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: FuncSpacing.lg),
          child: Center(
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: outlined ? scheme.primary : tokens.onBrand,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
