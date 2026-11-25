import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/format/app_format.dart';
import '../../app/icons/app_icons.dart';
import '../../app/icons/ui_icons.dart';
import '../../app/layout/content_widths.dart';
import '../../app/motion/app_overlays.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../app/widgets/app_menu_button.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/filter_menu_button.dart';
import '../../core/entity/illust_store.dart';
import '../../core/entity/stored_entities.dart';
import '../../core/novel/novel_feed_controller.dart';
import '../../core/novel/novel_store.dart';
import '../../core/paging/paged_feed_controller.dart';
import '../../core/profile/profile_feed_controller.dart';
import '../../core/profile/profile_models.dart';
import '../../core/user/user_repository.dart';
import '../../l10n/context.dart';

/// Aggregated tag frequency across loaded artist works.
typedef ProfileWorkTagCount = ({String name, String? translated, int count});

/// Aggregates tag frequencies across loaded visible works, sorted by descending
/// count then ascending tag name.
List<ProfileWorkTagCount> aggregateProfileWorkTags(
  Iterable<Iterable<({String name, String? translated})>> workTagLists,
) {
  final counts = <String, int>{};
  final translations = <String, String?>{};
  for (final tags in workTagLists) {
    final seenInWork = <String>{};
    for (final tag in tags) {
      final name = tag.name.trim();
      if (name.isEmpty || !seenInWork.add(name)) continue;
      counts[name] = (counts[name] ?? 0) + 1;
      final translated = tag.translated?.trim();
      if (translated != null && translated.isNotEmpty) {
        translations.putIfAbsent(name, () => translated);
      }
    }
  }
  final result = [
    for (final entry in counts.entries)
      (
        name: entry.key,
        translated: translations[entry.key],
        count: entry.value,
      ),
  ];
  result.sort((a, b) {
    final byCount = b.count.compareTo(a.count);
    return byCount != 0 ? byCount : a.name.compareTo(b.name);
  });
  return result;
}

/// Header above an artist's `illust`, `manga`, or `novel` work tab: combines
/// the live works total (when available) with a progressive tag filter derived
/// from loaded App-API works (top 10 in dropdown + searchable full picker).
class ProfileWorkTagHeader extends ConsumerWidget {
  const ProfileWorkTagHeader({
    super.key,
    required this.feedKey,
    required this.totalCount,
    required this.selectedTag,
    required this.onTagChanged,
  });

  static const int menuLimit = 10;

  final ProfileFeedKey feedKey;
  final int? totalCount;
  final String? selectedTag;
  final ValueChanged<String?> onTagChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isNovel = feedKey.workType == UserWorkType.novel;
    final PagedFeedState? feed;
    final List<ProfileWorkTagCount> tags;
    final bool hasVisibleItems;
    if (isNovel) {
      feed = ref.watch(userNovelFeedProvider(feedKey.userId)).value;
      final ids = feed?.ids ?? const <int>[];
      final novels = ref
          .watch(
            novelStoreProvider.select((store) => StoredEntities(store, ids)),
          )
          .items;
      hasVisibleItems =
          feed != null && !feed.showInitialError && novels.isNotEmpty;
      tags = aggregateProfileWorkTags([
        for (final novel in novels)
          [
            for (final tag in novel.tags)
              (name: tag.name, translated: tag.translatedName),
          ],
      ]);
    } else {
      feed = ref.watch(profileIllustFeedProvider(feedKey)).value;
      final ids = feed?.ids ?? const <int>[];
      final illusts = ref.watch(illustStoreProvider).getAll(ids);
      hasVisibleItems =
          feed != null && !feed.showInitialError && illusts.isNotEmpty;
      tags = aggregateProfileWorkTags([
        for (final illust in illusts)
          [
            for (final tag in illust.tags)
              (name: tag.name, translated: tag.translatedName),
          ],
      ]);
    }

    if (!hasVisibleItems && selectedTag == null) {
      return const SizedBox.shrink();
    }

