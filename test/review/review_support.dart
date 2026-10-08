import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'package:parfait/app/app.dart';
import 'package:parfait/app/navigation/routes.dart';
import 'package:parfait/app/scroll_behavior.dart';
import 'package:parfait/app/theme/replica_theme.dart';
import 'package:parfait/core/platform/android_intent_channel.dart';
import 'package:parfait/core/platform/intent_router.dart';
import 'package:parfait/core/settings/app_settings.dart';
import 'package:parfait/core/settings/settings_controller.dart';
import 'package:parfait/l10n/app_localizations.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';

import 'review_device.dart';
import 'review_world.dart';

export 'review_device.dart';
export 'review_fixtures.dart';
export 'review_world.dart';

/// Every scene and film carries this tag; tool/review.sh runs them.
const reviewTags = ['review'];

const zhCN = Locale('zh', 'CN');

const _captureKey = ValueKey('review-surface');

/// Runs one scene with the semantics tree on — it is on whenever an
/// accessibility service is, GKD included — and restores the device after.
/// The tester checks for leftover semantics handles before tear-downs run,
/// so the handle is released here rather than in addTearDown.
Future<T> reviewScene<T>(WidgetTester tester, Future<T> Function() body) async {
  final handle = tester.ensureSemantics();
  try {
    return await body();
  } finally {
    handle.dispose();
    // Swap in an empty tree so the scene's timers are cancelled with it,
    // then let one-shot timers (retry delays, prompt dwell) run out. Real
    // IO started in the fake zone — a database query from the page just
    // unmounted — needs its own turns to finish, or the store's close in
    // tear-down waits on it forever.
    await tester.pumpWidget(const SizedBox());
    await _ioTurns(tester, 10);
    await tester.pump(const Duration(minutes: 2));
    await _ioTurns(tester, 10);
    resetReviewDevice(tester);
  }
}

