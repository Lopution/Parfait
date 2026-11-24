import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/clipboard.dart';
import '../../../app/widgets/bookmark_switch_button.dart';
import '../../../core/bookmark/bookmark_models.dart';
import '../../../core/entity/illust_entity.dart';
import '../../../core/platform/image_clipboard.dart';

/// Builds the keyboard shortcut map for `ImageViewerPage`, including navigation,
/// zoom, chrome toggle, info, save (`S` / `Ctrl+S`), copy original image
/// (`Ctrl+C`), and bookmark toggle (`B`).
Map<ShortcutActivator, VoidCallback> buildImageViewerShortcuts(
  BuildContext context, {
  required IllustEntity? entity,
  required int Function() activePage,
  required VoidCallback onPageBackward,
  required VoidCallback onPageForward,
  required VoidCallback onZoomIn,
  required VoidCallback onZoomOut,
  required VoidCallback onResetZoom,
  required VoidCallback onToggleChrome,
  required VoidCallback onBack,
  required VoidCallback onSave,
  required VoidCallback onShowInfo,
}) {
  void copyImage() {
    if (entity == null || !isDesktopImageClipboardSupported) return;
    unawaited(
      copyIllustOriginalImageToClipboard(
        context,
        ProviderScope.containerOf(context),
        entity,
        pageIndex: activePage(),
      ),
    );
  }

  void bookmark() {
    if (entity == null) return;
    unawaited(
      toggleBookmark(
        context,
        BookmarkKey(BookmarkEntityType.illust, entity.id),
      ),
    );
  }

  return {
    const SingleActivator(LogicalKeyboardKey.arrowLeft): onPageBackward,
    const SingleActivator(LogicalKeyboardKey.keyK): onPageBackward,
    const SingleActivator(LogicalKeyboardKey.arrowRight): onPageForward,
    const SingleActivator(LogicalKeyboardKey.keyJ): onPageForward,
    const SingleActivator(LogicalKeyboardKey.equal): onZoomIn,
    const SingleActivator(LogicalKeyboardKey.add): onZoomIn,
    const SingleActivator(LogicalKeyboardKey.numpadAdd): onZoomIn,
    const SingleActivator(LogicalKeyboardKey.minus): onZoomOut,
    const SingleActivator(LogicalKeyboardKey.numpadSubtract): onZoomOut,
    const SingleActivator(LogicalKeyboardKey.digit0): onResetZoom,
    const SingleActivator(LogicalKeyboardKey.numpad0): onResetZoom,
    const SingleActivator(LogicalKeyboardKey.keyF): onToggleChrome,
    const SingleActivator(LogicalKeyboardKey.escape): onBack,
    const SingleActivator(LogicalKeyboardKey.backspace): onBack,
    const SingleActivator(LogicalKeyboardKey.keyS): onSave,
    const SingleActivator(LogicalKeyboardKey.keyS, control: true): onSave,
    const SingleActivator(LogicalKeyboardKey.keyS, meta: true): onSave,
    const SingleActivator(LogicalKeyboardKey.keyC, control: true): copyImage,
    const SingleActivator(LogicalKeyboardKey.keyC, meta: true): copyImage,
    const SingleActivator(LogicalKeyboardKey.keyB): bookmark,
    const SingleActivator(LogicalKeyboardKey.keyI): onShowInfo,
  };
}
