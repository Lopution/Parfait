import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:parfait/core/entity/illust_entity.dart';
import 'package:parfait/core/share/share_service.dart';
import 'package:parfait/core/watchlater/watch_later_database.dart';
import 'package:parfait/core/watchlater/watch_later_repository.dart';
import 'package:parfait/core/watchlater/watch_later_store.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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

/// In-memory repository for widget tests. sqflite_ffi runs sqlite on a
/// worker isolate, and isolate port events are starved inside the
/// testWidgets fake-async zone — the real-DB path is already covered by
/// watch_later_store_test, so the persistence boundary is faked here while
/// the sheet/dispatch code under test stays real.
class MemoryWatchLaterRepository extends WatchLaterRepository {
  MemoryWatchLaterRepository()
    : super(
        database: WatchLaterDatabase(
          factory: databaseFactoryFfi,
          databasePath: inMemoryDatabasePath,
        ),
      );

  final Map<String, List<WatchLaterEntry>> _rows = {};

  List<WatchLaterEntry> _account(String accountId) =>
      _rows.putIfAbsent(accountId, () => []);

  @override
  Future<List<WatchLaterEntry>> list(String accountId) async =>
      List.unmodifiable(_account(accountId));

  @override
  Future<void> add(String accountId, IllustEntity entity) async {
    final rows = _account(accountId);
    rows.removeWhere((entry) => entry.entity.id == entity.id);
    rows.insert(
      0,
      WatchLaterEntry(
        addedAt: DateTime.now().millisecondsSinceEpoch,
        entity: entity,
      ),
    );
  }

  @override
  Future<void> restoreAll(
    String accountId,
    Iterable<WatchLaterEntry> entries,
  ) async {
    final rows = _account(accountId);
    for (final entry in entries) {
      rows
        ..removeWhere((row) => row.entity.id == entry.entity.id)
        ..add(entry);
    }
    // Newest first, like the database query.
    rows.sort((a, b) => b.addedAt.compareTo(a.addedAt));
  }

  @override
  Future<void> removeAll(String accountId, Iterable<int> illustIds) async {
    final ids = illustIds.toSet();
    _account(accountId).removeWhere((entry) => ids.contains(entry.entity.id));
  }

  @override
  Future<void> clear(String accountId) async => _account(accountId).clear();
}

typedef CardWorld = (
  ProviderContainer,
  CardApiFixture,
  MemoryWatchLaterRepository,
);

Future<CardWorld> makeCardWorld({ShareService? shareService}) async {
  SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  final fixture = CardApiFixture();
  final repository = MemoryWatchLaterRepository();

  final container = await signedInApiContainer(
    fixture.build(),
    overrides: [
      watchLaterRepositoryProvider.overrideWithValue(repository),
      if (shareService != null)
        shareServiceProvider.overrideWithValue(shareService),
    ],
  );
  return (container, fixture, repository);
}
