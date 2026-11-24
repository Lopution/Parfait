import 'package:material_ui/material_ui.dart';

import '../../../../app/icons/ui_icons.dart';
import '../../../../app/theme/func_semantic_tokens.dart';
import '../../../../app/theme/func_tokens.dart';
import '../../../../l10n/context.dart';

/// Playback-speed menu button overlaid on `UgoiraViewer` with localized
/// semantics, tooltip, and a 48x48dp interactive target around the visual pill.
class UgoiraSpeedButton extends StatelessWidget {
  const UgoiraSpeedButton({
    super.key,
    required this.speed,
    required this.onSelected,
  });

  final double speed;
  final ValueChanged<double> onSelected;

  String _format(double value) =>
      value == value.roundToDouble() ? '${value.toInt()}x' : '${value}x';

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      menuChildren: [
        for (final option in const [0.5, 1.0, 1.5, 2.0])
          MenuItemButton(
            onPressed: () => onSelected(option),
            leadingIcon: option == speed
                ? const Icon(UiIcons.check, size: 18)
                : const SizedBox(width: 18),
            child: Text(_format(option)),
          ),
      ],
      builder: (context, controller, child) {
        final label = context.l10n.ugoiraPlaybackSpeed;
        final text = _format(speed);
        return Tooltip(
          message: label,
          child: Semantics(
            button: true,
            label: '$label: $text',
            child: InkWell(
              customBorder: const RoundedRectangleBorder(
                borderRadius: FuncShape.control,
              ),
              onTap: () =>
                  controller.isOpen ? controller.close() : controller.open(),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minWidth: kMinInteractiveDimension,
                  minHeight: kMinInteractiveDimension,
                ),
                child: Center(
                  widthFactor: 1,
                  child: DecoratedBox(
                    decoration: const BoxDecoration(
                      color: Color(0x99343838),
                      borderRadius: FuncShape.control,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: FuncSpacing.sm,
                        vertical: FuncSpacing.xs,
                      ),
                      child: ExcludeSemantics(
                        child: Text(
                          text,
                          style: Theme.of(context).textTheme.labelMedium
                              ?.copyWith(color: FuncTokens.white),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
