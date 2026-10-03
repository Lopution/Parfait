import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'haptics/app_haptics.dart';
import 'widgets/app_snack_bar.dart';

/// The UI's only clipboard write: copies [text], confirms with the success
/// haptic and shows [message]. A failed write throws before either, so the
/// user is never told a copy landed when it did not.
Future<void> copyToClipboard(
  BuildContext context,
  String text, {
  required String message,
}) async {
  await Clipboard.setData(ClipboardData(text: text));
  AppHaptics.success();
  if (context.mounted) showAppSnackBar(context, message);
}
