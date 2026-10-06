import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/widgets/prompt_host.dart';
import 'package:parfait/core/platform/accessibility.dart';

/// `MaterialApp.builder` that installs the prompt host the way app.dart
/// does. The platform timeout channel is the external boundary: the no-op
/// driver keeps every prompt at its base duration.
Widget promptHostBuilder(BuildContext context, Widget? child) =>
    PromptHost(accessibility: const NoopAppAccessibility(), child: child!);

/// The prompt on screen.
Finder get shownPrompt => find.byKey(PromptHost.promptKey);

/// The prompt's action button.
Finder promptAction(String label) => find.widgetWithText(TextButton, label);

/// The card of the prompt showing [message].
Finder promptCard(String message) => find
    .ancestor(of: find.text(message), matching: find.byType(Material))
    .first;
