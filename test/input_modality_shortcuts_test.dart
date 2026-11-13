import 'dart:async';
import 'dart:ui' show ViewFocusDirection, ViewFocusEvent, ViewFocusState;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/layout/input_modality.dart';
import 'package:parfait/app/navigation/keyboard_back.dart';
import 'package:parfait/app/pull_to_refresh.dart';
import 'package:parfait/app/widgets/app_slider.dart';
import 'package:parfait/app/widgets/comment_composer.dart';

import 'helpers/fake_account.dart';
import 'helpers/localized_app.dart';

Future<void> _sendChord(
  WidgetTester tester, {
  required LogicalKeyboardKey key,
  LogicalKeyboardKey? modifier,
}) async {
  if (modifier != null) await tester.sendKeyDownEvent(modifier);
  await tester.sendKeyDownEvent(key);
  await tester.sendKeyUpEvent(key);
  if (modifier != null) await tester.sendKeyUpEvent(modifier);
}

Future<Object?> _invokeNavCommand(String method) async {
  const codec = StandardMethodCodec();
  final completer = Completer<ByteData?>();
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        'parfait/navigation_commands',
        codec.encodeMethodCall(MethodCall(method)),
        completer.complete,
      );
  final reply = await completer.future;
  return reply == null ? null : codec.decodeEnvelope(reply);
}

