import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:parfait/app/layout/card_columns.dart';
import 'package:parfait/app/widgets/feed/feed_grid.dart';
import 'package:parfait/core/entity/stored_entities.dart';

/// An entity: equal only to itself (never const, which would share one).
class _Entity {
  _Entity(this.id);

  final int id;
}

class _Card extends StatelessWidget {
  const _Card(this.entity, this.builds);

  final _Entity entity;
  final Map<_Entity, int> builds;

  @override
  Widget build(BuildContext context) {
    builds.update(entity, (count) => count + 1, ifAbsent: () => 1);
    return SizedBox(height: 100, child: Text('${entity.id}'));
  }
}

void main() {
  for (final grid in [true, false]) {
    testWidgets('a ${grid ? 'grid' : 'card list'} rebuilds only the cards '
        'whose entity or other inputs changed', (tester) async {
      final builds = <_Entity, int>{};
      Future<void> show(List<_Entity> items, {Object? deps}) {
        Widget card(BuildContext context, int index) =>
            _Card(items[index], builds);
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
      // A page appended, then the same entities again (a load-more phase
      // change, a store merging other entities).
      final appended = [...first, _Entity(4), _Entity(5)];
      await show(appended);
      await show([...appended]);
      expect(builds.keys, appended);
      expect(builds.values, everyElement(1));

      // A changed entity rebuilds its own card.
      final changed = [...appended]..[1] = _Entity(1);
      await show(changed);
      expect(builds[changed[1]], 1);
      expect(builds[first[1]], 1);
      expect(builds[first[0]], 1);

      // Another input changed: every card rebuilds.
      await show(changed, deps: 'another scope');
      expect([for (final entity in changed) builds[entity]], everyElement(2));
    });
  }

  test('stored entities stay equal while each is the same instance', () {
    final a = _Entity(1);
    final b = _Entity(2);
    final store = {1: a, 2: b};
    final ids = [2, 1, 3];
    expect(StoredEntities(store, ids).items, [b, a]);
    expect(
      StoredEntities(store, ids),
      StoredEntities({...store, 4: _Entity(4)}, ids),
    );
    expect(
      StoredEntities(store, ids),
      isNot(StoredEntities({...store, 1: _Entity(1)}, ids)),
    );
  });
}
