import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parfait/core/actionqueue/action_bootstrap.dart';
import 'package:parfait/core/actionqueue/action_store.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'fake_account.dart';
import 'test_preferences.dart';

/// The watchlist endpoints over a MockClient: GETs serve [mangaSeries] or
/// [novelSeries], writes answer [mutationStatus].
class WatchlistFixture {
  final requests = <http.Request>[];
  List<Map<String, Object?>> mangaSeries = const [];
  List<Map<String, Object?>> novelSeries = const [];
  int mutationStatus = 200;

  http.Client build() => MockClient((request) async {
    requests.add(request);
    if (request.method == 'GET') {
      final isNovel = request.url.path.contains('/novel');
      return jsonResponse({
        'series': isNovel ? novelSeries : mangaSeries,
        'next_url': null,
      });
    }
    if (mutationStatus != 200) {
      return jsonResponse({
        'error': {'message': 'rejected'},
      }, mutationStatus);
    }
    return jsonResponse({'is_success': true});
  });
}

Future<(ProviderContainer, WatchlistFixture)> makeWatchlistWorld({
  WatchlistFixture? fixture,
  SharedPreferencesAsyncPlatform? preferences,
}) async {
  SharedPreferencesAsyncPlatform.instance = preferences ?? memoryPreferences();
  final resolvedFixture = fixture ?? WatchlistFixture();
  final container = await signedInApiContainer(
    resolvedFixture.build(),
    overrides: [actionStoreProvider.overrideWithValue(InMemoryActionStore())],
  );
  return (container, resolvedFixture);
}
