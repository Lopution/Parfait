import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:pixiv_func/app/haptics/app_haptics.dart';
import 'package:pixiv_func/app/widgets/card_actions/illust_card_actions.dart';
import 'package:pixiv_func/app/widgets/feed/illust_card.dart';
import 'package:pixiv_func/app/widgets/feed/muted_cover.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/auth/credential.dart';
import 'package:pixiv_func/core/auth/oauth_service.dart';
import 'package:pixiv_func/core/bookmark/bookmark_models.dart';
import 'package:pixiv_func/core/bookmark/bookmark_store.dart';
import 'package:pixiv_func/core/entity/illust_entity.dart';
import 'package:pixiv_func/core/mute/mute_store.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:pixiv_func/core/share/share_service.dart';
import 'package:pixiv_func/features/settings/pages/muted_items_page.dart';
import 'package:pixiv_func/core/watchlater/watch_later_database.dart';
import 'package:pixiv_func/core/watchlater/watch_later_repository.dart';
import 'package:pixiv_func/core/watchlater/watch_later_store.dart';
import 'package:pixiv_func/features/watchlater/watchlater_page.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';
import 'package:pixiv_func/l10n/app_localizations.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/fake_account.dart';
import 'helpers/illust_fixtures.dart';
import 'helpers/test_preferences.dart';

/// HTTP transport recording bookmark calls so the card menu's bookmark
/// adapter can be verified against real wire requests.
class _BookmarkApiFixture {
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
        return http.Response(
          jsonEncode(muteList),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      posts.add(request.url);
      if (request.url.path.endsWith('/v1/mute/edit')) {
        await muteEditGate?.future;
        if (muteEditStatus != 200) {
          return http.Response(
            jsonEncode({'message': 'boom', 'is_success': false}),
            muteEditStatus,
            headers: {'content-type': 'application/json'},
          );
        }
      }
      Map<String, String> fields;
      try {
        fields = (jsonDecode(request.body) as Map).cast<String, String>();
      } on FormatException {
        fields = Uri.splitQueryString(request.body);
      }
      postBodies.add(fields);
      return http.Response(
        jsonEncode({'message': '', 'is_success': true}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
  }
}

/// In-memory repository for widget tests. sqflite_ffi runs sqlite on a
/// worker isolate, and isolate port events are starved inside the
/// testWidgets fake-async zone — the real-DB path is already covered by
/// watch_later_store_test, so the persistence boundary is faked here while
/// the sheet/dispatch code under test stays real.
class _MemoryWatchLaterRepository extends WatchLaterRepository {
  _MemoryWatchLaterRepository()
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
  Future<void> add(
    String accountId,
    IllustEntity entity, {
    int? addedAt,
  }) async {
    final rows = _account(accountId);
    rows.removeWhere((entry) => entry.entity.id == entity.id);
    rows.insert(
      0,
      WatchLaterEntry(
        addedAt: addedAt ?? DateTime.now().millisecondsSinceEpoch,
        entity: entity,
      ),
    );
  }

  @override
  Future<void> remove(String accountId, int illustId) async {
    _account(accountId).removeWhere((entry) => entry.entity.id == illustId);
  }

  @override
  Future<void> clear(String accountId) async => _account(accountId).clear();
}

typedef World = (
  ProviderContainer,
  _BookmarkApiFixture,
  _MemoryWatchLaterRepository,
);

/// Records the payloads the card sheet hands to the platform share
/// boundary — the system sheet itself is plugin territory.
class _RecordingShareService implements ShareService {
  SharePayload? lastPayload;
  ShareOutcome outcome = ShareOutcome.openedSheet;

  @override
  Future<ShareOutcome> share(
    SharePayload payload, {
    Rect? sharePositionOrigin,
  }) async {
    lastPayload = payload;
    return outcome;
  }
}

Future<World> _makeWorld({ShareService? shareService}) async {
  SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  final fixture = _BookmarkApiFixture();
  final repository = _MemoryWatchLaterRepository();

  final credentials = FakeCredentialStore()
    ..seed(
      '100',
      const Credential(accessToken: 'access-1', refreshToken: 'refresh-1'),
    );
  final clientRef = <PixivHttpClient?>[null];
  final container = ProviderContainer(
    overrides: [
      credentialStoreProvider.overrideWithValue(credentials),
      accountMetadataRepositoryProvider.overrideWithValue(
        FakeAccountMetadataRepository(
          accounts: const [Account(id: '100', userId: 100, name: 'tester')],
          currentId: '100',
        ),
      ),
      oauthServiceProvider.overrideWithValue(
        OAuthService(
          client: MockClient((request) async {
            fail('refresh should not happen in this test');
          }),
        ),
      ),
      pixivHttpClientProvider.overrideWith((ref) {
        final client = clientRef[0];
        if (client == null) throw StateError('client not wired yet');
        return client;
      }),
      watchLaterRepositoryProvider.overrideWithValue(repository),
      if (shareService != null)
        shareServiceProvider.overrideWithValue(shareService),
    ],
  );
  clientRef[0] = PixivHttpClient(
    client: fixture.build(),
    accountStore: container.read(accountStoreProvider.notifier),
    credentialStore: credentials,
    oauthService: container.read(oauthServiceProvider),
  );
  await container.read(accountStoreProvider.future);
  addTearDown(container.dispose);
  return (container, fixture, repository);
}

Widget _cardApp(ProviderContainer container, Widget home) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      localizationsDelegates: appLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh', 'CN'),
      home: Scaffold(
        body: Center(child: SizedBox(width: 300, child: home)),
      ),
    ),
  );
}

