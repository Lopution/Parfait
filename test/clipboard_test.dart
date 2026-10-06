import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:parfait/app/clipboard.dart';
import 'package:parfait/app/haptics/haptics_driver.dart';

import 'helpers/recording_haptics.dart';
import 'helpers/prompt_host.dart';

/// Platform clipboard stand-in; [fail] makes the write throw.
List<String> _mockClipboard({bool fail = false}) {
  final written = <String>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') {
      if (fail) throw PlatformException(code: 'clipboard_unavailable');
      written.add((call.arguments as Map)['text'] as String);
    }
    return null;
  });
  addTearDown(
    () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
  );
  return written;
}

Future<BuildContext> _pumpHost(WidgetTester tester) async {
  late BuildContext context;
  await tester.pumpWidget(
    MaterialApp(
      builder: promptHostBuilder,
      home: Scaffold(
        body: Builder(
          builder: (c) {
            context = c;
            return const SizedBox();
          },
        ),
      ),
    ),
  );
  return context;
}

void main() {
  testWidgets('copies, confirms with the success haptic and a toast', (
    tester,
  ) async {
    final haptics = recordHaptics();
    final written = _mockClipboard();
    final context = await _pumpHost(tester);

    await copyToClipboard(context, 'pixiv.net', message: 'Copied');
    await tester.pump();

    expect(written, ['pixiv.net']);
    expect(haptics.roles, [HapticRole.success]);
    expect(find.text('Copied'), findsOneWidget);
  });

  testWidgets('a failed write claims nothing', (tester) async {
    final haptics = recordHaptics();
    _mockClipboard(fail: true);
    final context = await _pumpHost(tester);

    await expectLater(
      copyToClipboard(context, 'pixiv.net', message: 'Copied'),
      throwsA(isA<PlatformException>()),
    );
    await tester.pump();

    expect(haptics.played, isEmpty);
    expect(find.text('Copied'), findsNothing);
  });
}
