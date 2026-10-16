import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show Scaffold;
import 'package:parfait/app/pixiv_image.dart';
import 'package:parfait/core/settings/app_settings.dart';
import 'package:parfait/core/settings/settings_controller.dart';

import 'review_support.dart';

/// Route pushes and pops, branch switches and re-tap to top.
void main() {
  final back = find.byTooltip('返回');

  testFilm(
    'nav/page-push-pop',
    // The full settings list; `/settings` itself is the "me" dashboard.
    location: '/settings/all',
    notes:
        'A plain page: the theme settings slide in over the settings hub and '
        'slide back out. The entering page stays live — its switches are '
        'drawn, not a frozen snapshot — and the hub reappears without a '
        'stale press highlight on the tile that was tapped.',
    script: (film, router) async {
      await film.tap(find.text('主题'), hold: 6);
      await film.tap(back.last);
    },
  );

  testFilm(
    'nav/hero-detail',
    location: '/recommended',
    notes:
        'Hero into the detail page from a feed card and back. The finger '
        'rests 250ms, past the press delay, so the card is scaled down when '
        'it lifts: the card springs back under the transition, not frozen '
        'pressed in it (ux3 #7). The detail page covers the bottom bar, '
        'which leaves and returns with the feed. The image flies from the '
        'card to the '
        'pager; detail content (title, author, follow button) is live while '
        'it arrives; on the way back the card takes the image without a '
        'gap, a square-cornered frame or a late pop to full size.',
    script: (film, router) async {
      await film.tap(find.byType(PixivImage), hold: 15);
      await film.frames(20);
      await film.tap(back.last);
    },
  );

  testFilm(
    'nav/viewer-open-close',
    location: '/recommended/illust/1000',
    notes:
        'The viewer opening from the detail image and closing with the back '
        'button: the black backdrop fades, the image keeps its place, the '
        'system bars hide and return.',
    script: (film, router) async {
      await film.tap(find.byType(PixivImage));
      await film.frames(10);
      await film.tap(back.last);
    },
  );

  testFilm(
    'nav/branch-switch',
    location: '/recommended',
    notes:
        'Bottom bar: home → ranking → home. The branches slide side by '
        'side toward the chosen destination under a still bar; the entering '
        'branch is live, the leaving one slides as one texture; the '
        'indicator pill moves with the selection.',
    script: (film, router) async {
      await film.tap(find.text('排行'));
      await film.tap(find.text('推荐'));
    },
  );

  testFilm(
    'nav/retap-to-top',
    location: '/recommended',
    notes:
        'Scrolled down the home feed, tapping the selected home destination '
        'again scrolls back to the top.',
    script: (film, router) async {
      await film.swipe(find.text('illust 1004'), const Offset(0, -1400));
      // Scrolling down hid the bottom bar; a short scroll back up returns
      // it before the tap, as a thumb would.
      await film.swipe(
        find.byType(PixivImage).hitTestable().first,
        const Offset(0, 300),
        count: 15,
        hold: 2,
      );
      await film.tap(find.text('推荐'));
    },
  );

  for (final style in PageTransitionStyle.values) {
    testFilm(
      'nav/hero-detail-back-gesture-${style.name}',
      location: '/recommended',
      notes:
          'The ${style.name} transition, back gesture on the detail page '
          'opened from a feed card. Halfway, then cancelled: the page follows '
          'the finger as any page does in this style, the image leaves its '
          'spot toward the card, and both return on the cancel. Then a '
          'committed gesture: the page leaves with the style, the feed moves '
          'with it, the image lands on the card without a gap or a jump, and '
          'nothing cuts the image wrongly while the page shrinks or slides.',
      script: (film, router) async {
        final tester = film.tester;
        final container = ProviderScope.containerOf(
          tester.element(find.byType(Scaffold).first),
        );
        await tester.runAsync(
          () => container
              .read(settingsProvider.notifier)
              .setPageTransitionStyle(style),
        );
        await film.tap(find.byType(PixivImage), hold: 6);
        await film.frames(45);
        for (final commit in [false, true]) {
          await _backGesture('startBackGesture', 0);
          for (var i = 1; i <= 15; i++) {
            await _backGesture('updateBackGestureProgress', i / 30);
            await film.frame();
          }
          await _backGesture(
            commit ? 'commitBackGesture' : 'cancelBackGesture',
          );
          await film.frames(40);
        }
      },
    );
  }
}

/// The Android predictive back gesture from the left edge, which some ROMs
/// never deliver to the app (they send a plain back on release instead).
Future<void> _backGesture(String method, [double? progress]) {
  final data = const StandardMethodCodec().encodeMethodCall(
    MethodCall(
      method,
      progress == null
          ? null
          : {
              'touchOffset': <double>[20 + 300 * progress, 400],
              'progress': progress,
              'swipeEdge': 0,
            },
    ),
  );
  return TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage('flutter/backgesture', data, (_) {});
}
