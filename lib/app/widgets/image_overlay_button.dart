import 'package:material_ui/material_ui.dart';

import '../theme/func_tokens.dart';

/// Icon-only action floating over artwork (R6). The filled surface is a
/// fixed 55% black so the white glyph keeps >= 4.5:1 contrast even over a
/// pure white image — a tonal or surface-colored button would wash out.
///
/// `tapTargetSize` must stay [MaterialTapTargetSize.padded]: desktop themes
/// default to `shrinkWrap`, which would shrink the hit area to 40dp and
/// fail the 48×48 touch-target contract.
class ImageOverlayButton extends StatelessWidget {
  const ImageOverlayButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final Widget icon;

  /// Required: an icon-only action has no other accessible name.
  final String tooltip;

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: icon,
      tooltip: tooltip,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        backgroundColor: FuncTokens.imageControl,
        foregroundColor: FuncTokens.onImageControl,
        disabledBackgroundColor: FuncTokens.imageControl,
        disabledForegroundColor: FuncTokens.onImageControl.withValues(
          alpha: 0.38,
        ),
        tapTargetSize: MaterialTapTargetSize.padded,
      ),
    );
  }
}