/// Boots the real app — `createPixivRouter` inside the app's [AppChrome],
/// over the review world's providers — at [location] and returns the
/// router for scripted steps; [settleReview] then lets it load. The startup
/// gate, update check and pipeline warm-up are left out: a scene starts on
/// its page.
///
/// [semanticsDebugger] draws the semantics overlay: the nodes, groups and
/// labels a TalkBack traversal walks.
Future<GoRouter> pumpReviewApp(
  WidgetTester tester, {
  required ReviewWorld world,
  String location = '/recommended',
  Brightness brightness = Brightness.light,
  Locale locale = zhCN,
  double textScale = 1.0,
  bool semanticsDebugger = false,
}) async {
  applyReviewDevice(
    tester,
    locale: locale,
    textScale: textScale,
    brightness: brightness,
  );
  // The app language is a setting that a first run seeds from the system
  // locale. AppSettings.defaults reads the engine's dispatcher, which a
  // test leaves at en_US, so the harness makes the first run's choice.
  await tester.runAsync(() async {
    final settings = world.container.read(settingsProvider.notifier);
    await world.container.read(settingsProvider.future);
    await settings.selectLanguage(locale.toLanguageTag());
  });
  // VisibilityDetector debounces on a 500ms timer every repaint re-arms;
  // zero reports synchronously, so no timer outlives the scene.
  VisibilityDetectorController.instance.updateInterval = Duration.zero;
  final theme = replicaTheme(brightness);
  final router = createPixivRouter(initialLocation: location);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: world.container,
      child: RepaintBoundary(
        key: _captureKey,
        child: _maybeSemanticsOverlay(
          semanticsDebugger,
          Consumer(
            builder: (context, ref, _) => MaterialApp.router(
              theme: theme,
              darkTheme: theme,
              themeMode: brightness == Brightness.dark
                  ? ThemeMode.dark
                  : ThemeMode.light,
              localizationsDelegates: appLocalizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: locale,
              debugShowCheckedModeBanner: false,
              routerConfig: router,
              scrollBehavior: const FuncScrollBehavior(),
              builder: (context, child) => AppChrome(
                settings:
                    ref.watch(settingsProvider).value ?? AppSettings.defaults(),
                router: router,
                intentSource: const _NoIntents(),
                child: child!,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return router;
}

/// MaterialApp's own overlay labels in a style without a font family —
/// the test engine's boxes — so the harness draws it with the review font.
Widget _maybeSemanticsOverlay(bool show, Widget app) => show
    ? SemanticsDebugger(
        labelStyle: const TextStyle(
          fontFamily: 'Roboto',
          fontSize: 10,
          height: 0.8,
          color: Color(0xFF000000),
        ),
        child: app,
      )
    : app;

/// Gives real IO its event-loop turns — the image worker, the cache and
/// sqlite all do real IO — then pumps 100ms frames until nothing more is
/// scheduled. Returns whether the scene came to rest within [limit]; one
/// that keeps animating (a spinner that never stops) is still captured,
/// and the caller marks the shot. [settle] false — a loading state, whose
/// spinner runs by design — pumps [limit] / 4 and returns false.
Future<bool> settleReview(
  WidgetTester tester, {
  bool settle = true,
  Duration limit = const Duration(seconds: 10),
}) async {
  const frame = Duration(milliseconds: 100);
  await _ioTurns(tester, 40);
  if (!settle) {
    await tester.pump(limit ~/ 4);
    return false;
  }
  for (var waited = Duration.zero; waited < limit; waited += frame) {
    if (!tester.binding.hasScheduledFrame) return true;
    // A request started by a frame (a section scrolled into view) needs
    // real IO turns of its own to land.
    await _ioTurns(tester, 1);
    await tester.pump(frame, EnginePhase.sendSemanticsUpdate);
  }
  return !tester.binding.hasScheduledFrame;
}

/// [count] turns of the real event loop, each followed by a frame that
/// delivers what completed.
Future<void> _ioTurns(WidgetTester tester, int count) async {
  for (var i = 0; i < count; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 2)),
    );
    await tester.pump();
  }
}

/// The whole app surface as a PNG, at device density by default.
Future<Uint8List> captureReviewPng(
  WidgetTester tester, {
  double pixelRatio = reviewDpr,
}) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_captureKey),
  );
  final bytes = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: pixelRatio);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data!.buffer.asUint8List();
  });
  return bytes!;
}

/// The run directory and its manifest. Each scene file runs in its own
/// isolate, so entries are appended to `manifest.tsv` line by line and
/// tool/review.sh renders the table once every file has run.
abstract final class ReviewRun {
  static final dir =
      '$reviewOutDir/runs/${Platform.environment['PARFAIT_REVIEW_RUN'] ?? 'adhoc'}';

  static void record(
    String kind,
    String name,
    String location,
    String detail,
    String path,
  ) {
    final manifest = File('$dir/manifest.tsv')
      ..parent.createSync(recursive: true);
    manifest.writeAsStringSync(
      '$kind\t$name\t$location\t$detail\t$path\n',
      mode: FileMode.append,
      flush: true,
    );
  }
}

/// Writes the current surface to `shots/<name>.png`.
Future<void> saveShot(
  WidgetTester tester,
  String name, {
  required String location,
  required String detail,
}) async {
  final path = 'shots/$name.png';
  File('${ReviewRun.dir}/$path')
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(await captureReviewPng(tester));
  ReviewRun.record('shot', name, location, detail, path);
}

/// A rendering of a page besides the base one: light, Chinese, text scale
/// 1.0, GKD on and TalkBack off.
enum ShotVariant {
  dark('dark'),
  en('en'),
  ja('ja'),
  ru('ru'),
  largeText('text1.3'),
  talkBack('talkback');

  const ShotVariant(this.suffix);

  final String suffix;
}

/// English, Japanese and Russian: shot only where text can overflow.
const overflowVariants = {ShotVariant.en, ShotVariant.ja, ShotVariant.ru};

