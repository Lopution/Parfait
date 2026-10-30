import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/platform/android_intent_channel.dart';
import 'package:parfait/core/paging/feed_snapshot_store.dart';
import 'package:parfait/core/share/share_service.dart';
import 'package:parfait/core/user/follow_models.dart';
import 'package:parfait/core/user/user_entity.dart';
import 'package:parfait/core/user/user_repository.dart';

import 'api_responses.dart';
import 'bookmark_world.dart';
import 'fake_account.dart';
import 'memory_feed_snapshot_store.dart';

/// The App API's follow endpoints. [requests] logs each call from the
/// wire (`add:<id>:<restrict>`, `delete:<id>`, `restrict:<id>`); a [gate]
/// holds the add and delete answers and [failure] fails them.
class FollowApi {
  final requests = <String>[];
  Completer<void>? gate;
  ApiRoute? failure;

  /// What the follow detail answers; null is not followed. A
  /// [restrictFailure] answers instead.
  FollowRestrict? remoteRestrict = FollowRestrict.public;
  ApiRoute? restrictFailure;

  Future<http.Response> _write(http.Request request, String verb) async {
    final fields = requestFields(request);
    requests.add(
      verb == 'add'
          ? 'add:${fields['user_id']}:${fields['restrict']}'
          : 'delete:${fields['user_id']}',
    );
    await gate?.future;
    if (failure case final fail?) return fail(request);
    return jsonResponse(const <String, Object?>{});
  }

  Map<String, ApiRoute> get routes => {
    '/v1/user/follow/add': (request) => _write(request, 'add'),
    '/v1/user/follow/delete': (request) => _write(request, 'delete'),
    '/v1/user/follow/detail': (request) async {
      requests.add('restrict:${request.url.queryParameters['user_id']}');
      if (restrictFailure case final fail?) return fail(request);
      return jsonResponse({
        'follow_detail': {
          'is_followed': remoteRestrict != null,
          'restrict': ?remoteRestrict?.name,
        },
      });
    },
  };
}

/// The App API's `/v1/user/*` reads: every user id answers [detail] with
/// its id (by default one with [works] as its illusts), illust works
/// [works] and bookmarks [bookmarks] (illust JSON), and empty user lists.
/// [requests] logs each read from the wire, like `works:<id>:<type>:first`.
class UserApi {
  UserApi({
    UserEntity? detail,
    this.works = const [],
    this.bookmarks = const [],
    this.worksFailure,
    this.detailFailure,
  }) : detail = detail ?? sampleUser(42).copyWith(totalIllusts: works.length);

  // Mutable so a refresh scenario can change what the detail answers.
  UserEntity detail;
  final List<Map<String, dynamic>> works;
  final List<Map<String, dynamic>> bookmarks;
  final ApiRoute? worksFailure;

  /// Answers the detail instead; a test may clear it to recover.
  ApiRoute? detailFailure;

  /// When set, works answers wait on it — lets a test observe the feed's
  /// loading state instead of racing past it.
  Completer<void>? worksGate;

  /// Same gate for the detail — holds the profile header's first load.
  Completer<void>? detailGate;
  final requests = <String>[];

  static String _page(http.Request request) =>
      request.url.queryParameters.containsKey('offset') ? 'next' : 'first';

  ApiRoute _users(String relation) => (request) {
    final query = request.url.queryParameters;
    requests.add('relation:${query['user_id']}:$relation');
    return jsonResponse(pageJson('user_previews', const []));
  };

  Map<String, ApiRoute> get routes => {
    '/v1/user/detail': (request) async {
      final id = int.parse(request.url.queryParameters['user_id']!);
      requests.add('detail:$id');
      await detailGate?.future;
      if (detailFailure case final fail?) return fail(request);
      return jsonResponse(userDetailJson(detail.copyWith(id: id)));
    },
    '/v1/user/illusts': (request) async {
      final query = request.url.queryParameters;
      requests.add(
        'works:${query['user_id']}:${query['type']}:${_page(request)}',
      );
      await worksGate?.future;
      if (worksFailure case final fail?) return fail(request);
      return jsonResponse(
        pageJson('illusts', query['type'] == 'illust' ? works : const []),
      );
    },
    '/v1/user/bookmarks/illust': (request) {
      final query = request.url.queryParameters;
      requests.add(
        'bookmarks:${query['user_id']}:${query['restrict']}:${query['tag'] ?? ''}',
      );
      return jsonResponse(pageJson('illusts', bookmarks));
    },
    '/v1/user/following': _users('following'),
    '/v1/user/follower': _users('fans'),
    '/v1/user/mypixiv': _users('myPixiv'),
    '/v1/user/recommended': (request) {
      requests.add('recommended:${_page(request)}');
      return jsonResponse(pageJson('user_previews', const []));
    },
  };
}

/// The profile over [PixivApi] with [follows], [users] and [bookmarks]
/// (fresh ones by default) and [routes] for the rest; its repositories,
/// controllers and stores run real.
Future<ProviderContainer> makeProfileWorld({
  bool twoAccounts = false,
  FollowApi? follows,
  UserApi? users,
  BookmarkApi? bookmarks,
  Map<String, ApiRoute> routes = const {},
  OutboundUrlOpener? outboundUrlOpener,
  ShareService? shareService,
}) async {
  final api = PixivApi({
    ...backgroundRoutes,
    // The other lists the page reads: all empty.
    '/v1/user/novels': answer(pageJson('novels', const [])),
    '/v1/user/illust-series': answer(
      pageJson('illust_series_details', const []),
    ),
    ...(follows ?? FollowApi()).routes,
    ...(users ?? UserApi()).routes,
    ...(bookmarks ?? BookmarkApi()).routes,
    ...routes,
  });
  // Per-world snapshot store: sqflite singleInstance caches the default
  // ':memory:' feeds.db by path, so one test's committed snapshot would
  // leak into the next world's cold start. An in-memory store keeps the
  // same read/write contract without touching sqlite inside FakeAsync.
  final feedSnapshots = MemoryFeedSnapshotStore();
  return signedInApiContainer(
    api.client,
    account: const Account(id: '100', userId: 100, name: 'first'),
    others: [
      if (twoAccounts) const Account(id: '200', userId: 200, name: 'second'),
    ],
    overrides: [
      feedSnapshotStoreProvider.overrideWithValue(feedSnapshots),
      if (outboundUrlOpener != null)
        outboundUrlOpenerProvider.overrideWithValue(outboundUrlOpener),
      if (shareService != null)
        shareServiceProvider.overrideWithValue(shareService),
    ],
  );
}

/// The app's user repository over [routes], for code that takes one
/// directly.
Future<UserRepository> userRepositoryOver(Map<String, ApiRoute> routes) async =>
    (await signedInApiContainer(
      PixivApi(routes).client,
    )).read(userRepositoryProvider);

/// Answers the platform's pixiv.net session channel until the test ends:
/// a session signed in as [userId], or none. Unanswered, its reply needs
/// real async, which a widget test's fake clock never gives it.
void answerWebProfileSession([int? userId]) {
  const channel = MethodChannel('parfait/webprofile');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    channel,
    (call) async => call.method == 'readSession' && userId != null
        ? 'PHPSESSID=${userId}_0123456789abcdef0123456789abcdef'
        : null,
  );
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
}

UserEntity sampleUser(int id) =>
    UserEntity(id: id, name: 'sample user', account: 'sample');
