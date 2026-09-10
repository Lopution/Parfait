import 'package:material_ui/material_ui.dart';

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
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
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
