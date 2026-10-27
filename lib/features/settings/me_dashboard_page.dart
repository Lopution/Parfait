import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/format/app_format.dart';
import '../../app/motion/hero_transition.dart';
import '../../app/motion/motion_tokens.dart';
import '../../app/navigation/routes.dart';
import '../../app/person_avatar.dart';
import '../../app/pixiv_image.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../app/widgets/app_top_bar.dart';
import '../../app/widgets/edge_icon_buttons.dart';
import '../../app/widgets/entity_row.dart' show EntityBadge;
import '../../app/widgets/feed/feed_grid.dart'
    show IllustPagerAnchor, IllustPagerScope, IllustPagerSource;
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/func_bottom_nav.dart';
import '../../app/widgets/person_card.dart';
import '../../app/widgets/settings_load_error.dart';
import '../../core/auth/account.dart';
import '../../core/auth/account_store.dart';
import '../../core/navigation/home_destination.dart';
import '../../core/download/download_providers.dart';
import '../../core/download/download_task.dart' show isTerminal;
import '../../core/entity/illust_entity.dart';
import '../../core/entity/illust_store.dart';
import '../../core/history/history_models.dart';
import '../../core/history/history_repository.dart';
import '../../l10n/context.dart';
import 'settings_catalog.dart';
import 'settings_helpers.dart';
import 'settings_page.dart' show settingsPageIcons;

/// The "me" destination, YouTube's way: who is signed in, what they saw
/// last, the places of their own content as a list, then settings and
/// about. Content comes first — it is what the page is opened for.
class MeDashboardPage extends ConsumerWidget {
  const MeDashboardPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(accountStoreProvider);
    return Scaffold(
      // Root pages own no inline composer: leaving the default `true`
      // would subscribe this whole subtree to per-frame viewInsets churn
      // every time the IME animates (e.g. the push that hides the search
      // keyboard) — a relayout storm across all five live branches.
      resizeToAvoidBottomInset: false,
      // Settings open from the row at the page's end, not the bar.
      appBar: AppTopBar(title: Text(context.l10n.homeMe)),
      body: _body(context, ref, accounts),
    );
  }

  Widget _body(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<AccountState> accounts,
  ) {
    void reload() => ref.read(accountStoreProvider.notifier).reload();
    if (accounts.hasError) {
      return SettingsLoadError(
        error: accounts.error!,
        onRetry: reload,
        messageKey: 'accountReadFailed',
      );
    }
    if (accounts.isLoading && !accounts.hasValue) return const FeedLoading();
    final state = accounts.value;
    if (state?.status == AccountStatus.failure) {
      return SettingsLoadError(
        error: state?.error ?? StateError('account state unavailable'),
        onRetry: reload,
        messageKey: 'accountReadFailed',
      );
    }
    return settingsNarrowBody(
      ListView(
        padding: const EdgeInsets.only(
          top: FuncSpacing.sm,
          bottom: FuncSpacing.xl,
        ),
        children: [
          _AccountHeader(account: state?.current),
          const _RecentHistory(),
          const _ContentShortcuts(),
          const Divider(indent: FuncSpacing.lg, endIndent: FuncSpacing.lg),
          _MeRow(
            icon: Icons.settings_outlined,
            label: context.l10n.settingsTitle,
            onTap: () => openSettingsPage(context, settingsIndexPath),
          ),
          _MeRow(
            icon: settingsPageIcons[SettingsPageRef.about]!,
            label: context.l10n.aboutSettings,
            onTap: () => openSettingsPage(context, SettingsPageRef.about.path),
          ),
          const FuncNavBarSpacer(),
        ],
      ),
    );
  }
}

/// The signed-in account on a [PersonCard]: avatar, name, user ID and the
/// premium badge are the card, one button that opens the profile;
/// managing and switching accounts is a button of its own inside it.
/// Signed out, the card is one button to the login, with no manage button.
class _AccountHeader extends StatelessWidget {
  const _AccountHeader({required this.account});

  final Account? account;