Future<void> _openSheet(WidgetTester tester) async {
  await tester.longPress(find.byType(IllustCard));
  await tester.pumpAndSettle();
}

Future<void> _tapEntry(WidgetTester tester, String label) async {
  await tester.tap(find.widgetWithText(ListTile, label));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('long-press opens the sheet with all registered actions', (
    tester,
  ) async {
    final (container, _, _) = await _makeWorld();
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        _cardApp(container, IllustCard(entity: parseIllust(illustJson(7)))),
      );
      await _openSheet(tester);
    });

    final actions = container.read(illustCardActionsProvider);
    expect(actions.map((a) => a.id), [
      'bookmark',
      'download',
      'watch-later',
      'mute-work',
      'mute-user',
      'share',
    ]);
    for (final label in ['收藏', '下载', '稍后再看', '屏蔽此作品', '屏蔽作者', '分享']) {
      expect(
        find.widgetWithText(ListTile, label),
        findsOneWidget,
        reason: 'sheet should offer "$label"',
      );
      expect(find.bySemanticsLabel(label), findsWidgets);
    }
  });

  testWidgets('watch-later action adds, then the sheet offers remove', (
    tester,
  ) async {
    final (container, _, repository) = await _makeWorld();
    final entity = parseIllust(illustJson(9));
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(_cardApp(container, IllustCard(entity: entity)));
      await _openSheet(tester);
      await _tapEntry(tester, '稍后再看');
      await tester.pump();
      await tester.pump();
    });

    expect(find.text('已加入稍后再看'), findsOneWidget);
    expect((await repository.list('100')).map((e) => e.entity.id), [9]);

    await mockNetworkImagesFor(() async {
      await _openSheet(tester);
    });
    expect(find.widgetWithText(ListTile, '从稍后再看移除'), findsOneWidget);
    await mockNetworkImagesFor(() async {
      await _tapEntry(tester, '从稍后再看移除');
      await tester.pump();
      await tester.pump();
    });
    expect(await repository.list('100'), isEmpty);
  });

  testWidgets('watch-later removal offers undo restoring the entry', (
    tester,
  ) async {
    // Undo is the light-tick role — capture HapticFeedback.vibrate on the
    // platform channel, the AppHaptics static owner's observable seam.
    final haptics = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'HapticFeedback.vibrate') {
          haptics.add(call.arguments as String);
        }
        return null;
      },
    );
    AppHaptics.debugReset();
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
      AppHaptics.debugReset();
    });
    final (container, _, repository) = await _makeWorld();
    final entity = parseIllust(illustJson(9));
    const originalAddedAt = 1726800000000;
    await repository.add('100', entity, addedAt: originalAddedAt);
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(_cardApp(container, IllustCard(entity: entity)));
      await tester.pump();
      await _openSheet(tester);
      await _tapEntry(tester, '从稍后再看移除');
      await tester.pump();
      await tester.pump();
    });

    // The removal snackbar carries the undo action.
    expect(find.text('已从稍后再看移除'), findsOneWidget);
    expect(find.text('撤销'), findsOneWidget);
    expect(await repository.list('100'), isEmpty);

    await tester.tap(find.text('撤销'));
    expect(haptics, ['HapticFeedbackType.selectionClick']);
    await mockNetworkImagesFor(() async {
      await tester.pump();
      await tester.pump();
    });
    final restored = await repository.list('100');
    expect(restored.map((e) => e.entity.id), [9]);
    // Undo pins the original timestamp — the row keeps its old position.
    expect(restored.single.addedAt, originalAddedAt);
  });

  testWidgets('bookmark action sends a real add request', (tester) async {
    final (container, fixture, _) = await _makeWorld();
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        _cardApp(container, IllustCard(entity: parseIllust(illustJson(11)))),
      );
      await _openSheet(tester);
      await _tapEntry(tester, '收藏');
    });

    expect(fixture.posts, hasLength(1));
    expect(fixture.posts.single.path, '/v2/illust/bookmark/add');
    expect(
      container.read(
        bookmarkStoreProvider.select(
          (s) =>
              s[const BookmarkKey(BookmarkEntityType.illust, 11)]?.bookmarked,
        ),
      ),
      isTrue,
    );

    await mockNetworkImagesFor(() async {
      await _openSheet(tester);
    });
    expect(find.widgetWithText(ListTile, '取消收藏'), findsOneWidget);
  });

  testWidgets(
    'download action surfaces submission failure for an entity without '
    'original URLs',
    (tester) async {
      final (container, _, _) = await _makeWorld();
      // Multi-page work without metaPages: originalUrlAt yields nothing,
      // so downloadAll throws FormatException — the adapter must catch
      // and report instead of propagating.
      final entity = parseIllust(illustJson(13, pageCount: 3));
      await mockNetworkImagesFor(() async {
        await tester.pumpWidget(
          _cardApp(container, IllustCard(entity: entity)),
        );
        await _openSheet(tester);
        await _tapEntry(tester, '下载');
      });
      expect(find.textContaining('下载失败'), findsOneWidget);
    },
  );

  testWidgets(
    'share action hands the Shaft-format payload to the share service',
    (tester) async {
      final share = _RecordingShareService();
      final (container, _, _) = await _makeWorld(shareService: share);
      await mockNetworkImagesFor(() async {
        await tester.pumpWidget(
          _cardApp(container, IllustCard(entity: parseIllust(illustJson(15)))),
        );
        await _openSheet(tester);
        await _tapEntry(tester, '分享');
      });

      expect(
        share.lastPayload?.text,
        'illust 15 | author #Pixiv https://www.pixiv.net/artworks/15',
      );
    },
  );

  testWidgets('share fallback to clipboard shows the copy confirmation', (
    tester,
  ) async {
    final share = _RecordingShareService()
      ..outcome = ShareOutcome.copiedToClipboard;
    final (container, _, _) = await _makeWorld(shareService: share);
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        _cardApp(container, IllustCard(entity: parseIllust(illustJson(15)))),
      );
      await _openSheet(tester);
      await _tapEntry(tester, '分享');
    });

    expect(find.text('链接已复制'), findsOneWidget);
  });

  testWidgets('watch-later page renders stored works and empty state', (
    tester,
  ) async {
    final (container, _, repository) = await _makeWorld();
    await repository.add('100', parseIllust(illustJson(21)));
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(_cardApp(container, const WatchLaterPage()));
      await tester.pumpAndSettle();
    });
    expect(find.text('illust 21'), findsWidgets);
    expect(find.byType(IllustCard), findsOneWidget);

    await repository.remove('100', 21);
    container.invalidate(watchLaterStoreProvider);
    await mockNetworkImagesFor(() async {
      await tester.pumpAndSettle();
    });
    expect(find.text('暂存的作品会显示在这里'), findsOneWidget);
  });

  testWidgets('mute-work action toggles the local work mute', (tester) async {
    final (container, fixture, _) = await _makeWorld();
    final entity = parseIllust(illustJson(31));
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(_cardApp(container, IllustCard(entity: entity)));
      await _openSheet(tester);
      await _tapEntry(tester, '屏蔽此作品');
      await tester.pump();
      await tester.pump();
    });

    expect(
      container.read(muteStoreProvider.select((s) => s.isWorkMuted(31))),
      isTrue,
    );
    // Work mute is local-only: no mute/edit request may leave the client.
    expect(
      fixture.posts.where((u) => u.path.endsWith('/v1/mute/edit')),
      isEmpty,
    );

    await mockNetworkImagesFor(() async {
      await _openSheet(tester);
    });
    expect(find.widgetWithText(ListTile, '解除屏蔽此作品'), findsOneWidget);
  });

  testWidgets('mute-author action sends add_user_ids to mute/edit', (
    tester,
  ) async {
    final (container, fixture, _) = await _makeWorld();
    final entity = parseIllust(illustJson(33));
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(_cardApp(container, IllustCard(entity: entity)));
      await _openSheet(tester);
      await _tapEntry(tester, '屏蔽作者');
      await tester.pump();
      await tester.pump();
    });

    final edit = fixture.posts.indexWhere(
      (u) => u.path.endsWith('/v1/mute/edit'),
    );
    expect(edit, isNonNegative);
    expect(fixture.postBodies[edit]['add_user_ids[]'], '${entity.user.id}');
    expect(
      container.read(
        muteStoreProvider.select((s) => s.isUserMuted(entity.user.id)),
      ),
      isTrue,
    );

    await mockNetworkImagesFor(() async {
      await _openSheet(tester);
    });
    expect(find.widgetWithText(ListTile, '解除屏蔽作者'), findsOneWidget);
  });

  testWidgets('muted card blurs the cover and tap reveals in place', (
    tester,
  ) async {
    final (container, _, _) = await _makeWorld();
    final entity = parseIllust(illustJson(51));
    await container.read(muteStoreProvider.notifier).toggleWork(51);
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(_cardApp(container, IllustCard(entity: entity)));
      await tester.pump();
    });

    expect(find.byType(MutedCover), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('已屏蔽.*illust 51')), findsOneWidget);

    await mockNetworkImagesFor(() async {
      await tester.tap(find.byType(MutedCover));
      await tester.pump();
    });

    // Reveal swaps the cover for the normal card; the mute itself is
    // untouched (session-local presentation only).
    expect(find.byType(MutedCover), findsNothing);
    expect(
      container.read(muteStoreProvider.select((s) => s.isWorkMuted(51))),
      isTrue,
    );
  });

  testWidgets('muted items page lists entries and removes them', (
    tester,
  ) async {
    final (container, fixture, _) = await _makeWorld();
    fixture.muteList = {
      'muted_tags': [
        {'tag': 'tagA'},
      ],
      'muted_users': [
        {
          'user_id': 5,
          'user_name': 'user5',
          'user_account': 'u5',
          'user_profile_image_urls': {'medium': 'https://i.pximg.net/m.png'},
        },
      ],
      'mute_limit_count': 500,
    };
    // Seed a local work mute before the page builds.
    await container.read(muteStoreProvider.notifier).toggleWork(41);

    await tester.pumpWidget(_cardApp(container, const MutedItemsPage()));
    await tester.pumpAndSettle();

    expect(find.text('tagA'), findsOneWidget);
    expect(find.text('user5'), findsOneWidget);
    expect(find.text('#41'), findsOneWidget);

    // Unmute tag → server delete_tags[] request, row disappears.
    final tagTile = find.widgetWithText(ListTile, 'tagA');
    await tester.tap(
      find.descendant(
        of: tagTile,
        matching: find.byIcon(Icons.visibility_outlined),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('tagA'), findsNothing);
    final edit = fixture.posts.indexWhere(
      (u) => u.path.endsWith('/v1/mute/edit'),
    );
    expect(edit, isNonNegative);
    expect(fixture.postBodies[edit]['delete_tags[]'], 'tagA');

    // Unmute work → local only, no additional HTTP.
    final postsBefore = fixture.posts.length;
    final workTile = find.widgetWithText(ListTile, '#41');
    await tester.tap(
      find.descendant(
        of: workTile,
        matching: find.byIcon(Icons.visibility_outlined),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('#41'), findsNothing);
    expect(fixture.posts, hasLength(postsBefore));
    expect(
      container.read(muteStoreProvider.select((s) => s.isWorkMuted(41))),
      isFalse,
    );
  });

  testWidgets('muted items rows expose the release verb and icon', (
    tester,
  ) async {
    final (container, fixture, _) = await _makeWorld();
    fixture.muteList = {
      'muted_tags': [
        {'tag': 'tagA'},
      ],
      'muted_users': <dynamic>[],
      'mute_limit_count': 500,
    };
    await tester.pumpWidget(_cardApp(container, const MutedItemsPage()));
    await tester.pumpAndSettle();

    // D6: removing a mute reads as 解除屏蔽 with a visibility icon.
    expect(find.byTooltip('解除屏蔽'), findsOneWidget);
    expect(find.byIcon(Icons.visibility_outlined), findsOneWidget);
  });

  testWidgets('failed tag add keeps the input for a retry', (tester) async {
    final (container, fixture, _) = await _makeWorld();
    await tester.pumpWidget(_cardApp(container, const MutedItemsPage()));
    await tester.pumpAndSettle();

    fixture.muteEditStatus = 500;
    await tester.enterText(find.byType(TextField), 'tagFail');
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(
      field.controller!.text,
      'tagFail',
      reason: 'a rejected write keeps the draft so it can be retried',
    );
    expect(
      container.read(muteStoreProvider.select((s) => s.isTagMuted('tagFail'))),
      isFalse,
    );

    // The same draft succeeds once the backend recovers.
    fixture.muteEditStatus = 200;
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    expect(
      container.read(muteStoreProvider.select((s) => s.isTagMuted('tagFail'))),
      isTrue,
    );
  });

  testWidgets('a pending mute write shows a spinner on the new row', (
    tester,
  ) async {
    // The store applies optimistically: an added tag lands in the list
    // immediately and stays marked pending until the write resolves — the
    // trailing slot swaps its button for a live spinner.
    final (container, fixture, _) = await _makeWorld();
    await tester.pumpWidget(_cardApp(container, const MutedItemsPage()));
    await tester.pumpAndSettle();

    fixture.muteEditGate = Completer<void>();
    await tester.enterText(find.byType(TextField), 'tagNew');
    await tester.tap(find.byIcon(Icons.add));
    await tester.pump();
    expect(find.widgetWithText(ListTile, 'tagNew'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byTooltip('解除屏蔽'), findsNothing);

    fixture.muteEditGate!.complete();
    await tester.pumpAndSettle();
    expect(
      container.read(muteStoreProvider.select((s) => s.isTagMuted('tagNew'))),
      isTrue,
    );
    expect(find.byTooltip('解除屏蔽'), findsOneWidget);
  });
}
