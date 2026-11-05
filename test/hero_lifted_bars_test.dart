import 'dart:async';

import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parfait/app/motion/hero_transition.dart';
import 'package:parfait/app/navigation/func_page.dart';

import 'helpers/hero_flight.dart';
import 'helpers/view_size.dart';
import 'helpers/waits.dart';

/// A card page's bars ride over a card flight (TRANS-10).
void main() {
  testWidgets('a card flight lifts the card page\'s bars over the image: '
      'they slide and fade away as it opens and back as it returns', (
    tester,
  ) async {
    // A card right under a 100px app bar, over a 100px bottom bar.
    final navigator = await _pumpCardPage(
      tester,
      topBar: const ColoredBox(color: Colors.green),
      body: ListView(
        children: [
          Align(
            alignment: Alignment.topLeft,
            child: _art(
              const IllustHeroCardFrame(child: SizedBox.square(dimension: 200)),
            ),
          ),
        ],
      ),
      bottomInset: true,
      bottomBar: const LiftableShadow(
        shadows: [BoxShadow(blurRadius: 4)],
        child: _bottomBar,
      ),
    );
    const top = Rect.fromLTRB(0, 0, 400, 100);
    const bottom = Rect.fromLTRB(0, 700, 400, 800);
    bool realShadow() =>
        (tester.state(find.byType(LiftableShadow, skipOffstage: false))
                    as dynamic)
                .debugCasting
            as bool;
    // Each bar [shown] of the way in, its content as faded.
    void expectBars(double shown) {
      final bars = liftedBars(tester);
      expect(bars.map((bar) => bar.opacity), everyElement(shown));
      expect(bars.map((bar) => bar.rect), [
        top.translate(0, -100 * (1 - shown)),
        bottom.translate(0, 100 * (1 - shown)),
      ]);
      // The bottom bar's shadow moves with the lifted copy; the real one
      // holds off. The top bar casts none.
      expect(bars.map((bar) => bar.shadows), [0, 1]);
      expect(realShadow(), isFalse);
    }

    double shown() => liftedBars(tester).first.opacity;
    List<Rect> covered() => _covered(tester);

    _openCard(navigator);
    await tester.pump();
    await tester.pump();
    // Takeoff: the bars where they were, over the image, which the app
    // bar no longer cuts; the real ones covered.
    expectBars(1);
    expect(covered(), [top, bottom]);
    expect(heroPaintClipRect(tester)!.top, 0);
    await tester.pump(const Duration(milliseconds: 150));
    final opening = shown();
    expect(opening, inExclusiveRange(0, 1));
    expectBars(opening);
    await tester.pumpAndSettle();
    expect(liftedBars(tester), isEmpty);
    expect(covered(), isEmpty);
    expect(realShadow(), isTrue);

    navigator.pop();
    await tester.pump();
    await tester.pump();
    expectBars(0);
    expect(covered(), [top, bottom]);
    await tester.pump(const Duration(milliseconds: 150));
    final returning = shown();
    expect(returning, inExclusiveRange(0, 1));
    expectBars(returning);
    await tester.pump(const Duration(milliseconds: 240));
    expect(shown(), greaterThan(returning));
    await tester.pumpAndSettle();
    expect(liftedBars(tester), isEmpty);
    // Repainted once the flight lets go, with no frame left to ask for it.
    expect(realShadow(), isTrue);
  });

  // The card page's bars that leave themselves out (LiftableBar) need no
  // cover, and the feed under them shows past its viewport and its tab
  // body's clip while a lifted copy has not slid over it yet.
  testWidgets('a card flight shows the feed under the bars it lifts, and '
      'puts the bars and clips back as it lands', (tester) async {
    final scroll = ScrollController(initialScrollOffset: 200);
    addTearDown(scroll.dispose);
    // A 100px top bar over a tab body of 150px rows scrolled by 200, the
    // card the third.
    final moved = ValueNotifier(false);
    addTearDown(moved.dispose);
    final navigator = await _pumpCardPage(
      tester,
      moved: moved,
      topBar: const LiftableBar(
        child: ColoredBox(color: Colors.green, child: SizedBox.expand()),
      ),
      body: Stack(
        key: const ValueKey('tab body'),
        fit: StackFit.expand,
        children: [
          ListView(
            controller: scroll,
            children: [
              for (var i = 0; i < 8; i++)
                SizedBox(
                  key: ValueKey('row $i'),
                  height: 150,
                  child: i == 2
                      ? Align(
                          alignment: Alignment.topLeft,
                          child: _art(
                            const IllustHeroCardFrame(
                              child: SizedBox.square(dimension: 150),
                            ),
                          ),
                        )
                      : null,
                ),
            ],
          ),
        ],
      ),
      bottomBar: const LiftableBar(child: _bottomBar),
    );
    List<Rect> covered() => _covered(tester);
    List<bool> barsOut() => [
      for (final bar in tester.renderObjectList(
        find.byWidgetPredicate(
          (widget) => '${widget.runtimeType}' == '_LiftableBarBox',
          skipOffstage: false,
        ),
      ))
        (bar as dynamic).debugLiftedOut as bool,
    ];
    List<Clip> clips() => [
      tester
          .renderObject<RenderViewportBase>(
            find.byType(Viewport, skipOffstage: false),
          )
          .clipBehavior,
      tester
          .renderObject<RenderStack>(
            find.byKey(const ValueKey('tab body'), skipOffstage: false),
          )
          .clipBehavior,
    ];
    // The first row is laid out under the top bar, past the viewport.
    expect(
      tester
          .getRect(find.byKey(const ValueKey('row 0'), skipOffstage: false))
          .top,
      -100,
    );
    expect(clips(), [Clip.hardEdge, Clip.hardEdge]);

    for (final push in [true, false]) {
      if (push) {
        _openCard(navigator);
      } else {
        navigator.pop();
      }
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(liftedBars(tester), hasLength(2), reason: 'push: $push');
      expect(covered(), isEmpty);
      expect(barsOut(), [true, true]);
      expect(clips(), [Clip.none, Clip.none]);
      if (push) {
        // The navigator moves mid-flight, as a branch's across a layout
        // breakpoint: the bars are lifted again once it has laid out.
        moved.value = true;
        await tester.pump();
        await tester.pump();
        expect(barsOut(), [true, true]);
        expect(clips(), [Clip.none, Clip.none]);
      }
      // Bars and clips are back in the frame the lifted copies go: a frame
      // later the bars flashed out (11-05). (Under the opened page the card
      // page is not painted at all.)
      await pumpUntil(
        tester,
        () => liftedBars(tester).isEmpty,
        step: const Duration(milliseconds: 16),
      );
      expect(clips(), [Clip.hardEdge, Clip.hardEdge]);
      // The bottom bar floats over the opened page too.
      expect(push ? barsOut().last : barsOut(), push ? false : [false, false]);
      await tester.pumpAndSettle();
    }
  });
}

