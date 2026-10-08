import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:parfait/app/widgets/errors/error_details.dart';
import 'package:parfait/core/errors/error_category.dart';
import 'package:parfait/core/logging/crash_log.dart';
import 'package:parfait/l10n/app_localizations.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';
import 'package:parfait/l10n/context.dart';
import 'helpers/prompt_host.dart';

Widget _host(Widget child) {
  return MaterialApp(
    builder: promptHostBuilder,
    localizationsDelegates: appLocalizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('zh', 'CN'),
    home: Scaffold(body: Center(child: child)),
  );
}

void _mockClipboard(Map<String, String> store) {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') {
      store['text'] = (call.arguments as Map)['text'] as String;
    }
    return null;
  });
  addTearDown(
    () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
  );
}

void main() {
  group('ErrorDetails', () {
    testWidgets('expands to the raw text and flips the expanded flag', (
      tester,
    ) async {
      await tester.pumpWidget(_host(ErrorDetails(error: StateError('boom'))));
      await tester.tap(find.widgetWithText(TextButton, '详情'));
      await tester.pump();

      expect(find.text('Bad state: boom'), findsOneWidget);
      expect(
        tester.getSemantics(find.widgetWithText(TextButton, '详情')),
        isSemantics(hasExpandedState: true, isExpanded: true),
      );

      await tester.tap(find.widgetWithText(TextButton, '详情'));
      await tester.pump();
      expect(find.byType(SelectableText), findsNothing);
    });

    testWidgets('copy puts the text on the clipboard and confirms', (
      tester,
    ) async {
      final clipboard = <String, String>{};
      _mockClipboard(clipboard);
      await tester.pumpWidget(_host(ErrorDetails(error: StateError('boom'))));
      await tester.tap(find.widgetWithText(TextButton, '详情'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '复制'));
      await tester.pump();

      expect(clipboard['text'], 'Bad state: boom');
      expect(find.text('已复制'), findsOneWidget);
    });
  });

  group('errorCategoryText', () {
    testWidgets('maps every category to a localized sentence', (tester) async {
      final seen = <ErrorCategory, String>{};
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) {
              for (final category in ErrorCategory.values) {
                seen[category] = errorCategoryText(context, category);
              }
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      expect(seen.length, ErrorCategory.values.length);
      expect(seen[ErrorCategory.network], '网络连接失败');
      expect(seen[ErrorCategory.timeout], '连接超时');
      expect(seen[ErrorCategory.unauthorized], '需要重新登录');
      expect(seen[ErrorCategory.unknown], '未知错误');
      expect(seen.values.every((text) => text.isNotEmpty), isTrue);
    });
  });

  group('showErrorSnackBar', () {
    late Directory dir;
    late File file;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('error_snackbar_test');
      file = File('${dir.path}/crash.log');
      CrashLog.useFile(file);
    });

    tearDown(() {
      CrashLog.useFile(null);
      dir.deleteSync(recursive: true);
    });

    testWidgets('shows action + category and records the raw error', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showErrorSnackBar(
                context,
                action: context.l10n.historyLoadFailed,
                error: const SocketException('connection reset'),
              ),
              child: const Text('go'),
            ),
          ),
        ),
      );
      // dart:io continuations parked in the fake-async zone are never
      // resumed, so fire the handler — and with it the CrashLog write chain —
      // on the real event loop.
      final button = tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'go'),
      );
      await tester.runAsync(() async {
        button.onPressed!();
        await CrashLog.pending;
      });
      final content = file.readAsStringSync();
      expect(content, contains('SocketException'));
      expect(content, contains('connection reset'));

      await tester.pump();
      expect(find.text('历史记录加载失败：网络连接失败'), findsOneWidget);
      expect(
        find.textContaining('connection reset'),
        findsNothing,
        reason: 'the snackbar never prints raw exception text',
      );
    });
  });
}
