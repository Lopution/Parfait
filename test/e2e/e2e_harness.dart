import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kMiddleMouseButton;
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/core/history/history_models.dart';

import '../review/review_support.dart';

Future<bool> settle(WidgetTester tester, [int seconds = 2]) =>
    settleReview(tester, limit: Duration(seconds: seconds));

Future<void> runE2eScene(
  WidgetTester tester, {
  required Future<void> Function(ReviewWorld world, GoRouter router) body,
  ReviewDevice? device,
  Map<String, ReviewResponder> api = const {},
  List<HistoryRecord> history = const [],
  int watchlater = 0,
  int localNovels = 0,
  List<Override> overrides = const [],
  String location = '/recommended',
  Locale locale = zhCN,
}) async {
  final d = device ?? reviewDevices['phone']!;
  late final ReviewWorld world;
  await tester.runAsync(
    () async => world = await ReviewWorld.open(
      ReviewSetup(
        api: api,
        history: history,
        watchlater: watchlater,
        localNovels: localNovels,
        platformCaps: d.platformCaps,
        overrides: overrides,
      ),
    ),
  );
  await reviewScene(
    tester,
    semantics: false,
    onDispose: world.container.dispose,
    () async {
      final router = await pumpReviewApp(
        tester,
        world: world,
        device: d,
        location: location,
        locale: locale,
      );
      await settleReview(tester);
      await body(world, router);
    },
  );
}

Future<void> mouseClick(
  WidgetTester tester,
  Offset at, {
  int buttons = kMiddleMouseButton,
  int settleSeconds = 2,
}) async {
  final g = await tester.createGesture(
    kind: PointerDeviceKind.mouse,
    buttons: buttons,
  );
  await g.addPointer(location: at);
  try {
    await g.down(at);
    await tester.pump();
    await g.up();
    await settle(tester, settleSeconds);
  } finally {
    await g.removePointer();
    await tester.pump();
  }
}

Future<void> middleClick(WidgetTester tester, Finder target) =>
    mouseClick(tester, tester.getCenter(target));

Future<void> tapAndSettle(
  WidgetTester tester,
  Finder target, [
  int s = 2,
]) async {
  await tester.tap(target);
  await settle(tester, s);
}

void testE2e(
  String name,
  Future<void> Function(WidgetTester, ReviewWorld, GoRouter) body, {
  ReviewDevice? device,
  Map<String, ReviewResponder> api = const {},
  List<HistoryRecord> history = const [],
  int watchlater = 0,
  int localNovels = 0,
  List<Override> overrides = const [],
  String location = '/recommended',
  Locale locale = zhCN,
}) => testWidgets(
  name,
  (t) => runE2eScene(
    t,
    device: device,
    api: api,
    history: history,
    watchlater: watchlater,
    localNovels: localNovels,
    overrides: overrides,
    location: location,
    locale: locale,
    body: (w, r) => body(t, w, r),
  ),
);
