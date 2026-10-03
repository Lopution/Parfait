import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:parfait/app/theme/func_tokens.dart';
import 'package:parfait/app/widgets/image_overlay_button.dart';

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

/// The IconButton carries its palette as a WidgetStateProperty ButtonStyle —
/// resolve it per state instead of digging into Ink renderers.
ButtonStyle _style(WidgetTester tester) {
  final button = tester.widget<IconButton>(find.byType(IconButton));
  return button.style!;
}

Color _resolve(ButtonStyle style, String slot, Set<WidgetState> states) {
  final property = switch (slot) {
    'background' => style.backgroundColor,
    'foreground' => style.foregroundColor,
    _ => throw ArgumentError(slot),
  };
  return property!.resolve(states)!;
}

void main() {
  testWidgets('icon-only action carries a tooltip for accessibility', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        ImageOverlayButton(
          icon: const Icon(Icons.open_in_new),
          tooltip: '打开详情页',
          onPressed: () {},
        ),
      ),
    );
    await tester.pump();

    expect(find.byTooltip('打开详情页'), findsOneWidget);
  });

  testWidgets('the tap target stays >= 48x48 on every platform', (
    tester,
  ) async {
    for (final platform in [
      TargetPlatform.android,
      // Desktop themes default tapTargetSize to shrinkWrap — the padded
      // override is the contract being pinned here.
      TargetPlatform.windows,
    ]) {
      debugDefaultTargetPlatformOverride = platform;
      try {
        await tester.pumpWidget(
          _host(
            ImageOverlayButton(
              icon: const Icon(Icons.open_in_new),
              tooltip: '打开详情页',
              onPressed: () {},
            ),
          ),
        );
        await tester.pumpAndSettle();

        final size = tester.getSize(find.byType(ImageOverlayButton));
        expect(size.width, greaterThanOrEqualTo(48));
        expect(size.height, greaterThanOrEqualTo(48));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    }
  });

  testWidgets('colors come from the overlay tokens in every state', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        ImageOverlayButton(
          icon: const Icon(Icons.open_in_new),
          tooltip: '打开详情页',
          onPressed: () {},
        ),
      ),
    );
    await tester.pump();

    var style = _style(tester);
    expect(_resolve(style, 'background', {}), FuncTokens.imageControl);
    expect(_resolve(style, 'foreground', {}), FuncTokens.onImageControl);
    // Disabled keeps the same scrim so the control does not "jump" colour
    // when a page toggles the action off; only the glyph dims.
    expect(
      _resolve(style, 'background', {WidgetState.disabled}),
      FuncTokens.imageControl,
    );
    expect(
      _resolve(style, 'foreground', {WidgetState.disabled}),
      FuncTokens.onImageControl.withValues(alpha: 0.38),
    );

    await tester.pumpWidget(
      _host(
        const ImageOverlayButton(
          icon: Icon(Icons.open_in_new),
          tooltip: '打开详情页',
          onPressed: null,
        ),
      ),
    );
    await tester.pumpAndSettle();
    style = _style(tester);
    expect(
      _resolve(style, 'foreground', {WidgetState.disabled}),
      FuncTokens.onImageControl.withValues(alpha: 0.38),
    );
  });

  testWidgets('onPressed still fires through the themed style', (tester) async {
    var tapped = false;
    await tester.pumpWidget(
      _host(
        ImageOverlayButton(
          icon: const Icon(Icons.open_in_new),
          tooltip: '打开详情页',
          onPressed: () => tapped = true,
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byType(ImageOverlayButton));
    expect(tapped, isTrue);
  });

  testWidgets('buttonStyle() resolves to the same palette the widget paints', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        ImageOverlayButton(
          icon: const Icon(Icons.open_in_new),
          tooltip: '打开详情页',
          onPressed: () {},
        ),
      ),
    );
    await tester.pump();

    // AppMenuButton-style consumers apply the shared style through their
    // own IconButton — it must resolve to the same colors as the widget.
    final shared = ImageOverlayButton.buttonStyle();
    final applied = _style(tester);
    for (final states in <Set<WidgetState>>{
      const {},
      const {WidgetState.disabled},
    }) {
      expect(
        shared.backgroundColor!.resolve(states),
        applied.backgroundColor!.resolve(states),
      );
      expect(
        shared.foregroundColor!.resolve(states),
        applied.foregroundColor!.resolve(states),
      );
    }
    expect(shared.tapTargetSize, MaterialTapTargetSize.padded);
  });
}
