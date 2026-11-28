import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:parfait/app/widgets/novel_entry.dart';
import 'package:parfait/core/mute/mute_models.dart';
import 'package:parfait/core/mute/mute_store.dart';
import 'package:parfait/core/novel/novel_entity.dart';
import 'package:parfait/core/user/user_entity.dart';

import 'helpers/card_world.dart';
import 'helpers/localized_app.dart';

NovelEntity _novel(
  int id, {
  List<NovelTag> tags = const [],
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
}
