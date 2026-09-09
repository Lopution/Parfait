import 'package:material_ui/material_ui.dart';

class SettingsSection extends StatelessWidget {
  const SettingsSection({super.key, required this.title});

  final Widget title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: DefaultTextStyle.merge(
        style: TextStyle(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
        child: title,
      ),
    );
  }
}