    final l10n = context.l10n;
    final theme = Theme.of(context);
    final top = tags.take(menuLimit).toList(growable: false);
    final topNames = {for (final t in top) t.name};
    final active = selectedTag;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        FuncSpacing.lg,
        FuncSpacing.sm,
        FuncSpacing.lg,
        0,
      ),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: Wrap(
          spacing: FuncSpacing.md,
          runSpacing: FuncSpacing.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (totalCount != null && totalCount! > 0)
              Text(
                l10n.profileWorksTotal(AppFormat.count(context, totalCount!)),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            if (tags.isNotEmpty || active != null)
              FilterMenuButton<String?>(
                key: ValueKey(
                  'profile-work-tag-filter-${feedKey.workType.name}',
                ),
                label: active == null
                    ? l10n.profileTagFilterAll
                    : l10n.profileTagFilter(active),
                value: active,
                options: [
                  AppMenuEntry(value: null, label: l10n.profileTagAny),
                  for (final item in top)
                    AppMenuEntry(
                      value: item.name,
                      label: '${item.name} (${item.count})',
                    ),
                  if (active != null && !topNames.contains(active))
                    AppMenuEntry(value: active, label: active),
                ],
                onChanged: onTagChanged,
                moreLabel: l10n.profileTagMore,
                onMore: () => unawaited(
                  _openPicker(context, tags: tags, selected: active),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _openPicker(
    BuildContext context, {
    required List<ProfileWorkTagCount> tags,
    required String? selected,
  }) async {
    final picked = await showProfileWorkTagPicker(
      context,
      tags: tags,
      selectedTag: selected,
    );
    if (picked == null) return;
    onTagChanged(picked.isEmpty ? null : picked);
  }
}

/// Adaptive searchable tag picker for artist work tabs. Returns `''` when the
/// user explicitly clears the filter, a non-empty tag/keyword when picked, or
/// `null` when dismissed.
Future<String?> showProfileWorkTagPicker(
  BuildContext context, {
  required List<ProfileWorkTagCount> tags,
  String? selectedTag,
}) => showAppAdaptiveDialog<String>(
  context: context,
  maxWidth: ContentWidths.management,
  isScrollControlled: true,
  builder: (_) => _ProfileWorkTagPicker(tags: tags, selectedTag: selectedTag),
);

class _ProfileWorkTagPicker extends StatefulWidget {
  const _ProfileWorkTagPicker({required this.tags, this.selectedTag});

  final List<ProfileWorkTagCount> tags;
  final String? selectedTag;

  @override
  State<_ProfileWorkTagPicker> createState() => _ProfileWorkTagPickerState();
}

class _ProfileWorkTagPickerState extends State<_ProfileWorkTagPicker> {
  final _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final trimmed = _query.trim();
    final lower = trimmed.toLowerCase();
    final filtered = lower.isEmpty
        ? widget.tags
        : [
            for (final tag in widget.tags)
              if (tag.name.toLowerCase().contains(lower) ||
                  (tag.translated?.toLowerCase().contains(lower) ?? false))
                tag,
          ];
    final exactMatch = widget.tags.any((t) => t.name.toLowerCase() == lower);

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.heightOf(context) * 0.72,
        ),
        child: Padding(
          padding: const EdgeInsets.all(FuncSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.profileWorkTagPickerTitle,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  if (widget.selectedTag != null)
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(''),
                      child: Text(l10n.profileWorkTagClear),
                    ),
                ],
              ),
              const SizedBox(height: FuncSpacing.sm),
              TextField(
                controller: _controller,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: l10n.profileWorkTagSearchHint,
                  prefixIcon: const Icon(AppIcons.search),
                  suffixIcon: trimmed.isEmpty
                      ? null
                      : IconButton(
                          tooltip: l10n.searchClear,
                          onPressed: () {
                            _controller.clear();
                            setState(() => _query = '');
                          },
                          icon: const Icon(UiIcons.close),
                        ),
                ),
                textInputAction: TextInputAction.search,
                onChanged: (value) => setState(() => _query = value),
                onSubmitted: (value) {
                  final term = value.trim();
                  if (term.isNotEmpty) Navigator.of(context).pop(term);
                },
              ),
              const SizedBox(height: FuncSpacing.sm),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    if (trimmed.isNotEmpty && !exactMatch)
                      ListTile(
                        leading: const Icon(AppIcons.search),
                        title: Text(trimmed),
                        onTap: () => Navigator.of(context).pop(trimmed),
                      ),
                    for (final tag in filtered)
                      ListTile(
                        leading: const Icon(AppIcons.tag),
                        title: Text(tag.name),
                        subtitle: tag.translated == null
                            ? null
                            : Text(tag.translated!),
                        trailing: Text('${tag.count}'),
                        selected: tag.name == widget.selectedTag,
                        onTap: () => Navigator.of(context).pop(tag.name),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Runs a bounded, cancelable refill of up to [maxHops] `loadMore()` calls
/// while an active profile work tag filter yields fewer than [minVisible]
/// items and more pages remain on the server.
class ProfileFilterRefillRunner extends StatefulWidget {
  const ProfileFilterRefillRunner({
    super.key,
    required this.filterKey,
    required this.visibleCount,
    required this.loadedCount,
    required this.hasMore,
    required this.loadingMore,
    required this.hasLoadMoreError,
    required this.onLoadMore,
    required this.child,
  });

  static const int maxHops = 3;
  static const int minVisible = 6;

  final String? filterKey;
  final int visibleCount;
  final int loadedCount;
  final bool hasMore;
  final bool loadingMore;
  final bool hasLoadMoreError;
  final Future<void> Function() onLoadMore;
  final Widget child;

  @override
  State<ProfileFilterRefillRunner> createState() =>
      _ProfileFilterRefillRunnerState();
}

class _ProfileFilterRefillRunnerState extends State<ProfileFilterRefillRunner> {
  int _hops = 0;
  bool _inFlight = false;

  @override
  void initState() {
    super.initState();
    _scheduleRefillIfNeeded();
  }

  @override
  void didUpdateWidget(ProfileFilterRefillRunner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.filterKey != widget.filterKey) {
      _hops = 0;
    }
    _scheduleRefillIfNeeded();
  }

  void _scheduleRefillIfNeeded() {
    final activeFilter = widget.filterKey?.trim() ?? '';
    if (activeFilter.isEmpty) return;
    if (_inFlight || _hops >= ProfileFilterRefillRunner.maxHops) return;
    if (!widget.hasMore || widget.loadingMore || widget.hasLoadMoreError) {
      return;
    }
    if (widget.visibleCount >= ProfileFilterRefillRunner.minVisible) return;

    _inFlight = true;
    _hops += 1;
    final startedFilter = activeFilter;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || (widget.filterKey?.trim() ?? '') != startedFilter) {
        _inFlight = false;
        return;
      }
      unawaited(
        widget.onLoadMore().whenComplete(() {
          _inFlight = false;
          if (mounted) _scheduleRefillIfNeeded();
        }),
      );
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Empty state when an artist work tag filter matches zero loaded items:
/// offers one-tap reset and, when unexhausted, explicit manual load-more.
class ProfileFilteredEmptyState extends StatelessWidget {
  const ProfileFilteredEmptyState({
    super.key,
    required this.hasMore,
    required this.loadingMore,
    required this.onLoadMore,
    required this.onClearFilter,
  });

  final bool hasMore;
  final bool loadingMore;
  final Future<void> Function() onLoadMore;
  final VoidCallback? onClearFilter;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final canLoadMore = hasMore && !loadingMore;
    return FeedEmpty(
      icon: UiIcons.inbox,
      title: l10n.bookmarkTagFilterEmpty,
      onRefresh: canLoadMore ? onLoadMore : null,
      retryLabel: canLoadMore ? l10n.profileWorkTagLoadMore : null,
      onAction: onClearFilter,
      actionLabel: onClearFilter == null ? null : l10n.profileWorkTagClear,
      actionIcon: AppIcons.filterOff,
    );
  }
}
