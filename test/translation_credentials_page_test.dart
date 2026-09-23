import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pixiv_func/core/comments/comment_translation.dart';
import 'package:pixiv_func/core/comments/translation_credentials.dart';
import 'package:pixiv_func/features/settings/pages/translation_credentials_page.dart';
import 'package:pixiv_func/l10n/app_localizations.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';

class _FakeStore implements TranslationCredentialStore {
  BaiduTranslationCredentials? baidu;
  LlmTranslationCredentials? llm;
  Object? deleteError;
  Completer<void>? deleteBlocker;

  @override
  Future<BaiduTranslationCredentials?> readBaidu() async => baidu;

  @override
  Future<void> writeBaidu(BaiduTranslationCredentials credentials) async {
    baidu = credentials;
  }

  @override
  Future<LlmTranslationCredentials?> readLlm() async => llm;

  @override
  Future<void> writeLlm(LlmTranslationCredentials credentials) async {
    llm = credentials;
  }

  @override
  Future<bool> hasBaidu() async => baidu != null;

  @override
  Future<bool> hasLlm() async => llm != null;

  @override
  Future<void> deleteBaidu() async {
    await deleteBlocker?.future;
    final error = deleteError;
    if (error != null) throw error;
    baidu = null;
  }

  @override
  Future<void> deleteLlm() async {
    await deleteBlocker?.future;
    final error = deleteError;
    if (error != null) throw error;
    llm = null;
  }

  @override
  Future<void> deleteAll() async {
    baidu = null;
    llm = null;
  }
}

Widget _app(TranslationCredentialStore store, {bool baidu = true}) {
  return ProviderScope(
    overrides: [translationCredentialStoreProvider.overrideWithValue(store)],
    child: MaterialApp(
      localizationsDelegates: appLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en', 'US'),
      home: TranslationCredentialsPage(baidu: baidu),
    ),
  );
}

/// The clear action is confirm-gated: page button → dialog → filled
/// "Clear credentials" button. [confirm]=false exercises the cancel branch.
Future<void> _tapClear(WidgetTester tester, {bool confirm = true}) async {
  await tester.tap(find.widgetWithText(OutlinedButton, 'Clear credentials'));
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
        ..deleteError = TranslationCredentialsStoreException(
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

      final status = tester.widget<Text>(
        find.text('Secure storage operation failed'),
      );
      final scheme = Theme.of(
        tester.element(find.text('Secure storage operation failed')),
      ).colorScheme;
      expect(status.style?.color, scheme.error);
    },
  );

  testWidgets('clearing disables the actions and spins the clear button', (
    tester,
  ) async {
    final store = _FakeStore()..deleteBlocker = Completer<void>();
    await tester.pumpWidget(_app(store));
    await tester.pump();

    await tester.tap(find.widgetWithText(OutlinedButton, 'Clear credentials'));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Clear credentials'));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    final clear = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Clear credentials'),
    );
    final save = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Save to secure storage'),
    );
    expect(clear.onPressed, isNull);
    expect(save.onPressed, isNull);

    store.deleteBlocker!.complete();
    await tester.pump();
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Credentials cleared'), findsOneWidget);
  });

  testWidgets('a dirty draft asks before leaving, a clean one pops', (
    tester,
  ) async {
    final store = _FakeStore();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          translationCredentialStoreProvider.overrideWithValue(store),
        ],
        child: MaterialApp(
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
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

  testWidgets('cancelling the confirm keeps credentials and fields', (
    tester,
  ) async {
    final store = _FakeStore()
      ..baidu = const BaiduTranslationCredentials(appId: 'a', secret: 's');
    await tester.pumpWidget(_app(store));
    await tester.pump();

    await _tapClear(tester, confirm: false);

    expect(store.baidu, isNotNull);
    expect(_fieldText(tester, 0), 'a');
    expect(_fieldText(tester, 1), 's');
    expect(find.text('Credentials cleared'), findsNothing);
  });
}
