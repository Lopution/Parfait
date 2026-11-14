import 'dart:math' as math;
import 'dart:ui';

/// A desktop window's place: its size, its top-left corner in the global
/// screen space (negative on a display left of or above the primary one),
/// and whether it was maximized when the app closed.
class WindowGeometry {
  const WindowGeometry({
    required this.size,
    required this.position,
    this.maximized = false,
  });

  final Size size;
  final Offset position;
  final bool maximized;

  Rect get bounds =>
      Rect.fromLTWH(position.dx, position.dy, size.width, size.height);

  WindowGeometry copyWith({Size? size, Offset? position, bool? maximized}) =>
      WindowGeometry(
        size: size ?? this.size,
        position: position ?? this.position,
        maximized: maximized ?? this.maximized,
      );

  @override
  bool operator ==(Object other) =>
      other is WindowGeometry &&
      other.size == size &&
      other.position == position &&
      other.maximized == maximized;

  @override
  int get hashCode => Object.hash(size, position, maximized);

  @override
  String toString() =>
      'WindowGeometry(${size.width}x${size.height} at '
      '${position.dx},${position.dy}${maximized ? ', maximized' : ''})';
}

/// Opens wide enough for the task rail and a content column (NAV-20): the
/// expanded rail takes 256dp and 1280 leaves 1024 for the page.
const Size defaultWindowSize = Size(1280, 800);

/// The smallest place the shell stays usable: a collapsed rail and a
/// readable column.
const Size minimumWindowSize = Size(480, 640);

/// How much of the window must remain on a work area for its saved
/// position to be kept; less and it is centred instead.
const double keepVisibleExtent = 30;

/// The default first-launch place, centred on [workArea].
WindowGeometry defaultWindowGeometry(Rect workArea) => fitToWorkArea(
  WindowGeometry(
    size: defaultWindowSize,
    position: Offset(
      workArea.left + (workArea.width - defaultWindowSize.width) / 2,
      workArea.top + (workArea.height - defaultWindowSize.height) / 2,
    ),
  ),
  workArea,
);

/// A display's work area (its visible size excluding the taskbar), or its
/// full size where the platform reports no visible rectangle. Either way
/// the rectangle keeps the display's own origin, so a window restored to a
/// secondary display is not mistaken for one on the primary display.
Rect workAreaOf({
  required Size size,
  Offset? visiblePosition,
  Size? visibleSize,
}) {
  final origin = visiblePosition ?? Offset.zero;
  if (visibleSize != null && visibleSize.width > 0 && visibleSize.height > 0) {
    return Rect.fromLTWH(
      origin.dx,
      origin.dy,
      visibleSize.width,
      visibleSize.height,
    );
  }
  return Rect.fromLTWH(origin.dx, origin.dy, size.width, size.height);
}

/// Fits [desired] into [workArea]: at most 90% of it, never below
/// [minimumWindowSize], and centred when the saved place is mostly off the
/// work area. A saved place that is still visible is kept, pulled inside
/// the work area's edges so the window cannot hang off it.
WindowGeometry fitToWorkArea(WindowGeometry desired, Rect workArea) {
  final maxWidth = math.max(minimumWindowSize.width, workArea.width * .9);
  final maxHeight = math.max(minimumWindowSize.height, workArea.height * .9);
  final size = Size(
    desired.size.width.clamp(minimumWindowSize.width, maxWidth),
    desired.size.height.clamp(minimumWindowSize.height, maxHeight),
  );
  final saved = Rect.fromLTWH(
    desired.position.dx,
    desired.position.dy,
    size.width,
    size.height,
  );
  final position = isVisibleIn(saved, workArea)
      ? Offset(
          _inside(saved.left, workArea.left, workArea.right - size.width),
          _inside(saved.top, workArea.top, workArea.bottom - size.height),
        )
      : Offset(
          workArea.left + (workArea.width - size.width) / 2,
          workArea.top + (workArea.height - size.height) / 2,
        );
  return WindowGeometry(
    size: size,
    position: position,
    maximized: desired.maximized,
  );
}

/// Whether at least [keepVisibleExtent] of [window] lies inside
/// [workArea] on both axes.
bool isVisibleIn(
  Rect window,
  Rect workArea, {
  double minVisible = keepVisibleExtent,
}) {
  final overlap = window.intersect(workArea);
  return overlap.width >= minVisible && overlap.height >= minVisible;
}

/// The work area [saved] belongs to: the one it overlaps most, or null
/// when it overlaps none (its display went away).
Rect? workAreaFor(WindowGeometry saved, List<Rect> workAreas) {
  final bounds = saved.bounds;
  Rect? best;
  var bestArea = 0.0;
  for (final area in workAreas) {
    final overlap = bounds.intersect(area);
    if (overlap.width <= 0 || overlap.height <= 0) continue;
    final visible = overlap.width * overlap.height;
    if (visible > bestArea) {
      bestArea = visible;
      best = area;
    }
  }
  return best;
}

double _inside(double value, double start, double end) {
  if (end < start) return start;
  return value.clamp(start, end);
}

/// Resolved window restoration target supporting positionless Wayland runs.
class RestoredWindowGeometry {
  const RestoredWindowGeometry({
    required this.size,
    this.position,
    this.maximized = false,
  });

  final Size size;
  final Offset? position;
  final bool maximized;
}

/// Fits [desired] dimensions into [workArea] without moving position.
Size fitSizeToWorkArea(Size desired, Rect workArea) {
  final maxWidth = math.max(minimumWindowSize.width, workArea.width * .9);
  final maxHeight = math.max(minimumWindowSize.height, workArea.height * .9);
  final width = desired.width.isFinite
      ? desired.width.clamp(minimumWindowSize.width, maxWidth)
      : defaultWindowSize.width.clamp(minimumWindowSize.width, maxWidth);
  final height = desired.height.isFinite
      ? desired.height.clamp(minimumWindowSize.height, maxHeight)
      : defaultWindowSize.height.clamp(minimumWindowSize.height, maxHeight);
  return Size(width, height);
}

/// Resolves startup window bounds with Wayland skip-position & multi-monitor
/// fallback clamping.
RestoredWindowGeometry resolveWindowGeometry({
  required double? width,
  required double? height,
  required double? x,
  required double? y,
  required bool maximized,
  required Rect primaryArea,
  required List<Rect> workAreas,
  required bool isWayland,
}) {
  if (width == null || height == null || !width.isFinite || !height.isFinite) {
    final fallback = defaultWindowGeometry(primaryArea);
    return RestoredWindowGeometry(
      size: fallback.size,
      position: isWayland ? null : fallback.position,
      maximized: maximized,
    );
  }
  if (isWayland || x == null || y == null || !x.isFinite || !y.isFinite) {
    return RestoredWindowGeometry(
      size: fitSizeToWorkArea(Size(width, height), primaryArea),
      position: null,
      maximized: maximized,
    );
  }
  final saved = WindowGeometry(
    size: Size(width, height),
    position: Offset(x, y),
    maximized: maximized,
  );
  final targetArea = workAreaFor(saved, workAreas) ?? primaryArea;
  final fitted = fitToWorkArea(saved, targetArea);
  return RestoredWindowGeometry(
    size: fitted.size,
    position: fitted.position,
    maximized: fitted.maximized,
  );
}
