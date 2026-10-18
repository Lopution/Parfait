import 'package:flutter_test/flutter_test.dart';
import 'package:parfait/core/navigation/home_destination.dart';
import 'package:parfait/core/settings/arrangement.dart';

import 'helpers/settings_world.dart';

const _recommended = HomeDestination.recommended;
const _ranking = HomeDestination.ranking;
const _newWorks = HomeDestination.newWorks;
const _search = HomeDestination.search;
const _me = HomeDestination.me;

List<ArrangedEntry> _saved(
  List<HomeDestination> shown,
  List<HomeDestination> hidden,
) => Arrangement(shown: shown, hidden: hidden).toEntries((d) => d.name);

void main() {
  test('a saved bar keeps Me and two destinations whatever it says', () {
    expect(resolveHomeArrangement(null), HomeDestination.defaultArrangement);
    final cases = {
      // An edited bar comes back as saved.
      ([_ranking, _me, _newWorks], [_recommended, _search]): (
        [_ranking, _me, _newWorks],
        [_recommended, _search],
      ),
      // Me hidden by a damaged payload returns at the end.
      ([_ranking, _search], [_me, _recommended, _newWorks]): (
        [_ranking, _search, _me],
        [_recommended, _newWorks],
      ),
      // Me alone gets the most recently hidden one back.
      ([_me], [_newWorks, _recommended, _ranking, _search]): (
        [_me, _newWorks],
        [_recommended, _ranking, _search],
      ),
    };
    for (final MapEntry(key: (shown, hidden), value: (wantShown, wantHidden))
        in cases.entries) {
      expect(
        resolveHomeArrangement(_saved(shown, hidden)),
        Arrangement(shown: wantShown, hidden: wantHidden),
        reason: '$shown / $hidden',
      );
    }
  });

  test('Me and the last two destinations cannot leave the bar', () {
    const three = Arrangement(
      shown: [_ranking, _me, _search],
      hidden: [_recommended, _newWorks],
    );
    expect(three.canHideDestination(_ranking), isTrue);
    expect(three.canHideDestination(_me), isFalse);
    expect(three.canHideDestination(_recommended), isFalse, reason: 'hidden');
    expect(three.hide(_ranking).canHideDestination(_search), isFalse);
  });

  test('the start page falls back to the first on the bar', () {
    final bar = _saved([_ranking, _me, _search], [_recommended, _newWorks]);
    HomeDestination start(String? startPage, [String? last]) =>
        homeStartDestination(
          baseTestSettings().copyWith(
            homeArrangement: bar,
            homeStartPage: startPage,
            lastHomeDestination: last,
          ),
        );
    expect(homeStartDestination(null), _recommended, reason: 'loading');
    expect(start(null), _ranking);
    expect(start('search'), _search);
    expect(start('newWorks'), _ranking, reason: 'off the bar');
    expect(start('gone'), _ranking, reason: 'unknown value');
    expect(start(homeStartLastUsed, 'me'), _me);
    expect(start(homeStartLastUsed, 'recommended'), _ranking);
    expect(start(homeStartLastUsed), _ranking, reason: 'none used yet');

    final arrangement = resolveHomeArrangement(bar);
    expect(effectiveHomeStartPage(arrangement, 'search'), 'search');
    expect(effectiveHomeStartPage(arrangement, 'newWorks'), isNull);
    expect(
      effectiveHomeStartPage(arrangement, homeStartLastUsed),
      homeStartLastUsed,
    );
  });

  test(
    'back lands on the start page, the one used last where a run opened',
    () {
      final bar = _saved([_ranking, _me, _search], [_recommended, _newWorks]);
      HomeDestination back(String? startPage, HomeDestination? launched) =>
          homeBackDestination(
            baseTestSettings().copyWith(
              homeArrangement: bar,
              homeStartPage: startPage,
              lastHomeDestination: 'me',
            ),
            launched,
          );
      expect(back('search', _ranking), _search, reason: 'a new choice applies');
      expect(back(null, _search), _ranking);
      expect(back(homeStartLastUsed, _search), _search, reason: 'not me');
      expect(
        back(homeStartLastUsed, _newWorks),
        _ranking,
        reason: 'off the bar',
      );
      expect(back(homeStartLastUsed, null), _me, reason: 'no run yet');
    },
  );
}
