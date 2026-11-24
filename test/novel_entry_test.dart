import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:parfait/app/layout/input_modality.dart';
import 'package:parfait/app/widgets/entity_row.dart';
import 'package:parfait/app/widgets/novel_entry.dart';
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/mute/mute_models.dart';
import 'package:parfait/core/mute/mute_store.dart';
import 'package:parfait/core/novel/novel_entity.dart';
import 'package:parfait/core/user/user_entity.dart';

import 'helpers/card_world.dart';
import 'helpers/fake_account.dart';
import 'helpers/localized_app.dart';
import 'helpers/pixiv_router.dart';

NovelEntity _novel(
  int id, {
  String? coverUrl,
  List<NovelTag> tags = const [],
  String? seriesTitle,
  int totalBookmarks = 0,
  int xRestrict = 0,
  int novelAiType = 0,
}) => NovelEntity(
  id: id,
  title: 'novel $id',
  caption: '',
  user: const UserEntity(id: 8, name: 'author', account: 'author'),
  tags: tags,
  textLength: 4321,
  contentVersion: 'v$id',
  paragraphs: const [],
  coverImageUrl: coverUrl,
  seriesTitle: seriesTitle,
  totalBookmarks: totalBookmarks,
  xRestrict: xRestrict,
  novelAiType: novelAiType,
);

Widget _host(Widget child, {MuteState mutes = const MuteState()}) =>
    localizedApp(
      overrides: [muteStoreProvider.overrideWith(() => SeededMuteStore(mutes))],
      body: child,
    );

void main() {
  testWidgets('series, tags and the bookmark count join the identity', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _host(
        NovelEntry.regular(
          entity: _novel(
            6,
            seriesTitle: 'saga',
            totalBookmarks: 1234,
            tags: [for (var i = 1; i <= 6; i++) NovelTag(name: 't$i')],
          ),
        ),
      ),
    );
    expect(find.textContaining('saga · '), findsOneWidget);
    // Four tags at most on the footnote line.
    expect(find.text('#t1 #t2 #t3 #t4'), findsOneWidget);
    // Bookmark count lives in the meta line instead of clipping on the narrow cover.
    expect(find.byType(EntityBadge), findsNothing);
    expect(find.textContaining('次收藏'), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp(r'^novel 6, author, .+ 次收藏$')),
      findsOneWidget,
    );
    semantics.dispose();
  });

  testWidgets(
    'R-18, R-18G and AI marks appear in meta and semantics until muted',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          _host(
            NovelEntry.compact(
              entity: _novel(
                12,
                xRestrict: 1,
                novelAiType: 2,
                totalBookmarks: 99,
              ),
            ),
          ),
        );
        expect(find.textContaining('R-18 · AI 生成'), findsOneWidget);
        expect(find.textContaining('99 次收藏'), findsOneWidget);
        expect(
          find.bySemanticsLabel(
            RegExp(r'novel 12, author, R-18, AI 生成, 99 次收藏'),
          ),
          findsOneWidget,
        );

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(
          _host(
            NovelEntry.compact(
              entity: _novel(
                13,
                xRestrict: 2,
                tags: [const NovelTag(name: 't1')],
              ),
            ),
            mutes: const MuteState(tags: {'t1'}),
          ),
        );
        expect(find.textContaining('R-18G'), findsNothing);
        await tester.tap(find.byType(NovelEntry));
        await tester.pump();
        expect(find.textContaining('R-18G'), findsOneWidget);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets('a muted novel shows the reason until a tap reveals it', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        NovelEntry.regular(
          entity: _novel(6, tags: [NovelTag(name: 't1')]),
        ),
        mutes: const MuteState(tags: {'t1'}),
      ),
    );
    expect(find.text('已屏蔽：t1'), findsOneWidget);
    expect(find.text('#t1'), findsNothing);

    await tester.tap(find.byType(NovelEntry));
    await tester.pump();
    expect(find.text('novel 6'), findsOneWidget);
    expect(find.text('#t1'), findsOneWidget);
  });

  testWidgets('tap opens the novel route through the facade', (tester) async {
    // Same bootstrap as home_page_test: account overrides only, so the
    // real router and route facades drive navigation. Network-backed
    // providers fail fast inside the test host — this test only asserts
    // the facade wiring, not the destination page's content.
    final router = pixivRouter('/recommended');
    await tester.pumpWidget(
      localizedRouterApp(
        router,
        overrides: await signedInAccountOverrides(
          const Account(id: '100', userId: 100, name: 't'),
        ),
      ),
    );
    await tester.pump();

    // Host the entry on a plain pushed route — driving the shell's
    // recommended feed needs the full feed world; the contract under
    // test is "tap calls openNovel", not the feed.
    router.routerDelegate.navigatorKey.currentState!.push(
      PageRouteBuilder<void>(
        pageBuilder: (context, _, _) =>
            Scaffold(body: NovelEntry.compact(entity: _novel(77))),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(NovelEntry), findsOneWidget);

    await tester.tap(find.byType(NovelEntry));
    await tester.pump();
    expect(router.state.uri.path, '/recommended/novel/77');
  });

  testWidgets('pointer secondary click on NovelEntry opens context menu', (
    tester,
  ) async {
    var opened = 0;
    await tester.pumpWidget(
      _host(
        InputModalityScope(
          initialModality: InputModality.pointer,
          child: NovelEntry.regular(entity: _novel(88), onTap: () => opened++),
        ),
      ),
    );
    await tester.tap(
      find.byType(NovelEntry),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    expect(find.text('打开作品'), findsOneWidget);
    expect(find.text('编辑收藏'), findsOneWidget);
    expect(find.text('复制链接'), findsOneWidget);

    await tester.tap(find.text('打开作品'));
    await tester.pumpAndSettle();
    expect(opened, 1);
  });
}