/// Before-capture steps: open a sheet, push the viewer over the detail page
/// that loaded its work. The scene settles again afterwards.
typedef ShotSteps = Future<void> Function(WidgetTester tester, GoRouter router);

/// Registers a page [state] at [location] as one test per variant — the
/// base shot plus each of [variants], dark by default — so a page that
/// breaks does not hide the shots after it. A loading [state] does not
/// settle: its spinner never stops.
void testShot(
  String name, {
  required String location,
  String state = 'content',
  ReviewSetup setup = const ReviewSetup(),
  Set<ShotVariant> variants = const {ShotVariant.dark},
  bool semanticsDebugger = false,
  ShotSteps? before,
}) {
  for (final variant in <ShotVariant?>[null, ...variants]) {
    final shotName = variant == null ? name : '$name-${variant.suffix}';
    testWidgets(shotName, (tester) async {
      await reviewShot(
        tester,
        shotName,
        location: location,
        state: state,
        setup: variant == ShotVariant.talkBack
            ? setup.copyWith(touchExploration: true)
            : setup,
        brightness: variant == ShotVariant.dark
            ? Brightness.dark
            : Brightness.light,
        locale: switch (variant) {
          ShotVariant.en => const Locale('en', 'US'),
          ShotVariant.ja => const Locale('ja', 'JP'),
          ShotVariant.ru => const Locale('ru', 'RU'),
          _ => zhCN,
        },
        textScale: variant == ShotVariant.largeText ? 1.3 : 1.0,
        semanticsDebugger: semanticsDebugger,
        before: before,
      );
    }, tags: reviewTags);
  }
}

/// One page state: a fresh world from [setup], the app at [location], then
/// a shot named [name].
Future<void> reviewShot(
  WidgetTester tester,
  String name, {
  required String location,
  String state = 'content',
  ReviewSetup setup = const ReviewSetup(),
  Brightness brightness = Brightness.light,
  Locale locale = zhCN,
  double textScale = 1.0,
  bool semanticsDebugger = false,
  ShotSteps? before,
}) async {
  final settle = state != 'loading';
  await reviewScene(tester, () async {
    final world = await tester.runAsync(() => ReviewWorld.open(setup));
    final router = await pumpReviewApp(
      tester,
      world: world!,
      location: location,
      brightness: brightness,
      locale: locale,
      textScale: textScale,
      semanticsDebugger: semanticsDebugger,
    );
    var rested = await settleReview(tester, settle: settle);
    if (before != null) {
      await before(tester, router);
      rested = await settleReview(tester, settle: settle);
    }
    if (settle && !rested) {
      // ignore: avoid_print
      print('review: $name still animating after 10s; shot marked unsettled');
    }
    await saveShot(
      tester,
      name,
      location: location,
      detail: [
        state,
        if (settle && !rested) 'UNSETTLED',
        if (brightness == Brightness.dark) 'dark',
        if (locale != zhCN) locale.languageCode,
        if (textScale != 1.0) 'text ${textScale}x',
        if (setup.touchExploration) 'talkback',
        if (semanticsDebugger) 'semantics overlay',
      ].join(', '),
    );
  });
}

/// Records a scripted interaction at 60 Hz: each [frame] gives real IO a
/// turn, advances the fake clock one vsync and captures the surface. The
/// gesture helpers stamp pointer events with that clock, so velocity — a
/// fling, a swipe back — comes out as a finger would make it. [write] saves
/// the frames and contact sheets of 30 frames, each labelled with its
/// number, time and the share of pixels changed since the frame before.
class FilmRecorder {
  FilmRecorder(this.tester, this.name, this.location);

  final WidgetTester tester;
  final String name;

  /// Where the film starts.
  final String location;
  final _frames = <(Duration, Uint8List)>[];
  var _clock = Duration.zero;

  static const vsync = Duration(microseconds: 16667);

