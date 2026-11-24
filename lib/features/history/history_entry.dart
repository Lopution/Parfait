import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/rendering.dart'
    show BoxHitTestEntry, BoxHitTestResult, HitTestEntry, RenderProxyBox;
import 'package:flutter/services.dart' show HardwareKeyboard;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/format/app_format.dart';
import '../../app/icons/app_icons.dart';
import '../../app/layout/input_modality.dart';
import '../../app/motion/press_scale.dart';
import '../../app/navigation/home_shell_metrics.dart';
import '../../app/navigation/route_facade.dart';
import '../../app/pixiv_image.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../app/widgets/entity_row.dart';
import '../../app/widgets/feed/illust_card.dart';
import '../../app/widgets/selectable_tile.dart';
import '../../core/entity/illust_entity.dart';
import '../../core/entity/illust_store.dart';
import '../../core/history/history_models.dart';
import '../../core/novel/novel_entity.dart';
import '../../core/novel/novel_store.dart';

/// One grid tile in [HistoryPage], wrapping live store cards or snapshot
/// fallbacks with selection and desktop Ctrl/Cmd+Click handling.
class HistoryEntry extends ConsumerWidget {
  const HistoryEntry({
    super.key,
    required this.record,
    required this.recordKey,
    required this.managing,
    required this.selected,
    required this.onToggle,
    required this.onEnterManaging,
  });

  final HistoryRecord record;

  /// The encoded feed key (content type in the high bits) — selection
  /// tracks records by it, so an illust and a novel sharing a numeric id
  /// never collide.
  final int recordKey;
  final bool managing;
  final bool selected;
  final ValueChanged<int> onToggle;
  final ValueChanged<int> onEnterManaging;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Known-illust cells render the shared IllustCard; its own long-press
    // would open the card action sheet, but in history the gesture is the
    // selection-mode entry/toggle, so the page supplies the callback.
    final longPress = managing
        ? () => onToggle(recordKey)
        : () => onEnterManaging(recordKey);
    final child = switch (record.contentType) {
      HistoryContentType.illust => _IllustHistoryEntry(
        record: record,
        entity: ref.watch(illustStoreProvider).get(record.contentId),
        onLongPress: longPress,
      ),
      HistoryContentType.novel => _NovelHistoryEntry(
        record: record,
        entity: ref.watch(
          novelStoreProvider.select((store) => store[record.contentId]),
        ),
      ),
    };
    return _CtrlClickInterceptor(
      shouldIntercept: () {
        if (managing) return false;
        final modality =
            InputModalityScope.maybeOf(context) ??
            defaultInputModalityFor(Theme.of(context).platform);
        if (modality != InputModality.pointer) return false;
        final kbd = HardwareKeyboard.instance;
        return kbd.isControlPressed || kbd.isMetaPressed;
      },
      onTap: () => onEnterManaging(recordKey),
      child: SelectableTile(
        managing: managing,
        selected: selected,
        onToggle: () => onToggle(recordKey),
        onLongPress: longPress,
        child: child,
      ),
    );
  }
}

/// Intercepts Ctrl/Cmd+Click in pointer mode before the child work card can
/// claim the tap and push a detail route, turning the click into selection
/// mode entry instead.
class _CtrlClickInterceptor extends SingleChildRenderObjectWidget {
  const _CtrlClickInterceptor({
    required this.shouldIntercept,
    required this.onTap,
    required super.child,
  });

  final bool Function() shouldIntercept;
  final VoidCallback onTap;

  @override
  _RenderCtrlClickInterceptor createRenderObject(BuildContext context) =>
      _RenderCtrlClickInterceptor(
        shouldIntercept: shouldIntercept,
        onTap: onTap,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderCtrlClickInterceptor renderObject,
  ) {
    renderObject
      ..shouldIntercept = shouldIntercept
      ..onTap = onTap;
  }
}

class _RenderCtrlClickInterceptor extends RenderProxyBox {
  _RenderCtrlClickInterceptor({
    required this.shouldIntercept,
    required this.onTap,
  });

  bool Function() shouldIntercept;
  VoidCallback onTap;
  int? _activePointer;
  Offset? _downPosition;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!size.contains(position)) return false;
    if (shouldIntercept()) {
      result.add(BoxHitTestEntry(this, position));
      return true;
    }
    return super.hitTest(result, position: position);
  }

  @override
  void handleEvent(PointerEvent event, HitTestEntry entry) {
    if (event is PointerDownEvent &&
        (event.buttons & kPrimaryButton) != 0 &&
        shouldIntercept()) {
      _activePointer = event.pointer;
      _downPosition = event.position;
    } else if (event is PointerUpEvent && event.pointer == _activePointer) {
      final down = _downPosition;
      _activePointer = null;
      _downPosition = null;
      if (down != null && (event.position - down).distance <= 18.0) {
        onTap();
      }
    } else if (event is PointerCancelEvent && event.pointer == _activePointer) {
      _activePointer = null;
      _downPosition = null;
    }
  }
}

