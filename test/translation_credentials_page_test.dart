import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parfait/core/translation/translation_service.dart';
import 'package:parfait/core/translation/translation_credentials.dart';
import 'package:parfait/features/settings/pages/translation_credentials_page.dart';

import 'helpers/settings_world.dart';
import 'helpers/localized_app.dart';

/// The shared fake with injectable delete failures; Baidu reads wait on
/// [readBlocker], writes and deletes on [blocker].
class _FakeStore extends FakeTranslationStore {
  /// Thrown by deletes and LLM writes.
  Object? error;
  Completer<void>? readBlocker;
  Completer<void>? blocker;

  // A read returns what was stored when it started.
  @override
  Future<BaiduTranslationCredentials?> readBaidu() async {
    final stored = baidu;
    await readBlocker?.future;
    return stored;
  }

  @override
  Future<LlmTranslationCredentials?> readLlm() async {
    final stored = llm;
    await readBlocker?.future;
    return stored;
  }

  @override
  Future<void> writeBaidu(BaiduTranslationCredentials credentials) async {
    await blocker?.future;
    baidu = credentials;
  }

  @override
  Future<void> writeLlm(LlmTranslationCredentials credentials) async {
    if (error case final error?) throw error;
    llm = credentials;
  }

  @override
  Future<void> deleteBaidu() async {
    await blocker?.future;
    if (error case final error?) throw error;
    baidu = null;
  }

  @override
  Future<void> deleteLlm() async {
    if (error case final error?) throw error;
    llm = null;
  }
}

Widget _app(TranslationCredentialStore store, {bool baidu = true}) {
  return localizedApp(
    overrides: [translationCredentialStoreProvider.overrideWithValue(store)],
    locale: const Locale('en', 'US'),
    home: TranslationCredentialsPage(baidu: baidu),
  );
}

/// The clear action is confirm-gated: page row → dialog → filled
/// "Clear credentials" button. [confirm]=false exercises the cancel branch.
Future<void> _tapClear(WidgetTester tester, {bool confirm = true}) async {
  await tester.tap(find.widgetWithText(ListTile, 'Clear credentials'));
  await tester.pump();
  await tester.pump();
  if (confirm) {
    await tester.tap(find.widgetWithText(FilledButton, 'Clear credentials'));
  } else {
    await tester.tap(find.text('Cancel'));
  }
  await tester.pump();
  await tester.pump();
}

String _fieldText(WidgetTester tester, int index) =>
    tester.widget<TextField>(find.byType(TextField).at(index)).controller!.text;

void main() {
  testWidgets('clear empties the fields and reports success', (tester) async {
    final store = _FakeStore()
      ..baidu = const BaiduTranslationCredentials(appId: 'a', secret: 's');
    await tester.pumpWidget(_app(store));
    await tester.pump();
    // The stored credentials load into the form first.
    expect(_fieldText(tester, 0), 'a');
    expect(_fieldText(tester, 1), 's');

    await _tapClear(tester);

    expect(_fieldText(tester, 0), isEmpty);
    expect(_fieldText(tester, 1), isEmpty);
    expect(store.baidu, isNull);
    expect(find.text('Credentials cleared'), findsOneWidget);
  });

  testWidgets(
    'a store failure keeps the entered values and shows an error status',
    (tester) async {
      final store = _FakeStore()
        ..error = TranslationCredentialsStoreException(
          'delete',
          StateError('denied'),
        );
      await tester.pumpWidget(_app(store));
      await tester.pump();

      await tester.enterText(find.byType(TextField).at(0), 'typed-app-id');
      await tester.enterText(find.byType(TextField).at(1), 'typed-secret');
      await _tapClear(tester);

      // Failed deletes must not eat the user's input.
      expect(_fieldText(tester, 0), 'typed-app-id');
      expect(_fieldText(tester, 1), 'typed-secret');

      // The error colour is the icon's (THEME-08).
      expect(find.text('Secure storage operation failed'), findsOneWidget);
      final icon = tester.widget<Icon>(find.byIcon(Icons.error_outline));
      final scheme = Theme.of(
        tester.element(find.byIcon(Icons.error_outline)),
      ).colorScheme;
      expect(icon.color, scheme.error);
    },
  );

  testWidgets('typing while the store reads or writes stays a draft', (
    tester,
  ) async {
    final store = _FakeStore()
      ..baidu = const BaiduTranslationCredentials(appId: 'a', secret: 's')
      ..readBlocker = Completer<void>();
    await tester.pumpWidget(_app(store));
    bool dirty() => !tester
        .widget<PopScope<Object?>>(find.byWidgetPredicate((w) => w is PopScope))
        .canPop;

    await tester.enterText(find.byType(TextField).at(0), 'typed');
    store.readBlocker!.complete();
    await tester.pump();
    expect([_fieldText(tester, 0), _fieldText(tester, 1)], ['typed', 's']);
    expect(dirty(), isTrue);

    store.blocker = Completer<void>();
    await tester.tap(find.text('Save to secure storage'));
    await tester.pump();
    await tester.enterText(find.byType(TextField).at(1), 'newer');
    store.blocker!.complete();
    await tester.pump();
    expect(store.baidu!.secret, 's');
    expect(dirty(), isTrue, reason: 'the newer secret is not saved');

    // A read that started before a save never fills the form after it. A
    // save the form rejects writes nothing, and one storage refuses is
    // read again, so untouched fields still fill.
    for (final (typed, fails, shown, draft) in [
      (['https://x', 'y'], false, ['https://x', 'y', ''], false),
      (['z', ''], false, ['z', 'k', 'm'], true),
      (['https://x', 'y'], true, ['https://x', 'y', 'm'], true),
    ]) {
      await tester.pumpWidget(const SizedBox());
      store
        ..llm = const LlmTranslationCredentials(
          baseUrl: 'https://a',
          apiKey: 'k',
          model: 'm',
        )
        ..error = fails ? StateError('denied') : null
        ..readBlocker = Completer<void>();
      await tester.pumpWidget(_app(store, baidu: false));
      for (final (i, text) in typed.indexed) {
        await tester.enterText(find.byType(TextField).at(i), text);
      }
      await tester.tap(find.text('Save to secure storage'));
      await tester.pump();
      store.readBlocker!.complete();
      await tester.pump();
      expect([for (var i = 0; i < 3; i++) _fieldText(tester, i)], shown);
      expect(dirty(), draft);
    }
  });

  testWidgets('a dirty draft asks before leaving, a clean one pops', (
    tester,
  ) async {
    final store = _FakeStore();
    await tester.pumpWidget(
      localizedApp(
        overrides: [
          translationCredentialStoreProvider.overrideWithValue(store),
        ],
        locale: const Locale('en', 'US'),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        const TranslationCredentialsPage(baidu: true),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // A clean form pops straight through without a prompt.
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(TranslationCredentialsPage), findsNothing);

    // Dirty: system back opens the discard dialog; Discard leaves.
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), 'draft-app-id');
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Discard unsaved changes?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(TranslationCredentialsPage), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard changes'));
    await tester.pumpAndSettle();
    expect(find.byType(TranslationCredentialsPage), findsNothing);
  });
}
