import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable, listEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/icons/app_icons.dart';
import '../../app/icons/ui_icons.dart';
import '../../app/motion/hero_transition.dart';
import '../../app/motion/motion_tokens.dart';
import '../../app/navigation/route_facade.dart';
import '../../app/pixiv_image.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../app/widgets/entity_row.dart' show EntityBadge;
import '../../app/widgets/feed/illust_pager_source.dart'
    show IllustPagerAnchor, IllustPagerScope, IllustPagerSource;
import '../../app/widgets/scroll_edge_fade.dart';
import '../../app/widgets/settings/settings_group.dart';
import '../../core/entity/illust_entity.dart';
import '../../core/entity/illust_store.dart';
import '../../core/history/history_models.dart';
import '../../core/history/history_repository.dart';
import '../../l10n/context.dart';
import 'me_history_cover_row.dart';

/// The latest history records, newest first. Read again after every
/// history write, so a work seen elsewhere is on the row by the time the
/// page shows again.
final meRecentHistoryProvider = FutureProvider.autoDispose<List<HistoryRecord>>(
  (ref) async {
    final accountId = ref.watch(historyAccountIdProvider);
    if (accountId == null) return const [];
    final repository = ref.watch(historyRepositoryProvider);
    final changes = repository.changes.listen((_) => ref.invalidateSelf());
    ref.onDispose(changes.cancel);
    final result = await repository.page(
      accountId: accountId,
      limit: MeRecentHistory._count,
    );
    return result.records;
  },
);

/// The works seen last, as a row of covers; "view all" opens the history.
/// Renders a restrained empty-history entry card when empty and [showEmptyCard]
/// is true so users can still reach history.
class MeRecentHistory extends ConsumerStatefulWidget {
  const MeRecentHistory({super.key, this.showEmptyCard = false});

  static const _count = 8;
  static const _cover = 86.0;
  static const _gap = FuncSpacing.sm;

  /// The row's own Hero scope (TRANS-07): the same work may sit on a feed
  /// still mounted in another branch.
  static const _heroScope = 'me-history';

  final bool showEmptyCard;

  @override
  ConsumerState<MeRecentHistory> createState() => _MeRecentHistoryState();
}

