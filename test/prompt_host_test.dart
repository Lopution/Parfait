import 'dart:async';

import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:parfait/app/motion/app_overlays.dart';
import 'package:parfait/app/widgets/app_snack_bar.dart';

import 'helpers/localized_app.dart';
import 'helpers/prompt_host.dart';

Widget _app({required Widget home}) => ProviderScope(
  child: localizedApp(builder: promptHostBuilder, home: home),
);

class _Buttons extends StatelessWidget {
  const _Buttons(this.buttons);

  final Map<String, void Function(BuildContext context)> buttons;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        const SizedBox(height: 80),
        for (final MapEntry(:key, :value) in buttons.entries)
          Builder(
            builder: (context) =>
                TextButton(onPressed: () => value(context), child: Text(key)),
          ),
      ],
    ),
  );
}

double _opacity(WidgetTester tester, String message) {
  var opacity = 1.0;
  for (final fade in tester.widgetList<FadeTransition>(
    find.ancestor(
      of: promptCard(message),
      matching: find.byType(FadeTransition),
    ),
  )) {
    opacity *= fade.opacity.value;
  }
  return opacity;
}

void main() {
  testWidgets('a new prompt replaces the current one and drops the queue', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        home: _Buttons({
          'old': (c) =>
              showAppSnackBar(c, '旧提示', duration: const Duration(seconds: 30)),
          'queue': (c) => showAppSnackBar(c, '排队提示', replaceCurrent: false),
          'latest': (c) => showAppSnackBar(c, '最新提示'),
        }),
      ),
    );
    await tester.tap(find.text('old'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('queue'));
    await tester.pump();
    expect(find.text('旧提示'), findsOneWidget);
    expect(find.text('排队提示'), findsNothing);

    await tester.tap(find.text('latest'));
    await tester.pumpAndSettle();
    expect(find.text('旧提示'), findsNothing);
    expect(find.text('排队提示'), findsNothing);
    expect(find.text('最新提示'), findsOneWidget);
  });

  testWidgets('the action fires once and hides the prompt', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _app(
        home: _Buttons({
          'show': (c) => showAppSnackBar(
            c,
            '提示',
            action: PromptAction(label: '打开', onPressed: () => taps++),
          ),
        }),
      ),
    );
    await tester.tap(find.text('show'));
    await tester.pumpAndSettle();
    await tester.tap(promptAction('打开'));
    await tester.pump();
    await tester.tap(promptAction('打开'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(taps, 1);
    expect(find.text('提示'), findsNothing);
  });

  testWidgets('announces as a live region and dismisses from semantics', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(
        home: _Buttons({
          'show': (c) =>
              showAppSnackBar(c, '提示', duration: const Duration(seconds: 30)),
        }),
      ),
    );
    await tester.tap(find.text('show'));
    await tester.pumpAndSettle();
    expect(
      tester.getSemantics(find.text('提示')),
      isSemantics(label: '提示', isLiveRegion: true, hasDismissAction: true),
    );

    tester.semantics.performAction(
      find.semantics.byLabel('提示'),
      SemanticsAction.dismiss,
    );
    await tester.pumpAndSettle();
    expect(find.text('提示'), findsNothing);
    handle.dispose();
  });

  testWidgets('a sheet or dialog covers the prompt and takes its taps', (
    tester,
  ) async {
    var tapped = false;
    await tester.pumpWidget(
      _app(
        home: _Buttons({
          'show': (c) => showAppSnackBar(
            c,
            '提示',
            duration: const Duration(seconds: 30),
            action: PromptAction(label: '打开', onPressed: () => tapped = true),
          ),
          'sheet': (c) => unawaited(
            showAppBottomSheet<void>(
              context: c,
              builder: (_) => const SizedBox(height: 120),
            ),
          ),
          'dialog': (c) => unawaited(
            showAppDialog<void>(
              context: c,
              builder: (_) => const AlertDialog(content: Text('对话框')),
            ),
          ),
        }),
      ),
    );
    await tester.tap(find.text('show'));
    await tester.pumpAndSettle();
    final action = tester.getCenter(promptAction('打开'));

    for (final modal in ['sheet', 'dialog']) {
      await tester.tap(find.text(modal));
      await tester.pumpAndSettle();
      expect(_opacity(tester, '提示'), 0, reason: modal);
      await tester.tapAt(action);
      await tester.pumpAndSettle();
      expect(tapped, isFalse, reason: modal);
      if (modal == 'sheet') {
        expect(_opacity(tester, '提示'), 0, reason: modal);
        await tester.tapAt(const Offset(200, 120));
        await tester.pumpAndSettle();
      }
      expect(_opacity(tester, '提示'), 1, reason: modal);
    }
  });

  testWidgets(
    'a prompt shown after a modal opens stays visible and clickable until a newer modal covers it',
    (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        _app(
          home: _Buttons({
            'sheet': (c) => unawaited(
              showAppBottomSheet<void>(
                context: c,
                builder: (s) => SizedBox(
                  height: 260,
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextButton(
                          onPressed: () => showAppSnackBar(
                            s,
                            '内层提示',
                            duration: const Duration(seconds: 30),
                            action: PromptAction(
                              label: '重试',
                              onPressed: () => tapped = true,
                            ),
                          ),
                          child: const Text('toast'),
                        ),
                        TextButton(
                          onPressed: () => unawaited(
                            showAppDialog<void>(
                              context: s,
                              builder: (_) =>
                                  const AlertDialog(content: Text('二层弹窗')),
                            ),
                          ),
                          child: const Text('dialog2'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          }),
        ),
      );
      await tester.tap(find.text('sheet'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('toast'));
      await tester.pumpAndSettle();
      expect(_opacity(tester, '内层提示'), 1);

      await tester.tap(find.text('dialog2'));
      await tester.pumpAndSettle();
      expect(_opacity(tester, '内层提示'), 0);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(_opacity(tester, '内层提示'), 1);

      await tester.tap(promptAction('重试'));
      await tester.pumpAndSettle();
      expect(tapped, isTrue);
    },
  );
}
