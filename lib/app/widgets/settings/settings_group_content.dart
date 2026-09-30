import 'package:material_ui/material_ui.dart';

import '../../theme/func_semantic_tokens.dart';

/// Non-row content inside a [SettingsGroup]: text fields, segmented buttons,
/// sliders and buttons sit on the group's surface with the group's own inner
/// padding instead of `ListTile` chrome.
class SettingsGroupContent extends StatelessWidget {
  const SettingsGroupContent({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: FuncSpacing.lg,
        vertical: FuncSpacing.sm,
      ),
      child: child,
    );
  }
}
