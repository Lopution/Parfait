import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parfait/app/app.dart';
import 'package:parfait/app/icons/app_icons.dart';
import 'package:parfait/app/external_intent_bridge.dart';
import 'package:parfait/app/widgets/prompt_host.dart';
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/auth/account_repository.dart';
import 'package:parfait/core/auth/credential.dart';
import 'package:parfait/core/platform/android_intent_channel.dart';
import 'package:parfait/core/platform/intent_router.dart';
import 'package:parfait/features/home/recommended/recommended_home_page.dart';
import 'package:parfait/features/profile/user_page.dart';
import 'package:parfait/features/ranking/ranking_page.dart';

import 'helpers/fake_account.dart';
import 'helpers/prompt_host.dart';
import 'package:parfait/app/widgets/func_bottom_nav.dart';
import 'helpers/localized_app.dart';
import 'helpers/view_size.dart';
import 'helpers/pixiv_router.dart';

/// Answers [initial] and never delivers a new intent.
class _FixedIntentSource implements AndroidIntentSource {
  const _FixedIntentSource(this.initial);

  final AndroidIntentResult initial;

  @override
  Future<AndroidIntentResult> readInitial() async => initial;

  @override
  Stream<AndroidIntentResult> get onNewIntent => const Stream.empty();
}

const _signedInSnapshot = AccountMetadataSnapshot(
  accounts: [Account(id: '100', userId: 100, name: 'tester')],
  currentId: '100',
);

Widget _homeApp({AndroidIntentSource? intentSource, Locale? locale}) {
  final source =
      intentSource ??
      const _FixedIntentSource(IgnoredAndroidIntent('test: no android intent'));
  final router = pixivRouter('/recommended');
  final credentials = FakeCredentialStore(
    values: const {
      '100': Credential(accessToken: 'a-100', refreshToken: 'r-100'),
    },
  );
  final metadata = FakeAccountMetadataRepository(
    accounts: _signedInSnapshot.accounts,
    currentId: _signedInSnapshot.currentId,
  );
  return localizedRouterApp(
    router,
    overrides: [
      ...accountProviderOverrides(
        credentialStore: credentials,
        metadataRepository: metadata,
      ),
    ],
    locale: locale ?? const Locale('zh', 'CN'),
    builder: (context, child) => promptHostBuilder(
      context,
      ExternalIntentBridge(router: router, intentSource: source, child: child!),
    ),
  );
}

Future<void> _pumpHome(
  WidgetTester tester, {
  AndroidIntentSource? intentSource,
  Locale? locale,
}) async {
  // Pin a compact surface so the shell renders the bottom navigation bar
  // rather than the wide NavigationRail.
  setViewSize(tester, const Size(390, 844));
  await tester.pumpWidget(_homeApp(intentSource: intentSource, locale: locale));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets(
    'update prompt clears the shell bar and times out at eight seconds',
    (tester) async {
      await _pumpHome(tester);
      await tester.pumpAndSettle();

      final shell = tester.element(find.byType(FuncShellBottomNav));
      showUpdatePrompt(PromptHost.of(shell), version: '9.9.9', onOpen: () {});
      await tester.pump();
      await tester.pumpAndSettle();

      const message = '发现新版本：9.9.9';
      expect(find.text(message), findsOneWidget);
      // The bar anchors the prompt: the card rests fully above it.
      final card = tester.getRect(promptCard(message));
      final bar = tester.getRect(find.byType(FuncBottomNav));
      expect(card.overlaps(bar), isFalse);
      expect(card.bottom, closeTo(bar.top - 16, 0.5));

      // D2: the prompt is still shown mid-dwell; once the 8-second dwell
      // plus its exit flight have passed it is gone — the action never
      // pins it.
      await tester.pump(const Duration(seconds: 7));
      expect(find.text(message), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.text(message), findsNothing);
    },
  );

  testWidgets('C7: visited tabs stay alive and keep the first tab controller', (
    tester,
  ) async {
    await _pumpHome(tester);

    final firstRecommended = tester.state<State<RecommendedHomePage>>(
      find.byType(RecommendedHomePage),
    );

    await tester.tap(find.byIcon(AppIcons.ranking));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      find.byType(RecommendedHomePage, skipOffstage: false),
      findsOneWidget,
    );
    expect(find.byType(RankingPage, skipOffstage: false), findsOneWidget);

    await tester.tap(find.byIcon(AppIcons.home));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      identical(
        tester.state<State<RecommendedHomePage>>(
          find.byType(RecommendedHomePage),
        ),
        firstRecommended,
      ),
      isTrue,
    );
    expect(find.byType(RankingPage, skipOffstage: false), findsOneWidget);
  });

  testWidgets('C8: UserRoute delivered to home pushes the user page', (
    tester,
  ) async {
    await _pumpHome(
      tester,
      intentSource: const _FixedIntentSource(
        RoutedAndroidIntent(UserRoute(123)),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.byType(UserPage), findsOneWidget);
    expect(tester.widget<UserPage>(find.byType(UserPage)).userId, 123);
  });
}
