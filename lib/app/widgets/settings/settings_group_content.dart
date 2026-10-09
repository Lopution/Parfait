import 'package:material_ui/material_ui.dart';

import '../../theme/func_semantic_tokens.dart';
import 'settings_anchor.dart';

/// Non-row content inside a [SettingsGroup]: text fields, choice chips,
/// sliders and buttons sit on the group's surface with the group's own inner
/// padding instead of `ListTile` chrome.
class SettingsGroupContent extends StatelessWidget {
  const SettingsGroupContent({super.key, this.setting, required this.child});

  /// The catalog entry this content is the place of (settings search).
  final SettingsEntry? setting;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return anchorSettingsRow(
      setting,
      Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: FuncSpacing.lg,
          vertical: FuncSpacing.sm,
        ),
        child: child,
      ),
    );
  }
}
