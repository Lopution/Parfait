import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/icons/ui_icons.dart';
import '../../app/navigation/route_facade.dart';
import '../../app/widgets/app_snack_bar.dart';
import '../../app/widgets/app_spinner.dart';
import '../../app/widgets/watchlist_toggle.dart';
import '../../core/auth/account_store.dart';
import '../../core/errors/no_retry.dart';
import '../../core/log.dart';
import '../../core/network/pixiv_http_client.dart';
import '../../core/novel/novel_entity.dart';
import '../../core/novel/novel_repository.dart';
import '../../core/watchlist/watchlist_models.dart';
import '../../core/watchlist/watchlist_store.dart';
import '../../l10n/context.dart';

/// Maximum number of `/v2/novel/series` pages walked while locating the open
/// chapter and its successor across pagination boundaries.
const _maxSeriesPages = 20;

/// Fixed strip height shared by every series-bar state — an [IconButton]'s
/// minimum hit target. Loading, failure, missing-entry and data never resize
/// the strip under the bottom chrome.
const novelSeriesBarHeight = 48.0;

typedef NovelSeriesNavKey = ({int seriesId, int novelId});

/// Resolved series state for the open chapter: enough pages fetched to locate
/// [novelId] and its immediate next chapter whenever the series contains them.
class NovelSeriesNavState {
  const NovelSeriesNavState({
    required this.title,
    required this.watchlistAdded,
    required this.entries,
    required this.index,
    required this.truncated,
  });

  final String? title;
  final bool? watchlistAdded;
  final List<NovelSeriesEntry> entries;

  /// Index of the open chapter inside [entries], or `-1` if not found.
  final int index;

  /// Whether more series pages remain unfetched (page cap or later-page error).
  final bool truncated;

  bool get containsCurrent => index >= 0;

  NovelSeriesEntry? get previous => index > 0 ? entries[index - 1] : null;

  NovelSeriesEntry? get next =>
      index >= 0 && index + 1 < entries.length ? entries[index + 1] : null;
}

final novelSeriesNavProvider = FutureProvider.autoDispose
    .family<NovelSeriesNavState, NovelSeriesNavKey>((ref, key) async {
      final token = CancelToken();
      ref.onDispose(token.cancel);
      final repo = ref.read(novelRepositoryProvider);
      final NovelSeriesPage first;
      try {
        first = await repo.fetchSeries(key.seriesId, cancelToken: token);
      } catch (error) {
        // The bar shows only the localized fallback; the real error goes
        // to the log once, here at the fetch boundary — never inside
        // build, which would re-log on every rebuild.
        log('novel series ${key.seriesId} failed: $error');
        rethrow;
      }

      final entries = List<NovelSeriesEntry>.of(first.entries);
      var index = entries.indexWhere((entry) => entry.id == key.novelId);
      var nextUrl = first.nextUrl;
      var pagesFetched = 1;
      final seenCursors = <String>{};

      // Walk forward while the current chapter has not appeared yet OR sits on
      // the last slot of the fetched window (so its next chapter lives on the
      // following page). Stop cleanly if a later page fails so page-1 metadata
      // and fallback prev/next IDs still work.
      while ((index < 0 || index == entries.length - 1) &&
          nextUrl != null &&
          nextUrl.isNotEmpty &&
          pagesFetched < _maxSeriesPages &&
          seenCursors.add(nextUrl)) {
        try {
          final page = await repo.fetchSeries(
            key.seriesId,
            cursor: nextUrl,
            cancelToken: token,
          );
          entries.addAll(page.entries);
          index = entries.indexWhere((entry) => entry.id == key.novelId);
          nextUrl = page.nextUrl;
          pagesFetched += 1;
        } catch (error) {
          log(
            'novel series ${key.seriesId} page ${pagesFetched + 1} failed: '
            '$error',
          );
          break;
        }
      }

      return NovelSeriesNavState(
        title: first.title,
        watchlistAdded: first.watchlistAdded,
        entries: entries,
        index: index,
        truncated: nextUrl != null && nextUrl.isNotEmpty,
      );
    }, retry: noRetry);

/// Opens an adjacent chapter inside the reader, replacing the current chapter
/// route so back returns directly to the reading entry.
void _showNovelPage(BuildContext context, int novelId) {
  if (novelId <= 0) {
    showAppSnackBar(context, context.l10n.novelNotFound);
    return;
  }
  unawaited(openNovel(context, novelId, replaceCurrent: true));
}

/// One fixed-height series row: prev/next chevrons at the edges, content
/// centred on the row (not between the controls), an optional trailing
/// control (watchlist, retry) beside next.
/// All series-bar states share it so layout never shifts between them.
class _SeriesBarRow extends StatelessWidget {
  const _SeriesBarRow({
    this.onPrevious,
    this.onNext,
    this.center,
    this.trailing,
  });

  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final Widget? center;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: novelSeriesBarHeight,
      child: NavigationToolbar(
        middleSpacing: 0,
        leading: IconButton(
          tooltip: context.l10n.novelPrevious,
          onPressed: onPrevious,
          icon: const Icon(UiIcons.chevronLeft),
        ),
        middle: center,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ?trailing,
            IconButton(
              tooltip: context.l10n.novelNext,
              onPressed: onNext,
              icon: const Icon(UiIcons.chevronRight),
            ),
          ],
        ),
      ),
    );
  }
}

