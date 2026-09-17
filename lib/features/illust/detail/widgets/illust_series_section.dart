import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/navigation/routes.dart';
import '../../../../app/pixiv_image.dart';
import '../../../../core/entity/illust_store.dart';
import '../../../../core/series/illust_series_context_controller.dart';
import '../../../../core/series/series_models.dart';
import '../../../../core/series/series_store.dart';
import '../../../../l10n/context.dart';

/// Detail-page sliver between the image pages and [InfoBlock]: the series
/// card when this work belongs to a series (prev/next navigation included).
/// Non-series works and fetch errors render nothing — the context probe is
/// best-effort and must never block or break the detail page.
class IllustSeriesSection extends ConsumerWidget {
  const IllustSeriesSection({super.key, required this.illustId});

  final int illustId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final contextData = ref.watch(illustSeriesContextProvider(illustId)).value;
    if (contextData == null) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    final detail = ref.watch(illustSeriesStoreProvider)[contextData.seriesId];
    if (detail == null) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    return SliverToBoxAdapter(
      child: _SeriesCardView(detail: detail, context: contextData),
    );
  }
}

class _SeriesCardView extends ConsumerWidget {
  const _SeriesCardView({required this.detail, required this.context});

  final IllustSeriesEntity detail;
  final IllustSeriesContext context;

  @override
  Widget build(BuildContext buildContext, WidgetRef ref) {
    final theme = Theme.of(buildContext);
    final cover = detail.coverUrl;
    void openNeighbour(int? illustId) {
      if (illustId == null) return;
      openIllust(
        buildContext,
        illustId,
        initialEntity: ref.read(illustStoreProvider).get(illustId),
      );
    }

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => openIllustSeries(buildContext, detail.id),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              if (cover != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: PixivImage(
                    url: cover,
                    width: 56,
                    height: 56,
                    memCacheWidth: PixivImage.decodeWidthFor(56),
                  ),
                ),
              if (cover != null) const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      detail.title,
                      style: theme.textTheme.titleSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      context.contentOrder == null
                          ? buildContext.l10n.seriesTitle
                          : buildContext.l10n.seriesEpisode(
                              context.contentOrder!,
                            ),
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: buildContext.l10n.seriesPrevious,
                onPressed: context.prevIllustId == null
                    ? null
                    : () => openNeighbour(context.prevIllustId),
                icon: const Icon(Icons.chevron_left),
              ),
              IconButton(
                tooltip: buildContext.l10n.seriesNext,
                onPressed: context.nextIllustId == null
                    ? null
                    : () => openNeighbour(context.nextIllustId),
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