const _bottomBar = ColoredBox(color: Colors.blue, child: SizedBox(height: 100));

PageRoute<void> _page(
  BuildContext context,
  Widget child, {
  bool shared = false,
}) =>
    FuncPage<void>(
          transitionDuration: const Duration(milliseconds: 400),
          reverseTransitionDuration: const Duration(milliseconds: 400),
          sharedElement: shared,
          child: child,
        ).createRoute(context)
        as PageRoute<void>;

Widget _art(Widget child) => Hero(
  tag: 'card',
  flightShuttleBuilder: illustHeroFlightShuttleBuilder,
  child: child,
);

/// A card page, [body] under a 100px [topBar] (over a 100px inset when
/// [bottomInset]), in its own Navigator, with [bottomBar] floating over it
/// from the page around, as the home shell's.
Future<NavigatorState> _pumpCardPage(
  WidgetTester tester, {
  required Widget topBar,
  required Widget body,
  bool bottomInset = false,
  required Widget bottomBar,
  ValueNotifier<bool>? moved,
}) async {
  setViewSize(tester, const Size(400, 800));
  final heroes = HeroController();
  addTearDown(heroes.dispose);
  final navigatorKey = GlobalKey<NavigatorState>();
  late NavigatorState navigator;
  final cardNavigator = Navigator(
    key: navigatorKey,
    observers: [heroes],
    onGenerateRoute: (_) => _page(
      navigatorKey.currentContext!,
      Builder(
        builder: (context) {
          navigator = Navigator.of(context);
          return Scaffold(
            appBar: PreferredSize(
              preferredSize: const Size.fromHeight(100),
              child: topBar,
            ),
            body: body,
            bottomNavigationBar: bottomInset
                ? const SizedBox(height: 100)
                : null,
          );
        },
      ),
    ),
  );
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (root) => Stack(
          children: [
            if (moved == null)
              cardNavigator
            else
              ValueListenableBuilder(
                valueListenable: moved,
                builder: (_, moved, child) => moved
                    ? Padding(padding: EdgeInsets.zero, child: child)
                    : child!,
                child: cardNavigator,
              ),
            Positioned(left: 0, right: 0, bottom: 0, child: bottomBar),
          ],
        ),
      ),
    ),
  );
  return navigator;
}

/// The card's work page, opened with a shared-element flight.
void _openCard(NavigatorState navigator) => unawaited(
  navigator.push(
    _page(
      navigator.context,
      Align(
        alignment: Alignment.topCenter,
        child: _art(const SizedBox.square(dimension: 400)),
      ),
      shared: true,
    ),
  ),
);

List<Rect> _covered(WidgetTester tester) =>
    (tester.renderObject(find.byType(HeroBarsCover)) as dynamic)
            .debugLastPaintedRects
        as List<Rect>;