/// The history page's own Hero scope (TRANS-07): a work seen lately is
/// often on a feed still mounted in another branch.
const _heroScope = 'history';

class _IllustHistoryEntry extends StatelessWidget {
  const _IllustHistoryEntry({
    required this.record,
    required this.entity,
    required this.onLongPress,
  });

  final HistoryRecord record;
  final IllustEntity? entity;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final entity = this.entity;
    if (entity != null) {
      // Shared object contract: the card consumes FeedItemExtent for its
      // preview height and carries the visit date in the meta slot.
      return IllustCard(
        entity: entity,
        heroScope: _heroScope,
        meta: EntityMetaText(AppFormat.relative(context, record.lastViewedAt)),
        onLongPress: onLongPress,
      );
    }
    return _HistoryCardFrame(
      lastViewedAt: record.lastViewedAt,
      child: InkWell(
        onTap: () =>
            openIllust(context, record.contentId, heroScope: _heroScope),
        child: _SnapshotEntry(record: record, icon: AppIcons.illust),
      ),
    );
  }
}

class _NovelHistoryEntry extends StatelessWidget {
  const _NovelHistoryEntry({required this.record, required this.entity});

  final HistoryRecord record;
  final NovelEntity? entity;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final title = entity?.title ?? record.snapshot.title;
    final author = entity?.user.name ?? record.snapshot.authorName;
    final coverUrl = entity?.coverImageUrl ?? record.snapshot.coverUrl;
    void open() => openNovel(context, record.contentId);
    return _HistoryCardFrame(
      lastViewedAt: record.lastViewedAt,
      // The square cell follows the object contract: PressScale feedback,
      // an explicit Semantics label, rounded cover and a type badge so
      // novels stay distinguishable in the mixed history grid.
      child: PressScale(
        child: Semantics(
          container: true,
          button: true,
          image: true,
          label: '$title, $author',
          onTap: open,
          child: GestureDetector(
            excludeFromSemantics: true,
            onTap: open,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Stack(
                  children: [
                    AspectRatio(
                      aspectRatio: 1,
                      child: ClipRRect(
                        borderRadius: FuncShape.card,
                        child: coverUrl == null
                            ? ColoredBox(
                                color: colorScheme.surfaceContainer,
                                child: const Icon(
                                  AppIcons.localNovel,
                                  size: 42,
                                ),
                              )
                            : LayoutBuilder(
                                builder: (context, constraints) =>
                                    PixivImage.feed(
                                      coverUrl,
                                      layoutWidth: constraints.maxWidth,
                                    ),
                              ),
                      ),
                    ),
                    const Positioned(
                      left: 7,
                      top: 7,
                      child: EntityBadge(icon: AppIcons.localNovel),
                    ),
                  ],
                ),
                Padding(
                  padding: _titlePadding,
                  child: Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Padding(
                  padding: _linePadding,
                  child: Text(
                    author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A history cell's title, under the cover.
const _titlePadding = EdgeInsets.fromLTRB(
  IllustCard.textIndent,
  FuncSpacing.sm,
  IllustCard.textIndent,
  0,
);

/// A history cell's author and date lines.
const _linePadding = EdgeInsets.symmetric(horizontal: IllustCard.textIndent);

/// A cell drawn here (a novel, a work not in the store) laid out like the
/// shared [IllustCard] beside it: flat, the text on the card's indent.
class _HistoryCardFrame extends StatelessWidget {
  const _HistoryCardFrame({required this.lastViewedAt, required this.child});

  final DateTime lastViewedAt;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        child,
        Padding(
          padding: _linePadding,
          child: EntityMetaText(AppFormat.relative(context, lastViewedAt)),
        ),
      ],
    );
  }
}

class _SnapshotEntry extends StatelessWidget {
  const _SnapshotEntry({required this.record, required this.icon});

  final HistoryRecord record;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SnapshotCover(record: record, icon: icon),
        Padding(
          padding: _titlePadding,
          child: Text(
            record.snapshot.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        Padding(
          padding: _linePadding,
          child: Text(
            record.snapshot.authorName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

class _SnapshotCover extends StatelessWidget {
  const _SnapshotCover({required this.record, required this.icon});

  final HistoryRecord record;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1,
      child: ClipRRect(
        borderRadius: FuncShape.card,
        child: record.snapshot.coverUrl == null
            ? ColoredBox(
                color: Theme.of(context).colorScheme.surfaceContainer,
                child: Icon(icon, size: 42),
              )
            : LayoutBuilder(
                builder: (context, constraints) => PixivImage.feed(
                  record.snapshot.coverUrl!,
                  layoutWidth: constraints.maxWidth.isFinite
                      ? constraints.maxWidth
                      : HomeShellChrome.contentSizeOf(context).width / 2,
                ),
              ),
      ),
    );
  }
}