/// Prev/next navigation supplied by the webview payload when the detail
/// metadata carries no `series` object of its own.
class NovelAdjacentBar extends StatelessWidget {
  const NovelAdjacentBar({
    super.key,
    required this.prevId,
    required this.nextId,
  });

  final int? prevId;
  final int? nextId;

  @override
  Widget build(BuildContext context) {
    return _SeriesBarRow(
      onPrevious: prevId == null
          ? null
          : () => _showNovelPage(context, prevId!),
      onNext: nextId == null ? null : () => _showNovelPage(context, nextId!),
      center: Text(
        context.l10n.novelSeries,
        textAlign: TextAlign.center,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

/// Bottom-chrome strip for a serialized novel: resolves prev/next across series
/// pagination boundaries, falls back to detail metadata IDs when needed, and
/// updates the watchlist read cursor once per mounted bar.
class NovelSeriesBar extends ConsumerStatefulWidget {
  const NovelSeriesBar({
    super.key,
    required this.seriesId,
    required this.novelId,
    this.fallbackPrevId,
    this.fallbackNextId,
  });

  final int seriesId;
  final int novelId;
  final int? fallbackPrevId;
  final int? fallbackNextId;

  @override
  ConsumerState<NovelSeriesBar> createState() => _NovelSeriesBarState();
}

class _NovelSeriesBarState extends ConsumerState<NovelSeriesBar> {
  /// The watchlist cursor is written once per mounted bar — scheduling it
  /// on every build would re-fire the write on each chrome rebuild.
  bool _seenMarked = false;

  int get seriesId => widget.seriesId;
  int get novelId => widget.novelId;
  NovelSeriesNavKey get _navKey => (seriesId: seriesId, novelId: novelId);

  void _markSeenOnce() {
    final accountId = ref.watch(
      accountStoreProvider.select((async) => async.value?.usableCurrent?.id),
    );
    if (accountId == null || _seenMarked) return;
    _seenMarked = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        ref
            .read(watchlistReadCursorProvider)
            .markSeen(
              accountId,
              WatchlistKey(WatchlistType.novel, seriesId),
              novelId,
            )
            .catchError((Object error, _) {
              log('series seen cursor not remembered: $error');
            }),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final async = ref.watch(novelSeriesNavProvider(_navKey));
    final fallbackPrevId = widget.fallbackPrevId;
    final fallbackNextId = widget.fallbackNextId;
    Widget seriesTitle(NovelSeriesNavState series) => TextButton(
      key: const Key('novel-series-bar-title'),
      onPressed: () => unawaited(openNovelSeries(context, seriesId)),
      child: Text(
        series.title ?? l10n.novelSeries,
        textAlign: TextAlign.center,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
    return async.when(
      loading: () => const _SeriesBarRow(
        center: Center(child: AppSpinner(size: 16, strokeWidth: 2)),
      ),
      error: (error, _) => _SeriesBarRow(
        onPrevious: fallbackPrevId == null
            ? null
            : () => _showNovelPage(context, fallbackPrevId),
        onNext: fallbackNextId == null
            ? null
            : () => _showNovelPage(context, fallbackNextId),
        center: Text(
          l10n.novelSeriesUnavailable,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        trailing: TextButton(
          onPressed: () => ref.invalidate(novelSeriesNavProvider(_navKey)),
          child: Text(l10n.retry),
        ),
      ),
      data: (series) {
        final hasFallback = fallbackPrevId != null || fallbackNextId != null;
        // When the entire series was loaded and still does not contain this
        // novel, keep title and watchlist but dead-end navigation without
        // moving the watchlist cursor.
        if (!series.containsCurrent && (!series.truncated || !hasFallback)) {
          return _SeriesBarRow(
            center: seriesTitle(series),
            trailing: WatchlistToggle(
              seriesKey: WatchlistKey(WatchlistType.novel, seriesId),
              detailAdded: series.watchlistAdded,
              iconOnly: true,
            ),
          );
        }
        final previous = series.previous;
        final next = series.next;
        final prevId = previous != null
            ? (previous.viewable ? previous.id : null)
            : (series.truncated ? fallbackPrevId : null);
        final nextId = next != null
            ? (next.viewable ? next.id : null)
            : (series.truncated ? fallbackNextId : null);
        _markSeenOnce();
        return _SeriesBarRow(
          onPrevious: prevId == null
              ? null
              : () => _showNovelPage(context, prevId),
          onNext: nextId == null ? null : () => _showNovelPage(context, nextId),
          center: seriesTitle(series),
          trailing: WatchlistToggle(
            seriesKey: WatchlistKey(WatchlistType.novel, seriesId),
            detailAdded: series.watchlistAdded,
            iconOnly: true,
          ),
        );
      },
    );
  }
}
