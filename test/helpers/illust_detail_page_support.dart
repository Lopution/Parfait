import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:network_image_mock/network_image_mock.dart';

import 'package:parfait/app/pixiv_image.dart';
import 'package:parfait/app/navigation/routes.dart';
import 'package:parfait/core/entity/illust_store.dart';
import 'package:parfait/app/motion/motion_tokens.dart';
import 'package:parfait/app/motion/state_fade.dart';
import 'package:parfait/features/illust/detail/illust_detail_page.dart';
import 'package:parfait/core/share/share_service.dart';

import 'illust_fixtures.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';
import 'prompt_host.dart';

// Shared by the illust_detail_page tests.
/// Records what the detail page hands to the platform share boundary —
/// the system sheet is an external boundary, so a recording stand-in is
/// legitimate here (the page itself always runs).
class RecordingShareService implements ShareService {
  final List<SharePayload> payloads = [];
  ShareOutcome outcome = ShareOutcome.openedSheet;

  @override
  Future<ShareOutcome> share(
    SharePayload payload, {
    Rect? sharePositionOrigin,
  }) async {
    payloads.add(payload);
    return outcome;
  }
}

/// Scrolls the detail page down until the related section is on screen,
/// then lets the on-demand request start and land: visibility is reported
/// after a frame, the request starts on the next one, and the result needs
/// one more.
Future<void> scrollToRelated(WidgetTester tester) async {
  for (var i = 0; i < 2; i++) {
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -1400));
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pump(const Duration(milliseconds: 200));
}

/// Opens the detail AppBar's ⋮ menu. The tooltip comes from
/// MaterialLocalizations.showMenuTooltip ('Show menu' / '显示菜单').
Future<void> openDetailMenu(
  WidgetTester tester, {
  String tooltip = 'Show menu',
}) async {
  await tester.tap(find.byTooltip(tooltip));
  await tester.pumpAndSettle();
}

/// The selection bar's count, or null outside the page-selection mode.
String? selectionCount(WidgetTester tester) {
  if (downloadSelectedButton.evaluate().isEmpty) return null;
  return (tester.widget<AppBar>(find.byType(AppBar)).title! as Text).data;
}

/// The selection bar's download action.
final downloadSelectedButton = find.byTooltip('Download selected pages');

Future<void> pumpDetail(
  WidgetTester tester,
  ProviderContainer container, {
  bool seedStore = true,
  int illustId = 42,
  Locale? locale,
  bool useRouter = false,
  bool reduceMotion = false,
  double textScale = 1,
}) async {
  if (seedStore) {
    container.read(illustStoreProvider).mergeAll([
      parseIllust(illustJson(illustId, pageCount: 2, withMetaPages: true)),
    ]);
  }
  final router = useRouter
      ? createPixivRouter(initialLocation: '/recommended/illust/$illustId')
      : null;
  if (router != null) addTearDown(router.dispose);
  Widget app = router == null
      ? MaterialApp(
          builder: promptHostBuilder,
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: const [
            Locale('zh', 'CN'),
            Locale('en', 'US'),
            Locale('ja', 'JP'),
            Locale('ru', 'RU'),
          ],
          locale: locale,
          home: IllustDetailPage(illustId: illustId),
        )
      : MaterialApp.router(
          builder: promptHostBuilder,
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: const [
            Locale('zh', 'CN'),
            Locale('en', 'US'),
            Locale('ja', 'JP'),
            Locale('ru', 'RU'),
          ],
          locale: locale,
          routerConfig: router,
        );
  if (reduceMotion) {
    app = MotionScope(reduce: true, child: app);
  }
  if (textScale != 1) {
    final base = app;
    app = Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: base,
      ),
    );
  }
  await mockNetworkImagesFor(() async {
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: app),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  });
}

Future<void> longPressImage(WidgetTester tester) async {
  final center = tester.getCenter(find.byType(PixivImage).first);
  final gesture = await tester.startGesture(center);
  await tester.pump(const Duration(milliseconds: 700));
  await gesture.up();
  await tester.pump();
}

// Hidden chrome stays mounted (Opacity 0 + ExcludeSemantics — dropping it
// from the tree races the semantics flush). Visibility assertions check
// the bars' opacity rather than whether finders still see the (mounted)
// counter text.
void expectViewerChrome(WidgetTester tester, {required bool visible}) {
  final bars = tester
      .widgetList<Opacity>(
        find.byWidgetPredicate((w) => w is Opacity && w.alwaysIncludeSemantics),
      )
      .toList();
  expect(bars.length, 2, reason: 'top + bottom chrome bars');
  for (final bar in bars) {
    expect(bar.opacity, visible ? 1.0 : 0.0);
  }
}

/// The fixture's `create_date` as the device shows it.
final fixtureCreateDate = DateTime.parse('2026-08-01T10:00:00+09:00').toLocal();

/// The info block's metadata line without its icons.
String dateText(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('illust-detail-date'))).data!;

/// The stats block's figures, left to right.
List<String> statFigures(WidgetTester tester) => [
  for (final text in tester.widgetList<Text>(
    find.descendant(
      of: find.byKey(const Key('illust-detail-stats')),
      matching: find.byType(Text),
    ),
  ))
    text.data!,
];

/// Opacity of the page's skeleton-to-content [StateFade].
double stateFadeOpacity(WidgetTester tester) => tester
    .widget<FadeTransition>(
      find
          .descendant(
            of: find.byType(StateFade),
            matching: find.byType(FadeTransition),
          )
          .first,
    )
    .opacity
    .value;
