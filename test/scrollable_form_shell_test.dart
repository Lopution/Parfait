import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parfait/app/layout/content_widths.dart';
import 'package:parfait/app/theme/replica_theme.dart';
import 'package:parfait/app/widgets/scrollable_form_shell.dart';
import 'helpers/view_size.dart';

/// The acceptance matrix from the ui-consistency gate: narrowest realistic
/// portrait, a common phone, both breakpoints, an expanded desktop window
/// and a short landscape viewport.
const _viewports = [
  Size(320, 568),
  Size(360, 374), // folded cover screen: shortest realistic window
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

Widget _wrap({
  required Widget child,
  double textScale = 1,
  EdgeInsets padding = EdgeInsets.zero,
  EdgeInsets viewInsets = EdgeInsets.zero,
}) {
  return MediaQuery(
    data: MediaQueryData(
      textScaler: TextScaler.linear(textScale),
      padding: padding,
      viewInsets: viewInsets,
    ),
    child: MaterialApp(theme: replicaTheme(Brightness.light), home: child),
  );
}

void main() {
  for (final scale in const [1.0, 1.3]) {
    for (final size in _viewports) {
      testWidgets('shell keeps the primary action reachable at '
          '${size.width}x${size.height} @${scale}x', (tester) async {
        setViewSize(tester, size);

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

  // The body constraints subtract the bottom inset from the maximum; the
  // minimum must yield it too, or a short window with a system bar (a
  // folded cover screen) or an open keyboard makes minHeight exceed
  // maxHeight and BoxConstraints asserts.
  const insetCases = [
    (
      'folded cover screen with a system bar',
      Size(360, 374),
      EdgeInsets.only(bottom: 24),
      EdgeInsets.zero,
    ),
    (
      'phone with a system bar',
      Size(411, 896),
      EdgeInsets.only(bottom: 16),
      EdgeInsets.zero,
    ),
    (
      'phone with the keyboard up',
      Size(411, 896),
      EdgeInsets.zero,
      EdgeInsets.only(bottom: 300),
    ),
    (
      'landscape phone with both',
      Size(896, 411),
      EdgeInsets.only(bottom: 16),
      EdgeInsets.only(bottom: 200),
    ),
  ];
  for (final (reason, size, padding, viewInsets) in insetCases) {
    testWidgets('insets keep the constraints valid: $reason', (tester) async {
      setViewSize(tester, size);
      await tester.pumpWidget(
        _wrap(child: _shell(), padding: padding, viewInsets: viewInsets),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: reason);
    });
  }
}