  /// Films capture below device density: a square corner or a frozen frame
  /// reads as well at 1.5x, and a hundred frames stay quick to encode.
  static const pixelRatio = 1.5;

  /// Frames a long press holds down: past the 500ms long-press timeout.
  static const longPressFrames = 36;

  /// The fake time since the film started.
  Duration get clock => _clock;

  int get length => _frames.length;

  Future<void> frame() async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
    await tester.pump(vsync);
    _clock += vsync;
    _frames.add((
      _clock,
      await captureReviewPng(tester, pixelRatio: pixelRatio),
    ));
  }

  Future<void> frames(int count) async {
    for (var i = 0; i < count; i++) {
      await frame();
    }
  }

  /// Captures frames until [quiet] frames in a row schedule nothing more —
  /// the interaction has come to rest and no reply it waited on (a bookmark
  /// write, a page load) is still landing — or until [max] frames.
  Future<void> untilSettled({int max = 120, int quiet = 8}) async {
    var idle = 0;
    for (var i = 0; i < max && idle < quiet; i++) {
      await frame();
      idle = tester.binding.hasScheduledFrame ? 0 : idle + 1;
    }
  }

  Future<TestGesture> _down(Finder finder) async {
    bool found;
    try {
      found = finder.evaluate().isNotEmpty;
    } on StateError {
      // `.first` and `.last` finders throw on no match.
      found = false;
    }
    if (!found) {
      throw StateError('film $name, frame $length: nothing on screen $finder');
    }
    final gesture = await tester.createGesture();
    await gesture.down(tester.getCenter(finder.first), timeStamp: _clock);
    return gesture;
  }

  /// Down on the first match of [finder], [hold] frames, up, then the
  /// reaction until it rests.
  Future<void> tap(Finder finder, {int hold = 3}) async {
    final gesture = await _down(finder);
    await frames(hold);
    await gesture.up(timeStamp: _clock);
    await untilSettled();
  }

  Future<void> longPress(Finder finder) => tap(finder, hold: longPressFrames);

  /// A finger on the first match of [finder] moving by [offset] over [count] frames at a
  /// constant speed, then lifting while still moving — a fling, unless
  /// [hold] frames of standing still come before the lift.
  Future<void> swipe(
    Finder finder,
    Offset offset, {
    int count = 10,
    int hold = 0,
  }) async {
    final gesture = await _down(finder);
    final step = offset / count.toDouble();
    for (var i = 0; i < count; i++) {
      await gesture.moveBy(step, timeStamp: _clock + vsync);
      await frame();
    }
    await frames(hold);
    await gesture.up(timeStamp: _clock);
    await untilSettled();
  }

  /// The keyboard sliding in ([show]) or out over [count] frames the way
  /// the engine reports it: the view's bottom inset changes every frame.
  Future<void> keyboard({
    required bool show,
    double height = 320,
    int count = 15,
  }) async {
    for (var i = 1; i <= count; i++) {
      final t = Curves.easeOutCubic.transform(i / count);
      final inset = height * (show ? t : 1 - t);
      tester.view.viewInsets = FakeViewPadding(bottom: inset * reviewDpr);
      await frame();
    }
    await untilSettled();
  }

  Future<void> write(String notes) async {
    final dir = Directory('${ReviewRun.dir}/films/$name')
      ..createSync(recursive: true);
    final tiles = <img.Image>[];
    img.Image? previous;
    for (final (index, (time, bytes)) in _frames.indexed) {
      File(
        '${dir.path}/f${index.toString().padLeft(3, '0')}.png',
      ).writeAsBytesSync(bytes);
      final frame = img.copyResize(img.decodePng(bytes)!, width: 300);
      final change = previous == null ? 0.0 : _changed(previous, frame);
      previous = frame;
      final thumb = frame.clone();
      img.fillRect(
        thumb,
        x1: 0,
        y1: 0,
        x2: 210,
        y2: 22,
        color: img.ColorRgba8(0, 0, 0, 180),
      );
      img.drawString(
        thumb,
        '#$index  ${(time.inMicroseconds / 1000).toStringAsFixed(0)}ms  '
        '${(change * 100).toStringAsFixed(1)}%',
        font: img.arial14,
        x: 6,
        y: 4,
        color: img.ColorRgb8(255, 255, 0),
      );
      tiles.add(thumb);
    }
    if (tiles.isEmpty) {
      // A script that failed before its first frame: keep the notes, which
      // carry the error, rather than fail on an empty contact sheet.
      File('${dir.path}/notes.md').writeAsStringSync('# $name\n\n$notes\n');
      return;
    }
    const columns = 6;
    const rows = 5;
    const gap = 6;
    final tileWidth = tiles.first.width;
    final tileHeight = tiles.first.height;
    for (var page = 0; page * columns * rows < tiles.length; page++) {
      final pageTiles = tiles.skip(page * columns * rows).take(columns * rows);
      final pageRows = (pageTiles.length + columns - 1) ~/ columns;
      final sheet = img.Image(
        width: columns * tileWidth + (columns + 1) * gap,
        height: pageRows * tileHeight + (pageRows + 1) * gap,
      );
      img.fill(sheet, color: img.ColorRgb8(24, 24, 24));
      for (final (index, tile) in pageTiles.indexed) {
        img.compositeImage(
          sheet,
          tile,
          dstX: gap + (index % columns) * (tileWidth + gap),
          dstY: gap + (index ~/ columns) * (tileHeight + gap),
        );
      }
      File(
        '${dir.path}/sheet-${page.toString().padLeft(2, '0')}.png',
      ).writeAsBytesSync(img.encodePng(sheet));
    }
    File('${dir.path}/notes.md').writeAsStringSync('# $name\n\n$notes\n');
    ReviewRun.record(
      'film',
      name,
      location,
      '${_frames.length} frames',
      'films/$name',
    );
  }
}

