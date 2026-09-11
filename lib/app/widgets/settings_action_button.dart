import 'package:material_ui/material_ui.dart';

import '../../l10n/context.dart';
import '../navigation/routes.dart';

/// Shared settings entry injected into the AppBar actions of every primary
/// content tab. App settings are an app-level flow on the root navigator —
/// not a personal-content destination — so the gear is the discoverable path
/// on narrow layouts (the wide rail shows its own peer entry).
class SettingsActionButton extends StatelessWidget {
  const SettingsActionButton({super.key});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: context.l10n.settingsTitle,
      icon: const Icon(Icons.settings_outlined),
      onPressed: () => openSettings(context),
    );
  }
}
