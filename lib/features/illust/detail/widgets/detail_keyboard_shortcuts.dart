import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../../app/clipboard.dart';
import '../../../../app/layout/input_modality.dart';
import '../../../../app/widgets/bookmark_switch_button.dart';
import '../../../../core/bookmark/bookmark_models.dart';
import '../../../../core/bookmark/bookmark_store.dart';
import '../../../../core/entity/illust_entity.dart';
import '../../../../core/platform/image_clipboard.dart';
import '../detail_page_activity.dart';
import '../../illust_actions.dart';

/// Desktop keyboard shortcuts for `IllustDetailPage`:
/// - `B`: toggle bookmark
/// - `Shift+B`: open bookmark create/edit sheet
/// - `Ctrl/Cmd+S`: download all pages
/// - `Ctrl/Cmd+C`: copy page 1 original image (desktop clipboard, skipped while
///   a text field or `SelectableRegion` owns focus so text copying works)
class DetailKeyboardShortcuts extends ConsumerStatefulWidget {
  const DetailKeyboardShortcuts({
    super.key,
    required this.entity,
    required this.child,
  });

  final IllustEntity entity;
  final Widget child;

  @override
  ConsumerState<DetailKeyboardShortcuts> createState() =>
      _DetailKeyboardShortcutsState();
}

class _DetailKeyboardShortcutsState
    extends ConsumerState<DetailKeyboardShortcuts> {
  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKeyEvent);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKeyEvent);
    super.dispose();
  }

  bool _onKeyEvent(KeyEvent event) {
    if (!mounted || event is! KeyDownEvent) return false;
    if (!DetailPageActivity.of(context)) return false;
    if (!TickerMode.valuesOf(context).enabled) return false;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return false;
    if (isTextEditingFocused()) return false;

    final hw = HardwareKeyboard.instance;
    final primaryModifier = hw.isControlPressed || hw.isMetaPressed;
    final key = event.logicalKey;

    if (!primaryModifier &&
        !hw.isAltPressed &&
        key == LogicalKeyboardKey.keyB) {
      final bookmarkKey = BookmarkKey(
        BookmarkEntityType.illust,
        widget.entity.id,
      );
      if (hw.isShiftPressed) {
        final unsettled =
            ref.read(bookmarkStoreProvider)[bookmarkKey]?.isUnsettled ?? false;
        if (!unsettled) {
          unawaited(
            showBookmarkEditSheet(
              context,
              bookmarkKey,
              title: widget.entity.title,
            ),
          );
        }
        return true;
      }
      unawaited(toggleBookmark(context, bookmarkKey));
      return true;
    }

    if (primaryModifier && !hw.isAltPressed && !hw.isShiftPressed) {
      if (key == LogicalKeyboardKey.keyS) {
        unawaited(downloadAllIllustPages(context, ref, widget.entity));
        return true;
      }
      if (key == LogicalKeyboardKey.keyC && isDesktopImageClipboardSupported) {
        final focusCtx = FocusManager.instance.primaryFocus?.context;
        if (focusCtx?.findAncestorWidgetOfExactType<SelectableRegion>() !=
            null) {
          return false;
        }
        unawaited(
          copyIllustOriginalImageToClipboard(
            context,
            ProviderScope.containerOf(context),
            widget.entity,
            pageIndex: 0,
          ),
        );
        return true;
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
