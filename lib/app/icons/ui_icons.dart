import 'package:flutter/widgets.dart';
import 'package:forui/assets.dart';

/// Unified Lucide fine-stroke UI icons bridged from `forui`'s bundled
/// [FLucideIcons], complementing custom domain glyphs in `AppIcons` so no raw
/// Material `Icons.*` glyph leaks into app chrome (`THEME-16`).
abstract final class UiIcons {
  static const IconData add = FLucideIcons.plus;
  static const IconData arrowBack = FLucideIcons.arrowLeft;
  static const IconData arrowForward = FLucideIcons.arrowRight;
  static const IconData cancelCircle = FLucideIcons.circleX;
  static const IconData check = FLucideIcons.check;
  static const IconData checkCircle = FLucideIcons.circleCheck;
  static const IconData checklist = FLucideIcons.listChecks;
  static const IconData chevronLeft = FLucideIcons.chevronLeft;
  static const IconData chevronRight = FLucideIcons.chevronRight;
  static const IconData circleUnchecked = FLucideIcons.circle;
  static const IconData clock = FLucideIcons.clock;
  static const IconData close = FLucideIcons.x;
  static const IconData columns = FLucideIcons.columns2;
  static const IconData devices = FLucideIcons.monitorSmartphone;
  static const IconData displaySettings = FLucideIcons.slidersHorizontal;
  static const IconData dragHandle = FLucideIcons.gripHorizontal;
  static const IconData dropdown = FLucideIcons.chevronsUpDown;
  static const IconData errorFatal = FLucideIcons.octagonAlert;
  static const IconData errorOutline = FLucideIcons.circleAlert;
  static const IconData expandLess = FLucideIcons.chevronUp;
  static const IconData expandMore = FLucideIcons.chevronDown;
  static const IconData fillSuggestion = FLucideIcons.arrowUpLeft;
  static const IconData firstPage = FLucideIcons.chevronFirst;
  static const IconData hourglass = FLucideIcons.hourglass;
  static const IconData inbox = FLucideIcons.inbox;
  static const IconData more = FLucideIcons.ellipsis;
  static const IconData pause = FLucideIcons.pause;
  static const IconData pauseCircle = FLucideIcons.circlePause;
  static const IconData pin = FLucideIcons.pin;
  static const IconData pinOff = FLucideIcons.pinOff;
  static const IconData play = FLucideIcons.play;
  static const IconData pointer = FLucideIcons.mousePointer;
  static const IconData recordDot = FLucideIcons.circleDot;
  static const IconData refresh = FLucideIcons.refreshCw;
  static const IconData removeCircle = FLucideIcons.circleMinus;
  static const IconData reset = FLucideIcons.rotateCcw;
  static const IconData selectAll = FLucideIcons.checkCheck;
  static const IconData touch = FLucideIcons.hand;
  static const IconData warning = FLucideIcons.triangleAlert;
}