/// The share of pixels that differ visibly between two frames. A pop — a
/// card snapping to size, a snapshot swapped for the live page — is one
/// large value between quiet ones.
double _changed(img.Image before, img.Image after) {
  const threshold = 16;
  var changed = 0;
  for (final pixel in after) {
    final old = before.getPixel(pixel.x, pixel.y);
    if ((pixel.r - old.r).abs() > threshold ||
        (pixel.g - old.g).abs() > threshold ||
        (pixel.b - old.b).abs() > threshold) {
      changed++;
    }
  }
  return changed / (after.width * after.height);
}

/// Drives the app through a [FilmRecorder].
typedef FilmScript = Future<void> Function(FilmRecorder film, GoRouter router);

/// Registers one interaction film as its own test: a fresh world from
/// [setup], the app settled at [location], then [script] on camera.
/// [notes] says what to look for in the frames; it lands in notes.md.
void testFilm(
  String name, {
  required String location,
  required String notes,
  required FilmScript script,
  ReviewSetup setup = const ReviewSetup(),
  Brightness brightness = Brightness.light,
}) {
  testWidgets(name, (tester) async {
    await reviewScene(tester, () async {
      final world = await tester.runAsync(() => ReviewWorld.open(setup));
      final router = await pumpReviewApp(
        tester,
        world: world!,
        location: location,
        brightness: brightness,
      );
      await settleReview(tester);
      final film = FilmRecorder(tester, name, location);
      try {
        await script(film, router);
      } catch (error) {
        // The frames up to the failure are what explains it.
        await film.write(
          '$notes\n\nSCRIPT FAILED at frame ${film.length}: $error',
        );
        rethrow;
      }
      await film.write(notes);
    });
  }, tags: reviewTags);
}

class _NoIntents implements AndroidIntentSource {
  const _NoIntents();

  @override
  Future<AndroidIntentResult> readInitial() async =>
      const IgnoredAndroidIntent('review');

  @override
  Stream<AndroidIntentResult> get onNewIntent => const Stream.empty();
}
