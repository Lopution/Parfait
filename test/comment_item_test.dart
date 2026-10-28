import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/format/app_format.dart';
import 'package:parfait/app/theme/func_semantic_tokens.dart';
import 'package:parfait/core/auth/account_store.dart';
import 'package:parfait/core/translation/translation_service.dart';
import 'package:parfait/core/entity/comment_entity.dart';
import 'package:parfait/core/entity/illust_entity.dart';
import 'package:parfait/core/entity/illust_store.dart';
import 'package:parfait/core/settings/app_settings.dart';
import 'package:parfait/features/comments/comment_item.dart';

import 'helpers/comment_world.dart';
import 'helpers/localized_app.dart';

/// The Google transport stands in for the network; the rest of the
/// translation service runs as shipped.
class _PendingTransport
    with SequentialBatchTranslation
    implements TranslationTransport {
  final completer = Completer<String>();
  int calls = 0;

  @override
  Future<String> translate(String text, {required String targetLanguage}) {
    calls++;
    return completer.future;
  }
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
      localizedApp(
        overrides: [
          accountStoreProvider.overrideWith(commentsAccountStore),
          if (work != null)
            illustStoreProvider.overrideWithValue(
              IllustStore()..mergeAll([work]),
            ),
          translationServiceProvider.overrideWithValue(
            ConfiguredTranslationService(
              resolveProvider: () => TranslationProvider.google,
              google: transport,
              baidu: transport,
              llm: transport,
              doubao: transport,
            ),
          ),
        ],
        body: CommentItem(
          comment: comment,
          onReply: () => replies++,
          onOpenReplies: () => openedReplies++,
          onDelete: () => deletes++,
        ),
      ),
    );
    await tester.pump();
  }

  final moreActions = find.byTooltip('更多操作');
  final translate = find.widgetWithText(TextButton, '翻译');

  Finder menuItem(String label) => find.widgetWithText(MenuItemButton, label);

  testWidgets('own comment: the ⋮ only deletes, in danger color', (
    tester,
  ) async {
    await pumpItem(tester, sampleComment(40));
    expect(translate, findsOneWidget);
    // The ⋮ sits in the pill row: the date still ends on the row's edge.
    final item = find.byType(CommentItem);
    final date = AppFormat.relative(
      tester.element(item),
      DateTime.utc(2026, 8, 27),
    );
    expect(
      tester.getTopRight(find.text(date)).dx,
      tester.getTopRight(item).dx - FuncSpacing.lg,
    );

    await tester.tap(moreActions);
    await tester.pumpAndSettle();
    expect(menuItem('翻译'), findsNothing);
    final delete = menuItem('删除评论');
    final label = tester.widget<Text>(
      find.descendant(of: delete, matching: find.text('删除评论')),
    );
    expect(
      DefaultTextStyle.of(tester.element(find.byWidget(label))).style.color,
      FuncSemanticTokens.of(tester.element(item)).danger,
    );

    // The page confirms before deleting; the item only reports the choice.
    await tester.tap(delete);
    await tester.pumpAndSettle();
    expect(deletes, 1);
  });

  testWidgets("another user's comment has no ⋮", (tester) async {
    await pumpItem(tester, sampleComment(40, userId: 20));

    expect(moreActions, findsNothing);
    expect(translate, findsOneWidget);
    // The avatar opens the profile with a ripple shaped like it.
    expect(
      find.byWidgetPredicate(
        (w) => w is InkResponse && w.customBorder is CircleBorder,
      ),
      findsOneWidget,
    );
  });

  testWidgets('deleted author uses a localized placeholder', (tester) async {
    await pumpItem(tester, sampleComment(40, userId: 0, userName: ''));

    expect(find.text('已注销用户'), findsOneWidget);
    expect(find.text('user 0'), findsNothing);
  });

  testWidgets('translate is disabled while a translation runs', (tester) async {
    await pumpItem(tester, sampleComment(40, userId: 20));
    await tester.tap(translate);
    // Not pumpAndSettle: the running translation keeps its spinner turning.
    await tester.pump();
    expect(transport.calls, 1);
    expect(tester.widget<TextButton>(translate).onPressed, isNull);

    transport.completer.complete('你好');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('你好'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '收起翻译'), findsOneWidget);
  });
}
