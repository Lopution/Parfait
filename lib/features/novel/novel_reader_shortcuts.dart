import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/layout/input_modality.dart';
import '../../core/novel/reader_settings.dart';
import 'novel_reader.dart';

/// Handles keyboard navigation and shortcuts for `NovelReaderStage`:
/// - `F`: toggle chrome
/// - `T`: open TOC / reading progress sheet
/// - `B`: toggle novel bookmark (online novels only)
/// - `Home` / `End`: jump to first / last page
/// - Arrows, `PageUp`/`PageDown`, `Space`/`Shift+Space`: scroll or turn pages
KeyEventResult handleNovelReaderKeyEvent(
  BuildContext context,
  KeyEvent event, {
  required NovelPageTurn pageTurn,
  required NovelReaderHandle readerHandle,
  required VoidCallback onToggleChrome,
  required VoidCallback onOpenToc,
  VoidCallback? onToggleBookmark,
}) {
  if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
    return KeyEventResult.ignored;
  }
  final hw = HardwareKeyboard.instance;
  if (hw.isAltPressed || hw.isControlPressed || hw.isMetaPressed) {
    return KeyEventResult.ignored;
  }
  if (isTextEditingFocused()) return KeyEventResult.ignored;
  final route = ModalRoute.of(context);
  if (route != null && !route.isCurrent) return KeyEventResult.ignored;

  final key = event.logicalKey;
  final shift = hw.isShiftPressed;

  if (event is KeyDownEvent && !shift) {
    if (key == LogicalKeyboardKey.keyF) {
      onToggleChrome();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyT) {
      onOpenToc();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyB && onToggleBookmark != null) {
      onToggleBookmark();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.home) {
      if (readerHandle.pageCount?.call() != null) {
        readerHandle.goToPage?.call(0, animate: false);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.end) {
      final total = readerHandle.pageCount?.call();
      if (total != null && total > 0) {
        readerHandle.goToPage?.call(total - 1, animate: false);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
  }

  if (pageTurn == NovelPageTurn.scroll) {
    final viewport = readerHandle.viewportHeight?.call() ?? 480;
    const lineStep = 72.0;
    final pageStep = math.max(lineStep, viewport * 0.85);
    final double? delta;
    if (!shift && key == LogicalKeyboardKey.arrowDown) {
      delta = lineStep;
    } else if (!shift && key == LogicalKeyboardKey.arrowUp) {
      delta = -lineStep;
    } else if (key == LogicalKeyboardKey.pageDown ||
        (!shift && key == LogicalKeyboardKey.space)) {
      delta = pageStep;
    } else if (key == LogicalKeyboardKey.pageUp ||
        (shift && key == LogicalKeyboardKey.space)) {
      delta = -pageStep;
    } else {
      delta = null;
    }
    if (delta != null) {
      readerHandle.scrollBy?.call(delta, animate: event is KeyDownEvent);
      return KeyEventResult.handled;
    }
  }

  final int? step;
  if (!shift &&
      (key == LogicalKeyboardKey.arrowRight ||
          key == LogicalKeyboardKey.arrowDown)) {
    step = 1;
  } else if (!shift &&
      (key == LogicalKeyboardKey.arrowLeft ||
          key == LogicalKeyboardKey.arrowUp)) {
    step = -1;
  } else if (key == LogicalKeyboardKey.pageDown ||
      (!shift && key == LogicalKeyboardKey.space)) {
    step = 1;
  } else if (key == LogicalKeyboardKey.pageUp ||
      (shift && key == LogicalKeyboardKey.space)) {
    step = -1;
  } else {
    step = null;
  }
  if (step == null) return KeyEventResult.ignored;
  if (readerHandle.pageCount?.call() == null) return KeyEventResult.ignored;
  readerHandle.stepPage?.call(step, animate: event is KeyDownEvent);
  return KeyEventResult.handled;
}
