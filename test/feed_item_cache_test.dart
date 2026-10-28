import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:parfait/app/layout/card_columns.dart';
import 'package:parfait/app/widgets/feed/feed_grid.dart';
import 'package:parfait/core/entity/stored_entities.dart';

/// An entity: equal only to itself (never const, which would share one).
class _Entity {
  _Entity(this.id, [this.label = 'a']);

  final int id;
  final String label;
}

void main() {
  for (final grid in [true, false]) {
    testWidgets('a ${grid ? 'grid' : 'card list'} shows a changed entity or '
        'input on its cards', (tester) async {
      Future<void> show(List<_Entity> items, {String deps = 'scope'}) {
        Widget card(BuildContext context, int index) => SizedBox(
          height: 100,
          child: Text('${items[index].id}${items[index].label} $deps'),
        );
        return tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              home: CustomScrollView(
                slivers: [
                  if (grid)
                    IllustFeedGrid(
                      itemCount: items.length,
                      items: items,
                      itemDeps: deps,
                      itemBuilder: card,
                    )
                  else
                    SliverCardList(
                      itemCount: items.length,
                      items: items,
                      itemDeps: deps,
                      itemBuilder: card,
                    ),
                ],
              ),
            ),
          ),
        );
      }

      final first = [for (var id = 0; id < 4; id++) _Entity(id)];
      await show(first);
      // The same entities again (a load-more phase change, a store merging
      // other entities), then one replaced.
      await show([...first]);
      final changed = [...first]..[1] = _Entity(1, 'b');
      await show(changed);
      expect(find.text('1b scope'), findsOneWidget);
      expect(find.text('1a scope'), findsNothing);

      await show(changed, deps: 'other');
      expect(find.textContaining(' other'), findsNWidgets(4));
    });
  }

  test('stored entities list theirs in order and differ once one is '
      'replaced', () {
    final a = _Entity(1);
    final b = _Entity(2);
    final store = {1: a, 2: b};
    final ids = [2, 1, 3];
    expect(StoredEntities(store, ids).items, [b, a]);
    expect(
      StoredEntities(store, ids),
      isNot(StoredEntities({...store, 1: _Entity(1)}, ids)),
    );
  });
}
