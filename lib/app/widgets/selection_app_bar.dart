import 'package:material_ui/material_ui.dart';

import '../../l10n/context.dart';
import 'app_top_bar.dart';

/// The top bar of a list in selection mode: close on the leading edge,
/// the selection count as the title, batch actions at the end.
///
/// The title is the bare number: next to three actions, an "N selected"
/// sentence does not fit a 320dp screen at large text in every language.
/// Screen readers still hear the full sentence.
AppTopBar selectionAppBar(
  BuildContext context, {
  required int count,
  required VoidCallback onClose,
  required List<Widget> actions,
}) {
  return AppTopBar(
    backgroundColor: Theme.of(context).colorScheme.primaryContainer,
    leading: IconButton(
      tooltip: context.l10n.cancel,
      icon: const Icon(Icons.close),
      onPressed: onClose,
    ),
    title: Text('$count', semanticsLabel: context.l10n.selectedCount(count)),
    actions: actions,
  );
}
