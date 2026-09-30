import 'package:material_ui/material_ui.dart';
import '../theme/func_semantic_tokens.dart';

/// Shared empty-feed presentation.
///
/// Empty feeds are still actionable: the retry button is the deterministic
/// recovery path, while populated feeds keep the shared pull-to-refresh
/// gesture. Keeping the empty branch out of EasyRefresh prevents a disposed
/// empty list from retaining a ballistic indicator animation.
class ReplicaEmptyState extends StatelessWidget {
  const ReplicaEmptyState({
    super.key,
    required this.message,
    required this.retryLabel,
    required this.onRetry,
    this.icon = Icons.inbox_outlined,
  });

  final String message;
  final String retryLabel;
  final Future<void> Function() onRetry;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(FuncSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48),
            const SizedBox(height: FuncSpacing.md),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: FuncSpacing.md),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: Text(retryLabel),
            ),
          ],
        ),
      ),
    );
  }
}
