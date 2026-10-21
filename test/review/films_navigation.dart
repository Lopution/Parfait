import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parfait/app/motion/hero_rect_clip.dart';
import 'package:parfait/app/pixiv_image.dart';

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
    'nav/hero-me-history',
    location: '/recommended',
    setup: ReviewSetup(history: reviewHistory()),
    notes:
        'From the Me tab\'s recent row into a work the home feed loaded, and '
        'back. The square cover grows into the whole image on the detail '
        'page and shrinks back into the same cover: the crop opens out '
        'from the middle of the wide image, never a squeezed or letterboxed '
        'frame, and the row keeps its order after the landing.',
    script: (film, router) async {
      await film.tap(find.text('我的'));
      await film.tap(find.bySemanticsLabel('illust 1001'), hold: 6);
      await film.frames(10);
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

  testFilm(
    'nav/hero-detail-back-gesture',
    location: '/recommended',
    notes:
        'The back gesture on the detail page opened from a feed card. While '
        'the finger moves nothing does; on the commit the page leaves as on '
        'back: its content fades out onto its background first, then the '
        'background, so the feed is whole when the image lands on its card, '
        'without a gap or a jump, and nothing cuts the image wrongly.',
    script: (film, router) async {
      await film.tap(find.byType(PixivImage), hold: 6);
      await film.frames(45);
      await _backGesture('startBackGesture', 0);
      for (var i = 1; i <= 15; i++) {
        await _backGesture('updateBackGestureProgress', i / 30);
        await film.frame();
      }
      await _backGesture('commitBackGesture');
      await film.frames(40);
    },
  );

  // Hero flights cut short, over every image shape a flight treats
  // differently: a 4:3 card, the top of a 1:2.1 one, a 1:6 one on its
  // square thumbnail (no Hero), a 3:1 panorama, a 1:1.9 page that runs
  // past the detail capsule.
  final shapes = ReviewSetup(
    api: {
      '/v1/illust/recommended': reviewJson({
        'illusts': [
          for (final id in reviewShapesFeed)
            reviewIllustJson(id, pageCount: id.isEven ? 3 : 1),
        ],
        'next_url': null,
      }),
    },
  );
  const interruptNotes =
      'Opening Heroes cut short by back at several points, then left to '
      'land: the image turns around from where it is and lands on its '
      'card; the detail page fades out from where its fade-in got to, '
      'without a jump; no chrome of either page (status bar, tab row, '
      'bottom bar, app bar, action capsule, page counter) is drawn over '
      'the image or cut out of it; the card badges leave and return '
      'alike; nothing pops in or out at the landing.';
  for (final (shape, id) in [
    ('wide', 1500),
    ('tall-crop', 1501),
    ('square-thumb', 1502),
    ('panorama', 1503),
    ('past-capsule', 1504),
  ]) {
    testFilm(
      'nav/hero-interrupt-$shape',
      location: '/recommended',
      setup: shapes,
      notes: interruptNotes,
      script: (film, router) async {
        final card = film.tester.getCenter(
          find.bySemanticsLabel(RegExp('^illust $id,')).first,
        );
        for (final at in [3, 8, 14]) {
          await _open(film, card);
          await film.frames(at);
          await _systemBack();
          await film.untilSettled();
        }
        // Back and forth faster than a flight.
        for (final at in [4, 4, 4, 4]) {
          await _open(film, card);
          await film.frames(at);
          await _systemBack();
          await film.frames(at);
        }
        await film.untilSettled();
      },
    );
  }

  testFilm(
    'nav/hero-interrupt-under-tabs',
    location: '/recommended',
    setup: shapes,
    notes:
        '$interruptNotes The feed is scrolled so the tall card sits half '
        'under the tab row: the image leaves and lands clipped by the tab '
        'row, never over it, and the tab row never cuts the image on the '
        'detail page.',
    script: (film, router) async {
      await film.swipe(
        find.bySemanticsLabel(RegExp('^illust 1505,')),
        const Offset(0, -160),
        hold: 4,
      );
      final card = film.tester.getCenter(
        find.bySemanticsLabel(RegExp('^illust 1501,')).first,
      );
      for (final at in [4, 12]) {
        await _open(film, card);
        await film.frames(at);
        await _systemBack();
        await film.untilSettled();
      }
      for (final at in [4, 4, 4]) {
        await _open(film, card);
        await film.frames(at);
        await _systemBack();
        await film.frames(at);
      }
      await film.untilSettled();
      // Back, then the card again while the image is still on its way
      // home: it flies to the detail page and lands there.
      await _open(film, card);
      await film.frames(8);
      await _systemBack();
      await film.frames(5);
      await _open(film, card);
      await film.untilSettled();
      await _systemBack();
      await film.untilSettled();
    },
  );

  testFilm(
    'nav/hero-interrupt-gesture',
    location: '/recommended',
    setup: shapes,
    notes:
        '$interruptNotes The back here is the predictive back gesture, '
        'started mid-flight and committed after a few frames.',
    script: (film, router) async {
      final card = film.tester.getCenter(
        find.bySemanticsLabel(RegExp('^illust 1501,')).first,
      );
      for (final at in [4, 12]) {
        await _open(film, card);
        await film.frames(at);
        await _backGesture('startBackGesture', 0);
        for (var i = 1; i <= 4; i++) {
          await _backGesture('updateBackGestureProgress', i / 20);
          await film.frame();
        }
        await _backGesture('commitBackGesture');
        await film.untilSettled();
      }
    },
  );

  testFilm(
    'nav/hero-interrupt-me-history',
    location: '/recommended',
    setup: ReviewSetup(history: reviewHistory()),
    notes: '$interruptNotes From the Me tab\'s recent row.',
    script: (film, router) async {
      await film.tap(find.text('我的'));
      final cover = film.tester.getCenter(
        find.bySemanticsLabel('illust 1001').first,
      );
      for (final at in [4, 12]) {
        await _open(film, cover);
        await film.frames(at);
        await _systemBack();
        await film.untilSettled();
      }
      for (final at in [4, 4, 4]) {
        await _open(film, cover);
        await film.frames(at);
        await _systemBack();
        await film.frames(at);
      }
      await film.untilSettled();
    },
  );

  for (final (shape, id) in [('tall', 1501), ('panorama', 1503)]) {
    testFilm(
      'nav/hero-interrupt-viewer-$shape',
      location: '/recommended',
      setup: shapes,
      notes:
          'The viewer opening from the detail image, cut short by back at '
          'several points: the image returns to the detail page, the black '
          'stage fades from where it got to, the system bars come back, '
          'and the detail chrome (app bar, page counter, capsule) is not '
          'drawn over or cut out of the image.',
      script: (film, router) async {
        await film.tap(find.bySemanticsLabel(RegExp('^illust $id,')));
        await film.untilSettled();
        final image = film.tester.getCenter(
          find.byType(PixivImage).hitTestable().first,
        );
        for (final at in [4, 12]) {
          await _open(film, image);
          await film.frames(at);
          await _systemBack();
          await film.untilSettled();
        }
        for (final at in [4, 4, 4]) {
          await _open(film, image);
          await film.frames(at);
          await _systemBack();
          await film.frames(at);
        }
        await film.untilSettled();
      },
    );
  }
}

/// Taps [at] and films until a Hero flight is in the air (or 30 frames: a
/// card without a Hero opens without one). A point, not a finder: while
/// the image flies home its card or detail image is hidden.
Future<void> _open(FilmRecorder film, Offset at) async {
  await _tapUp(film, at);
  for (var i = 0; i < 30; i++) {
    if (find.byType(HeroRectClip).evaluate().isNotEmpty) return;
    await film.frame();
  }
}

/// A tap that does not wait for the reaction to settle: down, two frames,
/// up.
Future<void> _tapUp(FilmRecorder film, Offset at) async {
  final tester = film.tester;
  final gesture = await tester.createGesture();
  await gesture.down(at, timeStamp: film.clock);
  await film.frames(2);
  await gesture.up(timeStamp: film.clock);
}

/// The system back (button, or a back gesture the ROM sends as a plain
/// back on release).
Future<void> _systemBack() {
  final data = const JSONMethodCodec().encodeMethodCall(
    const MethodCall('popRoute'),
  );
  return TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage('flutter/navigation', data, (_) {});
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
