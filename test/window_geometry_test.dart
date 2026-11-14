import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:parfait/app/window/window_geometry.dart';

void main() {
  const workArea = Rect.fromLTWH(0, 0, 1440, 900);

  test(
    'a first launch opens at the default size, centred on the work area',
    () {
      final geometry = defaultWindowGeometry(workArea);
      expect(geometry.size, defaultWindowSize);
      expect(geometry.position, const Offset(80, 50));
      expect(geometry.maximized, isFalse);
    },
  );

  test('a work area smaller than the default size shrinks the window to 90% '
      'of it and pulls its saved corner back inside', () {
    final geometry = defaultWindowGeometry(const Rect.fromLTWH(0, 0, 900, 700));
    expect(geometry.size, const Size(810, 640));
    expect(geometry.position, Offset.zero);
  });

  test('a saved size larger than the work area shrinks to 90% of it', () {
    final geometry = fitToWorkArea(
      const WindowGeometry(size: Size(3000, 2000), position: Offset(10, 10)),
      workArea,
    );
    expect(geometry.size, const Size(1296, 810));
  });

  test('the minimum size wins on a work area too small for it', () {
    final geometry = fitToWorkArea(
      const WindowGeometry(size: Size(100, 100), position: Offset(0, 0)),
      const Rect.fromLTWH(0, 0, 400, 400),
    );
    expect(geometry.size, minimumWindowSize);
  });

  test('a saved place still visible is kept and pulled inside the edges', () {
    final geometry = fitToWorkArea(
      const WindowGeometry(size: Size(1280, 800), position: Offset(-100, 300)),
      workArea,
    );
    expect(geometry.position, const Offset(0, 100));
  });

  test('a saved place mostly off the work area is centred instead', () {
    final geometry = fitToWorkArea(
      const WindowGeometry(size: Size(1280, 800), position: Offset(-1260, 40)),
      workArea,
    );
    expect(geometry.position, const Offset(80, 50));
  });

  test('a maximized flag survives the fit', () {
    final geometry = fitToWorkArea(
      const WindowGeometry(
        size: Size(1280, 800),
        position: Offset(80, 50),
        maximized: true,
      ),
      workArea,
    );
    expect(geometry.maximized, isTrue);
    expect(geometry.size, const Size(1280, 800));
  });

  test(
    'the work area uses the visible rectangle when the platform has one',
    () {
      expect(
        workAreaOf(
          size: const Size(1920, 1080),
          visiblePosition: const Offset(0, 40),
          visibleSize: const Size(1920, 1040),
        ),
        const Rect.fromLTWH(0, 40, 1920, 1040),
      );
    },
  );

  test('a display without a visible rectangle uses its full size', () {
    expect(
      workAreaOf(size: const Size(1920, 1080)),
      const Rect.fromLTWH(0, 0, 1920, 1080),
    );
  });

  test('a saved place picks the display it overlaps most', () {
    const left = Rect.fromLTWH(-1920, 0, 1920, 1080);
    const right = Rect.fromLTWH(0, 0, 1920, 1080);
    // Across both displays, mostly on the left one.
    final mostlyLeft = const WindowGeometry(
      size: Size(1280, 800),
      position: Offset(-800, 100),
    );
    expect(workAreaFor(mostlyLeft, [right, left]), left);
    // Across both displays, mostly on the right one.
    final mostlyRight = const WindowGeometry(
      size: Size(1280, 800),
      position: Offset(-300, 100),
    );
    expect(workAreaFor(mostlyRight, [right, left]), right);
  });

  test('a saved place whose display went away belongs to none', () {
    final saved = const WindowGeometry(
      size: Size(1280, 800),
      position: Offset(-4000, 100),
    );
    expect(workAreaFor(saved, [workArea]), isNull);
  });

  test(
    'resolveWindowGeometry skips position on Wayland while preserving size',
    () {
      final restored = resolveWindowGeometry(
        width: 1100,
        height: 750,
        x: 120,
        y: 80,
        maximized: true,
        primaryArea: workArea,
        workAreas: const [workArea],
        isWayland: true,
      );
      expect(restored.size, const Size(1100, 750));
      expect(restored.maximized, isTrue);
      expect(restored.position, isNull);
    },
  );

  test(
    'resolveWindowGeometry clamps disconnected multi-monitor coordinates onto primary',
    () {
      final restored = resolveWindowGeometry(
        width: 1100,
        height: 750,
        x: -3500,
        y: 120,
        maximized: false,
        primaryArea: workArea,
        workAreas: const [workArea],
        isWayland: false,
      );
      expect(restored.size, const Size(1100, 750));
      expect(restored.position, const Offset(170, 75));
    },
  );
}
