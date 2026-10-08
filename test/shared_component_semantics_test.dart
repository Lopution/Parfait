import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:parfait/app/widgets/app_snack_bar.dart';
import 'package:parfait/l10n/app_localizations.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';
import 'helpers/prompt_host.dart';

Widget _host(Widget child) {
  return ProviderScope(
    child: MaterialApp(
      builder: promptHostBuilder,
      localizationsDelegates: appLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  testWidgets('app snackbars are exposed as live regions', (tester) async {
    await tester.pumpWidget(
      _host(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showAppSnackBar(context, 'Saved'),
            child: const Text('Show'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Show'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.bySemanticsLabel('Saved'), findsOneWidget);
    expect(
      tester.getSemantics(find.bySemanticsLabel('Saved')),
      isSemantics(label: 'Saved', isLiveRegion: true),
    );
  });
}
