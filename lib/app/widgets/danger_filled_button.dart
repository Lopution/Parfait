import 'package:material_ui/material_ui.dart';

/// The confirm of a dialog whose action cannot be undone (removing an
/// account, deleting a comment or a file): a filled button in the error
/// colours, so the irreversible choice does not wear the accent of an
/// ordinary one (THEME-07).
class DangerFilledButton extends StatelessWidget {
  const DangerFilledButton({
    super.key,
    required this.onPressed,
    required this.child,
  });

  final VoidCallback? onPressed;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return FilledButton(
      style: FilledButton.styleFrom(
        backgroundColor: colorScheme.error,
        foregroundColor: colorScheme.onError,
      ),
      onPressed: onPressed,
      child: child,
    );
  }
}
