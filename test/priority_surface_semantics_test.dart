// §7 screen-reader representative paths — the three priority surfaces
// (author header, artwork viewer, comment composer). These are widget-tree
// semantic assertions only: TalkBack/Narrator device runs stay marked
// "unverified" in the acceptance ledger — a clean semantic tree here does
// not imply the AT path was exercised.
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:network_image_mock/network_image_mock.dart';

import 'package:pixiv_func/features/comments/comment_input.dart';
import 'package:pixiv_func/features/illust/viewer/image_viewer_page.dart';
import 'package:pixiv_func/features/profile/profile_header_delegate.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';

Widget _host(Widget child) {
  return MaterialApp(
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN')],
    localizationsDelegates: appLocalizationsDelegates,
    home: Scaffold(body: child),
  );
}

void main() {
  testWidgets('author header stat chips announce label+value as one node', (
    tester,
  ) async {
    ProfileStatisticData stat({VoidCallback? onTap}) => ProfileStatisticData(
      id: 'following',
      icon: Icons.favorite_outline,
      label: '关注',
      value: 12,
      onTap: onTap,
    );

    // A tappable chip is a single button node announcing "label, value" —
    // the inner visuals are excluded so the pair never double-announces.
    await tester.pumpWidget(
      _host(ProfileStatistic(statistic: stat(onTap: () {}), compact: true)),
    );
    expect(find.bySemanticsLabel('关注, 12'), findsOneWidget);
    expect(
      tester.getSemantics(find.bySemanticsLabel('关注, 12')),
      isSemantics(isButton: true, hasTapAction: true),
    );

    // A read-only stat keeps the same announcement but loses the button
    // role — no phantom affordance.
    await tester.pumpWidget(_host(ProfileStatistic(statistic: stat())));
    expect(find.bySemanticsLabel('关注, 12'), findsOneWidget);
    expect(
      tester.getSemantics(find.bySemanticsLabel('关注, 12')),
      isSemantics(isButton: false, hasTapAction: false),
    );
  });

  testWidgets('viewer pages announce a per-page image and chrome controls', (
    tester,
  ) async {
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(_host(const ImageViewerPage(urls: ['u1', 'u2'])));
      await tester.pump();
    });

    // The media surface announces the page position as an image node —
    // without it a screen reader hits a silent canvas (PRD R4).
    expect(find.bySemanticsLabel('第 1 页，共 2 页'), findsOneWidget);
    expect(
      tester.getSemantics(find.bySemanticsLabel('第 1 页，共 2 页')),
      isSemantics(isImage: true),
    );

    // Chrome controls are named buttons: page sheet, fit, fullscreen.
    expect(find.byTooltip('跳转到页码'), findsOneWidget);
    expect(
      tester.getSemantics(find.byTooltip('适应屏幕')),
      isSemantics(isButton: true, hasTapAction: true),
    );
    expect(
      tester.getSemantics(find.byTooltip('进入全屏')),
      isSemantics(isButton: true, hasTapAction: true),
    );
  });

  testWidgets('comment composer exposes field, send and reply context', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        Column(
          children: [
            const Expanded(child: SizedBox()),
            CommentComposer(
              replyTo: 'alice',
              onCancelReply: () {},
              onSend: (_) async {},
              onStampSend: (_) async {},
            ),
          ],
        ),
      ),
    );
    await tester.pump();

    // The reply context is one announcement unit ("回复给 alice") with its
    // own named cancel affordance.
    expect(find.bySemanticsLabel('回复给: alice'), findsOneWidget);
    expect(
      tester.getSemantics(find.byTooltip('取消回复')),
      isSemantics(isButton: true, hasTapAction: true),
    );

    // The field is a text-input node; send/emoji/stamp are named buttons.
    expect(
      tester.getSemantics(find.byType(EditableText)),
      isSemantics(isTextField: true),
    );
    expect(find.byTooltip('发送'), findsOneWidget);
    expect(
      tester.getSemantics(find.byTooltip('Emoji')),
      isSemantics(isButton: true, hasTapAction: true),
    );
    expect(
      tester.getSemantics(find.byTooltip('Stamp')),
      isSemantics(isButton: true, hasTapAction: true),
    );
  });
}
