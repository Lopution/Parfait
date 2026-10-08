import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/theme/func_semantic_tokens.dart';
import 'package:parfait/core/auth/account_store.dart';
import 'package:parfait/core/comments/comment_translation.dart';
import 'package:parfait/core/comments/translation_credentials.dart';
import 'package:parfait/core/entity/comment_entity.dart';
import 'package:parfait/core/entity/illust_entity.dart';
import 'package:parfait/core/entity/illust_store.dart';
import 'package:parfait/core/settings/app_settings.dart';
import 'package:parfait/features/comments/comment_item.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';

import 'helpers/comment_world.dart';

/// The Google transport stands in for the network; the rest of the
/// translation service runs as shipped.
class _PendingTransport implements CommentTranslationTransport {
  final completer = Completer<String>();
  int calls = 0;

  @override
  Future<String> translate(String text, {required String targetLanguage}) {
    calls++;
    return completer.future;
  }
}

/// Google needs no credentials; any read means the wrong path ran.
class _NoCredentials implements TranslationCredentialStore {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  late _PendingTransport transport;
  var replies = 0;
  var openedReplies = 0;
  var deletes = 0;

  setUp(() {
    replies = 0;
    openedReplies = 0;
    deletes = 0;
  });

  Future<void> pumpItem(
    WidgetTester tester,
    CommentEntity comment, {
    IllustEntity? work,
  }) async {
    // Created inside the test's fake-async zone, or completing it would
    // never reach the widget.
    transport = _PendingTransport();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountStoreProvider.overrideWith(commentsAccountStore),
          if (work != null)
            illustStoreProvider.overrideWithValue(
              IllustStore()..mergeAll([work]),
            ),
          commentTranslationServiceProvider.overrideWithValue(
            ConfiguredCommentTranslationService(
              resolveProvider: () => TranslationProvider.google,
              store: _NoCredentials(),
              google: transport,
              baidu: transport,
              llm: transport,
            ),
          ),
        ],
        child: MaterialApp(
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN')],
          localizationsDelegates: appLocalizationsDelegates,
          home: Scaffold(
            body: CommentItem(
              comment: comment,
              onReply: () => replies++,
              onOpenReplies: () => openedReplies++,
              onDelete: () => deletes++,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  final moreActions = find.byTooltip('更多操作');

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(moreActions);
    // Not pumpAndSettle: a running translation keeps its spinner turning.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  Finder menuItem(String label) => find.widgetWithText(MenuItemButton, label);

  testWidgets('own comment: the menu translates and deletes in danger color', (
    tester,
  ) async {
    await pumpItem(tester, sampleComment(40));
    await openMenu(tester);

    expect(menuItem('翻译'), findsOneWidget);
    final delete = menuItem('删除评论');
    expect(delete, findsOneWidget);
    final danger = FuncSemanticTokens.of(
      tester.element(find.byType(CommentItem)),
    ).danger;
    final label = tester.widget<Text>(
      find.descendant(of: delete, matching: find.text('删除评论')),
    );
    expect(
      DefaultTextStyle.of(tester.element(find.byWidget(label))).style.color,
      danger,
    );

    // The page confirms before deleting; the item only reports the choice.
    await tester.tap(delete);
    await tester.pumpAndSettle();
    expect(deletes, 1);
  });

  testWidgets('another user\'s comment: the menu only translates', (
    tester,
  ) async {
    await pumpItem(tester, sampleComment(40, userId: 20));
    await openMenu(tester);

    expect(menuItem('翻译'), findsOneWidget);
    expect(menuItem('删除评论'), findsNothing);
  });

  testWidgets('translate is disabled while a translation runs', (tester) async {
    await pumpItem(tester, sampleComment(40, userId: 20));
    await openMenu(tester);
    await tester.tap(menuItem('翻译'));
    // Let the menu finish closing before it is opened again.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(transport.calls, 1);

    await openMenu(tester);
    expect(tester.widget<MenuItemButton>(menuItem('翻译')).onPressed, isNull);

    transport.completer.complete('你好');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('你好'), findsOneWidget);
  });
}