void main() {
  testWidgets(
    'InputModalityScope sets desktop/touch defaults and tracks pointer transitions',
    variant: const TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.android,
    }),
    (tester) async {
      InputModality? seen;
      await tester.pumpWidget(
        MaterialApp(
          home: InputModalityScope(
            child: Builder(
              builder: (context) {
                seen = InputModalityScope.maybeOf(context);
                return const SizedBox.expand(child: Text('probe'));
              },
            ),
          ),
        ),
      );
      expect(
        seen,
        defaultInputModalityFor(
          Theme.of(tester.element(find.text('probe'))).platform,
        ),
      );

      await tester.tap(find.text('probe'));
      await tester.pump();
      expect(seen, InputModality.touch);

      final mouse = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(mouse.hover(const Offset(50, 50)));
      await tester.pump();
      expect(seen, InputModality.pointer);

      final unknown = TestPointer(2, PointerDeviceKind.unknown);
      await tester.sendEventToBinding(unknown.down(const Offset(50, 50)));
      await tester.sendEventToBinding(unknown.up());
      await tester.pump();
      expect(seen, InputModality.pointer);
    },
  );

  testWidgets('AppSlider pointer drag does not hijack viewer arrow-key focus', (
    tester,
  ) async {
    final viewerFocus = FocusNode();
    final sliderFocus = FocusNode();
    addTearDown(viewerFocus.dispose);
    addTearDown(sliderFocus.dispose);
    var arrows = 0;
    var value = 0.5;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Focus(
            focusNode: viewerFocus,
            autofocus: true,
            onKeyEvent: (_, event) {
              if (event is KeyDownEvent &&
                  event.logicalKey == LogicalKeyboardKey.arrowRight) {
                arrows++;
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: Column(
              children: [
                AppSlider(value: value, onChanged: (v) => value = v),
                AppSlider(
                  value: 0.2,
                  focusNode: sliderFocus,
                  canRequestFocus: true,
                  onChanged: (_) {},
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(viewerFocus.hasFocus, isTrue);

    await tester.drag(find.byType(AppSlider).first, const Offset(80, 0));
    await tester.pump();
    expect(viewerFocus.hasFocus, isTrue);

    await _sendChord(tester, key: LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(arrows, 1);

    sliderFocus.requestFocus();
    await tester.pump();
    expect(sliderFocus.hasFocus, isTrue);
  });

  testWidgets(
    'KeyboardBack handles desktop back, search, refresh, editing guard, and focus loss',
    variant: const TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.macOS,
    }),
    (tester) async {
      final isMac = defaultTargetPlatform == TargetPlatform.macOS;
      final modifier = isMac
          ? LogicalKeyboardKey.metaLeft
          : LogicalKeyboardKey.controlLeft;
      final backModifier = isMac
          ? LogicalKeyboardKey.metaLeft
          : LogicalKeyboardKey.altLeft;
      final backKey = isMac
          ? LogicalKeyboardKey.bracketLeft
          : LogicalKeyboardKey.arrowLeft;

      var refreshes = 0;
      var anchorSearches = 0;
      final showAnchor = ValueNotifier(true);
      final controller = TextEditingController();
      addTearDown(showAnchor.dispose);
      addTearDown(controller.dispose);

      late final GoRouter router;
      router = GoRouter(
        initialLocation: '/recommended',
        routes: [
          GoRoute(
            path: '/recommended',
            builder: (_, _) => Scaffold(
              body: PullToRefresh(
                onRefresh: () async => refreshes++,
                child: ListView(
                  children: [
                    ValueListenableBuilder<bool>(
                      valueListenable: showAnchor,
                      builder: (_, visible, _) => visible
                          ? SearchShortcutAnchor(
                              onTrigger: () => anchorSearches++,
                              child: const Text('anchor'),
                            )
                          : const SizedBox.shrink(),
                    ),
                    TextButton(
                      onPressed: () =>
                          unawaited(router.push('/recommended/detail')),
                      child: const Text('go detail'),
                    ),
                    TextField(controller: controller),
                    const SizedBox(height: 1200),
                  ],
                ),
              ),
            ),
            routes: [
              GoRoute(
                path: 'detail',
                builder: (_, _) => const Scaffold(body: Text('detail page')),
              ),
              GoRoute(
                path: 'search/input',
                builder: (_, _) => const Scaffold(body: Text('search route')),
              ),
            ],
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        localizedRouterApp(
          router,
          builder: (_, child) => KeyboardBack(router: router, child: child!),
        ),
      );
      await tester.pumpAndSettle();

      // Back via keyboard chord, mouse side button, and Windows channel.
      for (final trigger in [
        () => _sendChord(tester, key: backKey, modifier: backModifier),
        () async {
          final mouse = TestPointer(1, PointerDeviceKind.mouse);
          await tester.sendEventToBinding(
            mouse.down(const Offset(100, 100), buttons: kBackMouseButton),
          );
          await tester.sendEventToBinding(mouse.up());
        },
        () async {
          expect(await _invokeNavCommand('forward'), isFalse);
          expect(await _invokeNavCommand('back'), isTrue);
        },
      ]) {
        await tester.tap(find.text('go detail'));
        await tester.pumpAndSettle();
        expect(find.text('detail page'), findsOneWidget);
        await trigger();
        await tester.pumpAndSettle();
        expect(find.text('detail page'), findsNothing);
      }

      // Search & refresh shortcuts while not editing.
      await _sendChord(
        tester,
        key: LogicalKeyboardKey.keyF,
        modifier: modifier,
      );
      await _sendChord(tester, key: LogicalKeyboardKey.slash);
      await tester.pump();
      expect(anchorSearches, 2);

      await _sendChord(tester, key: LogicalKeyboardKey.f5);
      await tester.pumpAndSettle();
      await _sendChord(
        tester,
        key: LogicalKeyboardKey.keyR,
        modifier: modifier,
      );
      await tester.pumpAndSettle();
      expect(refreshes, 2);

      // While editing TextField: `/` does not search, Escape unfocuses only.
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await _sendChord(tester, key: LogicalKeyboardKey.slash);
      await _sendChord(tester, key: backKey, modifier: backModifier);
      await tester.pump();
      expect(anchorSearches, 2);
      expect(
        primaryFocus?.context?.findAncestorWidgetOfExactType<EditableText>(),
        isNotNull,
      );

      await _sendChord(tester, key: LogicalKeyboardKey.escape);
      await tester.pump();
      expect(
        primaryFocus?.context?.findAncestorWidgetOfExactType<EditableText>(),
        isNull,
      );

      // Anchor absent falls back to pushing /recommended/search/input.
      showAnchor.value = false;
      await tester.pump();
      await _sendChord(
        tester,
        key: LogicalKeyboardKey.keyF,
        modifier: modifier,
      );
      await tester.pumpAndSettle();
      expect(find.text('search route'), findsOneWidget);

      // Window focus loss releases held modifier keys.
      await tester.sendKeyDownEvent(backModifier);
      expect(
        isMac
            ? HardwareKeyboard.instance.isMetaPressed
            : HardwareKeyboard.instance.isAltPressed,
        isTrue,
      );
      WidgetsBinding.instance.handleViewFocusChanged(
        const ViewFocusEvent(
          viewId: 0,
          state: ViewFocusState.unfocused,
          direction: ViewFocusDirection.undefined,
        ),
      );
      expect(
        isMac
            ? HardwareKeyboard.instance.isMetaPressed
            : HardwareKeyboard.instance.isAltPressed,
        isFalse,
      );
    },
  );

  testWidgets(
    'CommentComposer submits on Ctrl/Cmd+Enter in pointer mode and keeps Enter for newline',
    variant: const TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.macOS,
    }),
    (tester) async {
      final isMac = defaultTargetPlatform == TargetPlatform.macOS;
      final modifier = isMac
          ? LogicalKeyboardKey.metaLeft
          : LogicalKeyboardKey.controlLeft;
      final sent = <String>[];

      await tester.pumpWidget(
        localizedApp(
          overrides: [...await signedInAccountOverrides()],
          body: InputModalityScope(
            initialModality: InputModality.pointer,
            child: CommentComposer(
              onSend: (text) async => sent.add(text),
              onStampSend: (_) async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'hello');
      await tester.pump();

      await _sendChord(tester, key: LogicalKeyboardKey.enter);
      await tester.pump();
      expect(sent, isEmpty);

      await _sendChord(
        tester,
        key: LogicalKeyboardKey.enter,
        modifier: modifier,
      );
      await tester.pumpAndSettle();
      expect(sent, ['hello']);
    },
  );
}
