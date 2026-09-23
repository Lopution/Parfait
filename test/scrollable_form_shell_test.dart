import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pixiv_func/app/layout/content_widths.dart';
import 'package:pixiv_func/app/theme/replica_theme.dart';
import 'package:pixiv_func/app/widgets/scrollable_form_shell.dart';

/// The acceptance matrix from the ui-consistency gate: narrowest realistic
/// portrait, a common phone, both breakpoints, an expanded desktop window
/// and a short landscape viewport.
const _viewports = [
  Size(320, 568),
  Size(390, 844),
  Size(600, 960),
  Size(840, 1180),
  Size(1200, 800),
  Size(640, 320), // landscape / short height
];

Widget _shell({double? contentMaxWidth}) {
  return ScrollableFormShell(
    contentMaxWidth: contentMaxWidth ?? ContentWidths.form,
    header: const Text(
      'Choose a thing',
      textAlign: TextAlign.center,
      style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
    ),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < 4; i++) ...[
          SizedBox(height: 52, child: Center(child: Text('Option $i'))),
          const Divider(),
        ],
      ],
    ),
    primaryAction: FilledButton(
      onPressed: () {},
      child: const Text('Continue'),
    ),
    secondary: TextButton(onPressed: () {}, child: const Text('Set up later')),
  );
}

Widget _wrap({required Widget child, double textScale = 1}) {
  return MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
    child: MaterialApp(theme: replicaTheme(Brightness.light), home: child),
  );
}

void main() {
  for (final scale in const [1.0, 1.3]) {
    for (final size in _viewports) {
      testWidgets('shell keeps the primary action reachable at '
          '${size.width}x${size.height} @${scale}x', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(_wrap(child: _shell(), textScale: scale));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'no overflow');

        // On short viewports the action sits below the fold; reachability
        // means a scroll brings it fully on screen and it stays tappable.
        final label = find.text('Continue');
        await tester.ensureVisible(label);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        final action = tester.getRect(find.byType(FilledButton));
        expect(action.bottom, lessThanOrEqualTo(size.height));
        expect(action.top, greaterThanOrEqualTo(0));
        // The column never exceeds the role width cap.
        expect(action.width, lessThanOrEqualTo(ContentWidths.form));
      });
    }
  }

  testWidgets('content column is capped and centered on wide viewports', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_wrap(child: _shell()));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final action = tester.getRect(find.byType(FilledButton));
    expect(action.width, ContentWidths.form);
    // Centered: symmetric side margins on the capped column.
    expect(action.left, closeTo((1200 - ContentWidths.form) / 2, 1));
  });

  testWidgets('a custom role width is honored', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _wrap(child: _shell(contentMaxWidth: ContentWidths.article)),
    );
    await tester.pumpAndSettle();

    final action = tester.getRect(find.byType(FilledButton));
    expect(action.width, ContentWidths.article);
  });
}
