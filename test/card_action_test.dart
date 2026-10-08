import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:network_image_mock/network_image_mock.dart';
import 'package:parfait/app/haptics/haptics_driver.dart';
import 'package:parfait/app/widgets/card_actions/illust_card_actions.dart';
import 'package:parfait/app/widgets/feed/illust_card.dart';
import 'package:parfait/app/widgets/feed/muted_cover.dart';
import 'package:parfait/core/mute/mute_models.dart';
import 'package:parfait/core/mute/mute_store.dart';
import 'package:parfait/core/share/share_service.dart';
import 'package:parfait/features/settings/pages/muted_items_page.dart';
import 'package:parfait/core/watchlater/watch_later_repository.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';
import 'package:parfait/l10n/app_localizations.dart';

import 'helpers/recording_haptics.dart';
import 'helpers/card_world.dart';
import 'helpers/illust_fixtures.dart';
import 'helpers/prompt_host.dart';

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

Widget _cardApp(ProviderContainer container, Widget home) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      builder: promptHostBuilder,
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
    final (container, _, _) = await makeCardWorld();
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        _cardApp(container, IllustCard(entity: parseIllust(illustJson(7)))),
      );
      await _openSheet(tester);
    });

    final actions = container.read(illustCardActionsProvider);
    // Bookmarking stays with the card's heart.
    expect(actions.map((a) => a.id), [
      'download',
      'watch-later',
      'mute-work',
      'mute-user',
      'share',
    ]);
    for (final label in ['下载', '稍后再看', '屏蔽此作品', '屏蔽作者', '分享']) {
      expect(
        find.widgetWithText(ListTile, label),
        findsOneWidget,
        reason: 'sheet should offer "$label"',
      );
      expect(find.bySemanticsLabel(label), findsWidgets);
    }
    expect(find.widgetWithText(ListTile, '收藏'), findsNothing);
  });

  testWidgets('unmuting from the card offers Undo', (tester) async {
    final (container, _, _) = await makeCardWorld();
    await container
        .read(muteStoreProvider.notifier)
        .muteWork(const MutedWork(illustId: 7));
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        _cardApp(container, IllustCard(entity: parseIllust(illustJson(7)))),
      );
      await _openSheet(tester);
      await _tapEntry(tester, '解除屏蔽此作品');
    });
    expect(container.read(muteStoreProvider).isWorkMuted(7), isFalse);
    expect(find.text('已解除屏蔽'), findsOneWidget);

    await tester.tap(promptAction('撤销'));
    await tester.pumpAndSettle();
    expect(container.read(muteStoreProvider).isWorkMuted(7), isTrue);
  });

  testWidgets('watch-later action adds, then the sheet offers remove', (
    tester,
  ) async {
    final (container, _, repository) = await makeCardWorld();
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
    // Undo is the light-tick role.
    final haptics = recordHaptics();
    final (container, _, repository) = await makeCardWorld();
    final entity = parseIllust(illustJson(9));
    const originalAddedAt = 1726800000000;
    await repository.restoreAll('100', [
      WatchLaterEntry(addedAt: originalAddedAt, entity: entity),
    ]);
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

    // Opening the sheet by long-press played longPress.
    expect(haptics.roles, [HapticRole.longPress]);
    await tester.tap(find.text('撤销'));
    expect(haptics.roles, [HapticRole.longPress, HapticRole.select]);
    await mockNetworkImagesFor(() async {
      await tester.pump();
      await tester.pump();
    });
    final restored = await repository.list('100');
    expect(restored.map((e) => e.entity.id), [9]);
    // Undo pins the original timestamp — the row keeps its old position.
    expect(restored.single.addedAt, originalAddedAt);
  });

  testWidgets(
    'download action surfaces submission failure for an entity without '
    'original URLs',
    (tester) async {
      final (container, _, _) = await makeCardWorld();
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

  testWidgets('share action hands the formatted payload to the share service', (
    tester,
  ) async {
    final share = _RecordingShareService();
    final (container, _, _) = await makeCardWorld(shareService: share);
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
  });

  testWidgets('share fallback to clipboard shows the copy confirmation', (
    tester,
  ) async {
    final share = _RecordingShareService()
      ..outcome = ShareOutcome.copiedToClipboard;
    final (container, _, _) = await makeCardWorld(shareService: share);
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        _cardApp(container, IllustCard(entity: parseIllust(illustJson(15)))),
      );
      await _openSheet(tester);
      await _tapEntry(tester, '分享');
    });

    expect(find.text('链接已复制'), findsOneWidget);
  });

  testWidgets('mute-work action toggles the local work mute', (tester) async {
    final (container, fixture, _) = await makeCardWorld();
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
    // The management list shows what was kept at mute time.
    final kept = container.read(muteStoreProvider).works[31]!;
    expect(kept.title, entity.title);
    expect(kept.thumbnailUrl, entity.imageUrls.squareMedium);
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
    final (container, fixture, _) = await makeCardWorld();
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
    final (container, _, _) = await makeCardWorld();
    final entity = parseIllust(illustJson(51));
    await container
        .read(muteStoreProvider.notifier)
        .muteWork(const MutedWork(illustId: 51));
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

  testWidgets('failed tag add keeps the input for a retry', (tester) async {
    final (container, fixture, _) = await makeCardWorld();
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
}
