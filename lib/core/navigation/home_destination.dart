/// The home shell's destinations and the user's arrangement of them: which
/// sit on the bottom bar, in what order, and where the app opens.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../settings/app_settings.dart';
import '../settings/arrangement.dart';
import '../settings/settings_controller.dart';

/// One destination per shell branch, in branch order. The branches never
/// move; only the bar shows them in the user's order.
enum HomeDestination {
  recommended('/recommended'),
  ranking('/ranking'),
  newWorks('/new'),
  search('/search'),
  me('/settings');

  const HomeDestination(this.rootPath);

  /// The branch root's location.
  final String rootPath;

  int get branchIndex => index;

  /// Me holds the settings, the only way back to this arrangement: it
  /// never leaves the bar.
  bool get hideable => this != me;

  static HomeDestination ofBranch(int branchIndex) => values[branchIndex];

  static HomeDestination? byName(String? name) => values.asNameMap()[name];

  static const defaultArrangement = Arrangement<HomeDestination>(
    shown: values,
    hidden: [],
  );
}

/// The fewest destinations the bar shows.
const minHomeDestinations = 2;

/// The `homeStartPage` value that opens the destination used last.
const homeStartLastUsed = 'last';

/// [saved] laid over the default bar. Me and two destinations stay on the
/// bar whatever the payload says, so a damaged or newer one cannot leave
/// the user without the settings.
Arrangement<HomeDestination> resolveHomeArrangement(
  List<ArrangedEntry>? saved,
) {
  var arrangement = Arrangement.resolve(
    HomeDestination.defaultArrangement,
    saved,
    HomeDestination.byName,
  );
  if (!arrangement.shown.contains(HomeDestination.me)) {
    arrangement = arrangement.show(HomeDestination.me);
  }
  while (arrangement.shown.length < minHomeDestinations) {
    arrangement = arrangement.show(arrangement.hidden.first);
  }
  return arrangement;
}

extension HomeArrangement on Arrangement<HomeDestination> {
  /// Whether [destination] may leave the bar.
  bool canHideDestination(HomeDestination destination) =>
      destination.hideable &&
      shown.contains(destination) &&
      shown.length > minHomeDestinations;
}

/// The start page choice in effect: a chosen destination no longer on the
/// bar, or an unknown value, is the first on the bar (null) again.
String? effectiveHomeStartPage(
  Arrangement<HomeDestination> arrangement,
  String? startPage,
) {
  if (startPage == homeStartLastUsed) return startPage;
  final destination = HomeDestination.byName(startPage);
  return destination != null && arrangement.shown.contains(destination)
      ? startPage
      : null;
}

/// Where the app opens: the first destination on the bar, the one used
/// last, or the chosen one. One used last that is off the bar falls back
/// to the first.
HomeDestination homeStartDestination(AppSettings? settings) {
  final arrangement = resolveHomeArrangement(settings?.homeArrangement);
  final destination = switch (effectiveHomeStartPage(
    arrangement,
    settings?.homeStartPage,
  )) {
    homeStartLastUsed => HomeDestination.byName(settings?.lastHomeDestination),
    final name => HomeDestination.byName(name),
  };
  return destination != null && arrangement.shown.contains(destination)
      ? destination
      : arrangement.shown.first;
}

/// The user's bar; the default until settings have loaded.
final homeArrangementProvider = Provider<Arrangement<HomeDestination>>(
  (ref) => resolveHomeArrangement(
    ref.watch(settingsProvider.select((async) => async.value?.homeArrangement)),
  ),
);

/// Saves [arrangement]; the default one is saved as null, so a later
/// version's default reaches users who never edited it.
Future<void> saveHomeArrangement(
  SettingsController settings,
  Arrangement<HomeDestination> arrangement,
) => settings.setHomeArrangement(
  arrangement == HomeDestination.defaultArrangement
      ? null
      : arrangement.toEntries((destination) => destination.name),
);