  static const _avatarDiameter = 72.0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final value = account;
    final url = value?.profileImageUrl;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        FuncSpacing.lg,
        FuncSpacing.sm,
        FuncSpacing.lg,
        FuncSpacing.lg,
      ),
      child: PersonCard(
        onTap: value == null ? () => openLogin(context) : () => openMe(context),
        tapHint: value == null ? null : l10n.meOpenProfile,
        endPadding: PersonCard.padding - EdgeIconButtons.glyphInset,
        trailing: value == null
            ? null
            : IconButton(
                tooltip: l10n.accountManagement,
                icon: const Icon(Icons.manage_accounts_outlined),
                onPressed: () =>
                    openSettingsPage(context, SettingsPageRef.account.path),
              ),
        child: Row(
          children: [
            SizedBox.square(
              dimension: _avatarDiameter,
              child: PersonAvatar(
                imageUrl: url == null || url.isEmpty ? null : url,
                radius: _avatarDiameter / 2,
              ),
            ),
            const SizedBox(width: FuncSpacing.lg),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          value?.name ?? l10n.signedOut,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: FuncSemanticTokens.of(context).display,
                        ),
                      ),
                      if (value?.isPremium ?? false) ...[
                        const SizedBox(width: FuncSpacing.sm),
                        const _PremiumBadge(),
                      ],
                    ],
                  ),
                  const SizedBox(height: FuncSpacing.xs),
                  Text(
                    value == null
                        ? l10n.login
                        : l10n.labelValue(l10n.profileId, '${value.userId}'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// pixiv Premium beside the name: a neutral pill, a fact about the
/// account rather than an accent (THEME-07).
class _PremiumBadge extends StatelessWidget {
  const _PremiumBadge();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: FuncShape.pill,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: FuncSpacing.sm,
          vertical: FuncSpacing.xxs,
        ),
        child: Text(
          context.l10n.premiumBadge,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

/// Download tasks not yet finished. The manager reports every progress
/// tick; the count is re-emitted only when it moves, so the grid rebuilds
/// when a task starts or ends, not on every tick.
final _activeDownloadCountProvider = StreamProvider.autoDispose<int>((
  ref,
) async* {
  final manager = ref.watch(downloadManagerProvider);
  int count() => manager.tasks.where((task) => !isTerminal(task.status)).length;
  var last = count();
  yield last;
  await for (final _ in manager.changes) {
    final next = count();
    if (next == last) continue;
    yield last = next;
  }
});

/// The latest history records, newest first. Read again after every
/// history write, so a work seen elsewhere is on the row by the time the
/// page shows again.
final _recentHistoryProvider = FutureProvider.autoDispose<List<HistoryRecord>>((
  ref,
) async {
  final accountId = ref.watch(historyAccountIdProvider);
  if (accountId == null) return const [];
  final repository = ref.watch(historyRepositoryProvider);
  final changes = repository.changes.listen((_) => ref.invalidateSelf());
  ref.onDispose(changes.cancel);
  final result = await repository.page(
    accountId: accountId,
    limit: _RecentHistory._count,
  );
  return result.records;
});

/// The works seen last, as a row of covers; "view all" opens the history.
/// Nothing while the history is empty.
class _RecentHistory extends ConsumerStatefulWidget {
  const _RecentHistory();

  static const _count = 8;
  static const _cover = 88.0;
  static const _gap = FuncSpacing.sm;

  /// The row's own Hero scope (TRANS-07): the same work may sit on a feed
  /// still mounted in another branch.
  static const _heroScope = 'me-history';

  @override
  ConsumerState<_RecentHistory> createState() => _RecentHistoryState();
}

class _RecentHistoryState extends ConsumerState<_RecentHistory>
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
    final route = ModalRoute.of(context);
    final navigator = Navigator.maybeOf(context);
    final shell = navigator == null ? null : ModalRoute.of(navigator.context);
    final covers = [
      ?route?.secondaryAnimation,
      if (!identical(shell, route)) ?shell?.secondaryAnimation,
    ];
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
            heroScope: _RecentHistory._heroScope,
            heroImageUrl: flies ? url : null,
            heroImageDecodeWidth: flies
                ? PixivImage.decodeWidthFor(_RecentCover.layoutWidth(entity))
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
        .watch(_recentHistoryProvider)
        .value
        ?.where((record) => record.accountId == account)
        .toList();
    if (records != null && showing && !_covered) _adopt(records);
    final shown = _shown;
    if (shown.isEmpty) return const SizedBox.shrink();
    final store = ref.watch(illustStoreProvider);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: FuncSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            // A group heading's inset: the group's and the title's own.
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
            height: _RecentHistory._cover,
            child: IllustPagerScope(
              source: _pager,
              // Eight covers at most: built all at once, keyed by work, so
              // each keeps its state as the order changes.
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: FuncSpacing.lg),
                child: Row(
                  children: [
                    for (final (index, record) in shown.indexed) ...[
                      if (index > 0) const SizedBox(width: _RecentHistory._gap),
                      _RowSlot(
                        key: ValueKey(_keyOf(record)),
                        order: _order,
                        from: _from[_keyOf(record)],
                        entering: _joined.contains(_keyOf(record)),
                        child: _rowCover(store, record),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A cover's place on the row. When the row takes a new order, a cover
/// that moved slides from where it was to its new place; one new to the row
/// slides in from the leading edge and fades in. A new order arriving
/// mid-slide carries on from where the cover is. Reduced motion moves it at
/// once.
class _RowSlot extends StatefulWidget {
  const _RowSlot({
    super.key,
    required this.order,
    required this.from,
    required this.entering,
    required this.child,
  });

  /// The row's order generation; a new one starts a slide.
  final int order;

  /// Where the cover was when the row took [order], in places relative to
  /// its new one; null when it is new to the row.
  final int? from;

  /// Whether the cover joined the row with [order].
  final bool entering;
  final Widget child;

  @override
  State<_RowSlot> createState() => _RowSlotState();
}

class _RowSlotState extends State<_RowSlot>
    with SingleTickerProviderStateMixin {
  static const _stride = _RecentHistory._cover + _RecentHistory._gap;

  /// The fade of a cover joining the row: an effect, shorter than the move.
  static const _fadeIn = Interval(0, 0.5);

  late final _controller = AnimationController(vsync: this, value: 1);

  /// The slide's start, in logical pixels from the cover's place.
  double _start = 0;
  bool _fading = false;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (widget.entering) _slide(from: -1, fade: true);
  }

  @override
  void didUpdateWidget(_RowSlot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.order == oldWidget.order) return;
    final from = widget.from;
    if (from != null && from != 0) _slide(from: from, fade: false);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  double get _offset =>
      _start * (1 - MotionTokens.spatialCurve.transform(_controller.value));

  void _slide({required int from, required bool fade}) {
    final duration = MotionTokens.resolve(context, MotionTokens.spatial);
    if (duration == Duration.zero) return;
    final leading = Directionality.of(context) == TextDirection.ltr ? 1 : -1;
    _start = _offset + from * _stride * leading;
    _fading = fade;
    _controller
      ..duration = duration
      ..forward(from: 0);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
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
              // Still one object to a screen reader while it fades in.
              alwaysIncludeSemantics: true,
              child: moved,
            )
          : moved;
    },
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

  /// The illustration's work from the store, for its ratio.
  final IllustEntity? entity;
  final bool flies;
  final VoidCallback onTap;

  static const _size = _RecentHistory._cover;

  /// The cover's decode width: a wide image covers the square by its
  /// height, so it is decoded wider.
  static double layoutWidth(IllustEntity? entity) =>
      _size * math.max(1, entity?.pageAspectRatioAt(0) ?? 1);

  @override
  Widget build(BuildContext context) {
    final url = record.snapshot.coverUrl;
    final novel = record.contentType == HistoryContentType.novel;
    final entity = this.entity;
    Widget? image;
    if (url != null) {
      final tag = illustHeroTag(_RecentHistory._heroScope, record.contentId);
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
    return Semantics(
      container: true,
      button: true,
      label: record.snapshot.title,
      onTap: onTap,
      excludeSemantics: true,
      child: SizedBox.square(
        dimension: _size,
        child: Material(
          color: Theme.of(context).colorScheme.surfaceContainer,
          shape: const RoundedRectangleBorder(borderRadius: FuncShape.card),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Stack(
              fit: StackFit.expand,
              children: [
                image ??
                    Icon(
                      novel ? Icons.menu_book_outlined : Icons.image_outlined,
                    ),
                if (novel)
                  const Positioned(
                    left: 7,
                    top: 7,
                    child: EntityBadge(icon: Icons.menu_book_outlined),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One content entry: a row of [_ContentShortcuts]. [count], when given,
/// is shown at the row's end while it is above zero.
typedef _Entry = ({
  IconData icon,
  String label,
  VoidCallback onTap,
  int? count,
});

/// The user's own content, a row each; then the home destinations the user
/// took off the bar.
class _ContentShortcuts extends ConsumerWidget {
  const _ContentShortcuts();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final activeTasks = ref.watch(_activeDownloadCountProvider).value ?? 0;
    final offBar = ref.watch(homeArrangementProvider).hidden;
    final List<_Entry> entries = [
      (
        icon: Icons.favorite_border,
        label: l10n.profileBookmarked,
        onTap: () => unawaited(openMe(context, tab: MeTab.bookmarks)),
        count: null,
      ),
      (
        icon: Icons.people_outline,
        label: l10n.profileFollowing,
        onTap: () => unawaited(openMe(context, tab: MeTab.following)),
        count: null,
      ),
      (
        icon: Icons.library_books_outlined,
        label: l10n.watchlistTitle,
        onTap: () => unawaited(openWatchlist(context)),
        count: null,
      ),
      (
        icon: Icons.bookmark_border,
        label: l10n.watchLaterTitle,
        onTap: () => unawaited(openWatchLater(context)),
        count: null,
      ),
      (
        icon: Icons.menu_book_outlined,
        label: l10n.localNovelsTitle,
        onTap: () => unawaited(openLocalNovels(context)),
        count: null,
      ),
      (
        icon: Icons.downloading_outlined,
        label: l10n.downloaderSettings,
        onTap: () => unawaited(openDownloadTasks(context)),
        count: activeTasks,
      ),
      for (final destination in HomeDestination.values)
        if (offBar.contains(destination))
          (
            icon: homeDestinationIcon(destination),
            label: homeDestinationLabel(context, destination),
            onTap: () => openHomeDestination(context, destination),
            count: null,
          ),
    ];
    return Column(
      children: [
        for (final entry in entries)
          _MeRow(
            icon: entry.icon,
            label: entry.label,
            onTap: entry.onTap,
            count: entry.count,
          ),
      ],
    );
  }
}

/// A row of the page: a neutral icon and its label; [count], when given,
/// as a badge at the end while it is above zero.
class _MeRow extends StatelessWidget {
  const _MeRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.count,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final int? count;

  @override
  Widget build(BuildContext context) {
    final count = this.count;
    return ListTile(
      leading: Icon(
        icon,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      title: Text(label),
      trailing: count == null
          ? null
          : Badge(
              isLabelVisible: count > 0,
              label: Text(AppFormat.count(context, count)),
            ),
      onTap: onTap,
    );
  }
}
