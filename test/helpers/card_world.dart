import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parfait/core/mute/mute_models.dart';
import 'package:parfait/core/mute/mute_store.dart';
import 'package:parfait/core/share/share_service.dart';
import 'package:parfait/core/watchlater/watch_later_repository.dart';
import 'package:parfait/core/watchlater/watch_later_store.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'fake_account.dart';
import 'test_preferences.dart';

/// HTTP transport recording bookmark calls so the card menu's bookmark
/// adapter can be verified against real wire requests.
class CardApiFixture {
  final List<Uri> posts = [];
  final List<Map<String, String>> postBodies = [];

  /// Hydration payload for `/v1/mute/list`; tests override to seed
  /// server-side muted tags/users.
  Map<String, dynamic> muteList = {
    'muted_tags': <dynamic>[],
    'muted_users': <dynamic>[],
    'mute_limit_count': 500,
  };

  /// `/v1/mute/edit` knobs: a non-2xx status fails the write; a gate
  /// defers the response so tests can observe the in-flight pending row.
  int muteEditStatus = 200;
  Completer<void>? muteEditGate;

  http.Client build() {
    return MockClient((request) async {
      // The card watches MuteStore, whose hydrate fetches the server list.
      if (request.method == 'GET' &&
          request.url.path.endsWith('/v1/mute/list')) {
        return jsonResponse(muteList);
      }
      posts.add(request.url);
      if (request.url.path.endsWith('/v1/mute/edit')) {
        await muteEditGate?.future;
        if (muteEditStatus != 200) {
          return jsonResponse({
            'message': 'boom',
            'is_success': false,
          }, muteEditStatus);
        }
      }
      Map<String, String> fields;
      try {
        fields = (jsonDecode(request.body) as Map).cast<String, String>();
      } on FormatException {
        fields = Uri.splitQueryString(request.body);
      }
      postBodies.add(fields);
      return jsonResponse({'message': '', 'is_success': true});
    });
  }
}

/// The world, its API fixture and the app's watch-later repository (an
/// in-memory database under `flutter test`).
typedef CardWorld = (ProviderContainer, CardApiFixture, WatchLaterRepository);

Future<CardWorld> makeCardWorld({ShareService? shareService}) async {
  SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  final fixture = CardApiFixture();
  final container = await signedInApiContainer(
    fixture.build(),
    overrides: [
      if (shareService != null)
        shareServiceProvider.overrideWithValue(shareService),
    ],
  );
  return (container, fixture, container.read(watchLaterRepositoryProvider));
}

/// Mutes fixed at [seed], with no account, storage or server behind them.
class SeededMuteStore extends MuteStore {
  SeededMuteStore(this.seed);

  final MuteState seed;

  @override
  MuteState build() => seed;
}
