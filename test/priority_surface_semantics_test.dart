// §7 screen-reader representative paths — the three priority surfaces
// (author header, artwork viewer, comment composer). These are widget-tree
// semantic assertions only: TalkBack/Narrator device runs stay marked
// "unverified" in the acceptance ledger — a clean semantic tree here does
// not imply the AT path was exercised.
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:network_image_mock/network_image_mock.dart';

import 'package:parfait/features/illust/viewer/image_viewer_page.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';

import 'helpers/image_network.dart';

Widget _host(Widget child) {
  return withStalledImages(
    MaterialApp(
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: appLocalizationsDelegates,
      home: Scaffold(body: child),
    ),
  );
}

void main() {
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

    // Chrome controls are named buttons: the page counter (jump sheet)
    // and fit.
    expect(
      tester.getSemantics(find.byTooltip('跳转到页码')),
      isSemantics(isButton: true, hasTapAction: true),
    );
    expect(
      tester.getSemantics(find.byTooltip('适应屏幕')),
      isSemantics(isButton: true, hasTapAction: true),
    );
  });
}