class _MeRecentHistoryState extends ConsumerState<MeRecentHistory>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  /// The row's illustrations for the detail pager. Never disposed here: a
  /// pushed detail route still holds it — its lifetime is the route's.
  final _pager = IllustPagerSource();

  /// The covers as shown. Each work viewed moves to the front of the
  /// history, but the row keeps its order while any page is over it (one
  /// opened from it, or from anywhere else), so the image flying back lands
  /// where its cover was when the pager aimed it. Once that page has left,
  /// the row takes the new order, each cover sliding to its place.
  List<HistoryRecord> _shown = const [];

  /// Bumped each time the row takes a new order; [_from] holds where each
  /// cover was then, in places relative to its new one, and [_joined] the
  /// covers that order brought onto the row. A first fill (an empty row
  /// before) slides nothing.
  int _order = 0;
  Map<(HistoryContentType, int), int> _from = const {};
  Set<(HistoryContentType, int)> _joined = const {};

  /// The transitions of the pages over the row: over its own route in the
  /// branch, and over the home shell on the root navigator (the profile,
  /// downloads). The row is covered while either is not dismissed.
  ///
  /// Not TickerMode: the Overlay turns tickers off under any opaque page,
  /// so it cannot tell a page over the row from another tab.
  List<Animation<double>> _covers = const [];
  bool _covered = false;

  /// Whether the open work flew in. One opened without a flight (its work
  /// not in the store yet, no ratio to fly by) takes none back either.
  bool _flies = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final covers = <Animation<double>>[];
    final seenRoutes = <ModalRoute<dynamic>>{};
    void collect(ModalRoute<dynamic>? candidate) {
      if (candidate == null || !seenRoutes.add(candidate)) return;
      final secondary = candidate.secondaryAnimation;
      if (secondary != null && !covers.contains(secondary)) {
        covers.add(secondary);
      }
    }

    collect(ModalRoute.of(context));
    final seenNavigators = <NavigatorState>{};
    var navigator = Navigator.maybeOf(context);
    while (navigator != null && seenNavigators.add(navigator)) {
      final navContext = navigator.context;
      collect(ModalRoute.of(navContext));
      // Navigator.maybeOf(navContext) returns `navigator` itself because
      // `navContext` is its own StatefulElement; use findAncestorStateOfType
      // to step strictly above it toward the root Navigator.
      navigator = navContext.findAncestorStateOfType<NavigatorState>();
    }
    if (listEquals(covers, _covers)) return;
    for (final cover in _covers) {
      cover.removeStatusListener(_onCover);
    }
    _covers = covers;
    for (final cover in covers) {
      cover.addStatusListener(_onCover);
    }
    _covered = _isCovered;
  }

  @override
  void dispose() {
    for (final cover in _covers) {
      cover.removeStatusListener(_onCover);
    }
    super.dispose();
  }

  bool get _isCovered => _covers.any((cover) => !cover.isDismissed);

  /// A page starts covering the row, or the last one over it has left
  /// and its image has landed.
  void _onCover(AnimationStatus status) {
    final covered = _isCovered;
    if (covered == _covered) return;
    setState(() {
      _covered = covered;
      if (!covered) _flies = true;
    });
  }

  static (HistoryContentType, int) _keyOf(HistoryRecord record) =>
      (record.contentType, record.contentId);

  void _adopt(List<HistoryRecord> records) {
    final before = {for (final (i, r) in _shown.indexed) _keyOf(r): i};
    final moved =
        before.length != records.length ||
        records.indexed.any((e) => before[_keyOf(e.$2)] != e.$1);
    if (before.isEmpty) {
      _from = const {};
      _joined = const {};
    } else if (moved) {
      _order++;
      _from = {
        for (final (i, r) in records.indexed)
          if (before[_keyOf(r)] case final was?) _keyOf(r): was - i,
      };
      _joined = {
        for (final r in records)
          if (!before.containsKey(_keyOf(r))) _keyOf(r),
      };
    }
    _shown = records;
  }

  void _open(HistoryRecord record) {
    final id = record.contentId;
    switch (record.contentType) {
      case HistoryContentType.novel:
        unawaited(openNovel(context, id));
      case HistoryContentType.illust:
        _pager.update([
          for (final record in _shown)
            if (record.contentType == HistoryContentType.illust)
              record.contentId,
        ]);
        final entity = ref.read(illustStoreProvider).get(id);
        final url = record.snapshot.coverUrl;
        final flies = entity != null && url != null;
        setState(() => _flies = flies);
        unawaited(
          openIllust(
            context,
            id,
            initialEntity: entity,
            heroScope: MeRecentHistory._heroScope,
            heroImageUrl: flies ? url : null,
            heroImageDecodeWidth: flies
                ? PixivImage.decodeWidthOf(
                    context,
                    _RecentCover.layoutWidth(entity),
                    listen: false,
                  )
                : null,
            pagerSource: _pager,
          ),
        );
    }
  }

  Widget _rowCover(IllustStore store, HistoryRecord record) {
    final illust = record.contentType == HistoryContentType.illust;
    final cover = _RecentCover(
      record: record,
      entity: illust ? store.get(record.contentId) : null,
      flies: _flies,
      onTap: () => _open(record),
    );
    return illust
        ? IllustPagerAnchor(illustId: record.contentId, child: cover)
        : cover;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // Under another tab the row is left; it catches up once it shows
    // again. Under a page it holds until that page has left.
    final showing = TickerMode.valuesOf(context).enabled;
    // After a switch the provider keeps the previous account's records
    // while the next ones load, or for good if that read fails: covers of
    // another account leave at once, slide-free, whatever is over the row.
    final account = ref.watch(historyAccountIdProvider);
    if (_shown.isNotEmpty && _shown.first.accountId != account) {
      _shown = const [];
      _from = const {};
      _joined = const {};
    }
    final records = ref
        .watch(meRecentHistoryProvider)
        .value
        ?.where((record) => record.accountId == account)
        .toList();
    if (records != null && showing && !_covered) _adopt(records);
    final shown = _shown;
    final theme = Theme.of(context);
    if (shown.isEmpty) {
      if (!widget.showEmptyCard) return const SizedBox.shrink();
      return SettingsGroup(
        title: Text(context.l10n.historySettings),
        children: [
          InkWell(
            onTap: () => unawaited(openHistory(context)),
            child: Padding(
              padding: const EdgeInsets.all(FuncSpacing.lg),
              child: Row(
                children: [
                  Icon(
                    AppIcons.history,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: FuncSpacing.md),
                  Expanded(
                    child: Text(
                      context.l10n.historyEmpty,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Icon(
                    UiIcons.chevronRight,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }
    final store = ref.watch(illustStoreProvider);
    return Padding(
      padding: const EdgeInsets.only(bottom: FuncSpacing.xl - FuncSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            // A group heading's inset: the group's and the title's own.
            // Bottom is 0 to offset the cover row's FuncSpacing.xs lift headroom.
            padding: const EdgeInsets.fromLTRB(
              FuncSpacing.lg + FuncSpacing.lg,
              0,
              FuncSpacing.lg,
              0,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      context.l10n.historySettings,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => unawaited(openHistory(context)),
                  child: Text(context.l10n.detailViewAll),
                ),
              ],
            ),
          ),
          SizedBox(
            height: MeRecentHistory._cover + 2 * FuncSpacing.xs,
            child: IllustPagerScope(
              source: _pager,
              // Eight covers at most: built all at once, keyed by work, so
              // each keeps its state as the order changes.
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final rowWidth =
                      shown.length * MeRecentHistory._cover +
                      math.max(0, shown.length - 1) * MeRecentHistory._gap +
                      2 * FuncSpacing.lg;
                  return ScrollEdgeFade(
                    axis: Axis.horizontal,
                    fadeExtent: FuncSpacing.lg,
                    initialAfter: rowWidth > constraints.maxWidth + 0.5,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(
                        horizontal: FuncSpacing.lg,
                        vertical: FuncSpacing.xs,
                      ),
                      child: MeHistoryCoverRow(
                        coverSize: MeRecentHistory._cover,
                        gap: MeRecentHistory._gap,
                        textDirection: Directionality.of(context),
                        children: [
                          for (final (index, record) in shown.indexed)
                            MeHistoryCoverSlot(
                              key: ValueKey(_keyOf(record)),
                              paintPriority: _paintPriority(
                                index: index,
                                total: shown.length,
                                from: _from[_keyOf(record)],
                                entering: _joined.contains(_keyOf(record)),
                              ),
                              child: _RowSlot(
                                order: _order,
                                from: _from[_keyOf(record)],
                                entering: _joined.contains(_keyOf(record)),
                                child: _rowCover(store, record),
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  static int _paintPriority({
    required int index,
    required int total,
    required int? from,
    required bool entering,
  }) {
    if ((from != null && from > 0) || (index == 0 && entering)) {
      return 2 + (total - index);
    }
    if (from != null && from < 0) return 0;
    return 1;
  }
}

class _SlotLift extends InheritedWidget {
  const _SlotLift({required this.scale, required super.child});

  final ValueListenable<double> scale;

  static ValueListenable<double>? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_SlotLift>()?.scale;

  @override
  bool updateShouldNotify(_SlotLift oldWidget) =>
      !identical(scale, oldWidget.scale);
}

/// A cover's place on the row. When the row takes a new order, a cover
/// that moved slides from where it was to its new place; one new to the row
/// slides in from the leading edge and fades in. A new order arriving
/// mid-slide carries on from where the cover is. Reduced motion moves it at
/// once.
class _RowSlot extends StatefulWidget {
  const _RowSlot({
    required this.order,
    required this.from,
    required this.entering,
    required this.child,
  });

  final int order;
  final int? from;
  final bool entering;
  final Widget child;

  @override
  State<_RowSlot> createState() => _RowSlotState();
}

class _RowSlotState extends State<_RowSlot>
    with SingleTickerProviderStateMixin {
  static const _stride = MeRecentHistory._cover + MeRecentHistory._gap;
  static const _fadeIn = Interval(0, 0.5);

  late final _controller = AnimationController(vsync: this, value: 1)
    ..addListener(_syncLift);
  late final ValueNotifier<double> _liftScale = ValueNotifier(1.0);

  double _start = 0;
  bool _fading = false;
  bool _lifting = false;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (widget.entering) {
      _slide(from: -1, fade: true, lift: false);
    }
  }

  @override
  void didUpdateWidget(_RowSlot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.order == oldWidget.order) return;
    final from = widget.from;
    if (from != null && from != 0) {
      _slide(from: from, fade: false, lift: from > 0);
    }
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_syncLift)
      ..dispose();
    _liftScale.dispose();
    super.dispose();
  }

  void _syncLift() {
    final next = !_lifting || _controller.isCompleted
        ? 1.0
        : 1.0 + 0.04 * math.sin(_controller.value * math.pi);
    if (_liftScale.value != next) _liftScale.value = next;
  }

  static const _slideCurve = Curves.easeInOutCubic;

  double get _offset => _start * (1 - _slideCurve.transform(_controller.value));

  void _slide({required int from, required bool fade, required bool lift}) {
    final duration = MotionTokens.resolve(context, MotionTokens.spatial);
    if (duration == Duration.zero) return;
    final leading = Directionality.of(context) == TextDirection.ltr ? 1 : -1;
    _start = _offset + from * _stride * leading;
    _fading = fade;
    _lifting = lift;
    _controller
      ..duration = duration
      ..forward(from: 0);
    _syncLift();
  }

  @override
  Widget build(BuildContext context) => _SlotLift(
    scale: _liftScale,
    child: AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) {
        final moved = Transform.translate(
          offset: Offset(_offset, 0),
          child: child,
        );
        return _fading
            ? Opacity(
                opacity: _fadeIn.transform(_controller.value),
                alwaysIncludeSemantics: true,
                child: moved,
              )
            : moved;
      },
    ),
  );
}

/// A work of the row: its cover, the top of a tall one and the middle of
/// a wide one, a novel marked as one. An illustration whose work is in the
/// store carries the Hero to its detail page. One object to a screen
/// reader, read by its title.
class _RecentCover extends StatelessWidget {
  const _RecentCover({
    required this.record,
    required this.entity,
    required this.flies,
    required this.onTap,
  });

  final HistoryRecord record;
  final IllustEntity? entity;
  final bool flies;
  final VoidCallback onTap;

  static const _size = MeRecentHistory._cover;

  static double layoutWidth(IllustEntity? entity) =>
      _size * math.max(1, entity?.pageAspectRatioAt(0) ?? 1);

  @override
  Widget build(BuildContext context) {
    final url = record.snapshot.coverUrl;
    final novel = record.contentType == HistoryContentType.novel;
    final entity = this.entity;
    Widget? image;
    if (url != null) {
      final tag = illustHeroTag(MeRecentHistory._heroScope, record.contentId);
      image = PixivImage.feed(
        url,
        layoutWidth: layoutWidth(entity),
        alignment: Alignment.topCenter,
        transitionKey: entity == null ? null : tag,
      );
      if (entity != null) {
        image = HeroMode(
          enabled: flies,
          child: Hero(
            tag: tag,
            curve: MotionTokens.spatialCurve,
            createRectTween: illustHeroRectTween,
            flightShuttleBuilder: illustHeroFlightShuttleBuilder,
            child: IllustHeroCardFrame(
              cropAspect: entity.pageAspectRatioAt(0),
              child: image,
            ),
          ),
        );
      }
    }
    final content = InkWell(
      onTap: onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          image ?? Icon(novel ? AppIcons.novel : AppIcons.illust),
          if (novel)
            const Positioned(
              left: 7,
              top: 7,
              child: EntityBadge(icon: AppIcons.novel),
            ),
        ],
      ),
    );
    final scheme = Theme.of(context).colorScheme;
    Widget buildCard(double elevation, Widget? child) => Material(
      color: scheme.surfaceContainer,
      elevation: elevation,
      shadowColor: scheme.shadow,
      shape: const RoundedRectangleBorder(borderRadius: FuncShape.card),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
    final lift = _SlotLift.of(context);
    return Semantics(
      container: true,
      button: true,
      label: record.snapshot.title,
      onTap: onTap,
      excludeSemantics: true,
      child: SizedBox.square(
        dimension: _size,
        child: lift == null
            ? buildCard(0, content)
            : ValueListenableBuilder<double>(
                valueListenable: lift,
                child: content,
                builder: (_, scale, child) {
                  final elevation = ((scale - 1.0) / 0.04).clamp(0.0, 1.0) * 4;
                  return Transform.scale(
                    scale: scale,
                    child: buildCard(elevation, child),
                  );
                },
              ),
      ),
    );
  }
}
