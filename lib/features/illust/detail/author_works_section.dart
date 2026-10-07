import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/motion/state_fade.dart';
import '../../../app/navigation/routes.dart';
import '../../../app/pixiv_image.dart';
import '../../../app/theme/func_semantic_tokens.dart';
import '../../../app/widgets/skeleton/func_skeleton.dart';
import '../../../core/entity/illust_entity.dart';
import '../../../core/entity/illust_store.dart';
import '../../../core/profile/profile_feed_controller.dart';
import '../../../core/profile/profile_models.dart';
import '../../../l10n/context.dart';
import 'on_demand_sliver.dart';
import 'widgets/detail_section_header.dart';

/// A strip of the author's other works, with "See all" into the author's
/// page. It reads the author page's own works feed (first page), so that
/// page opens on them at once. Requested only once on screen
/// ([OnDemandSliver]); the loaded strip fades in over its skeleton.
class AuthorWorksSlivers extends ConsumerWidget {
  const AuthorWorksSlivers({super.key, required this.entity});

  /// Works shown before "See all".
  static const shown = 12;

  /// Square tile edge; also the strip's height while pending.
  static const tileExtent = 112.0;

  final IllustEntity entity;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authorId = entity.user.id;
    final key = ProfileFeedKey(userId: authorId, kind: ProfileFeedKind.work);
    final feed = profileIllustFeedProvider(key);
    final header = DetailSectionHeader(
      title: context.l10n.detailSectionAuthorWorks,
      actionLabel: context.l10n.detailViewAll,
      onAction: () => openUser(context, authorId),
    );
    return OnDemandSliver(
      id: 'author-works-${entity.id}',
      alreadyRequested: () => ref.exists(feed),
      placeholder: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          const SizedBox(height: tileExtent),
        ],
      ),
      sliver: (context) => SliverToBoxAdapter(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            _StripBody(entity: entity, feedKey: key),
          ],
        ),
      ),
    );
  }
}

enum _StripKind { loading, error, empty, works }

class _StripBody extends ConsumerWidget {
  const _StripBody({required this.entity, required this.feedKey});

  final IllustEntity entity;
  final ProfileFeedKey feedKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feed = profileIllustFeedProvider(feedKey);
    final async = ref.watch(feed);
    final store = ref.watch(illustStoreProvider);
    final state = async.asData?.value;
    final works = [
      for (final id in state?.ids ?? const <int>[])
        if (id != entity.id) ?store.get(id),
    ].take(AuthorWorksSlivers.shown).toList();
    final kind = switch (state) {
      null when async.hasError => _StripKind.error,
      null => _StripKind.loading,
      _ when state.showInitialError => _StripKind.error,
      _ when state.showInitialSpinner && state.ids.isEmpty =>
        _StripKind.loading,
      _ when works.isEmpty => _StripKind.empty,
      _ => _StripKind.works,
    };
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    Widget note(String text, {Widget? action}) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: FuncSpacing.xl),
      child: Row(
        children: [
          Expanded(child: Text(text, style: muted)),
          ?action,
        ],
      ),
    );
    return StateFade(
      kind: kind,
      child: switch (kind) {
        _StripKind.loading => FuncSkeleton(
          label: l10n.contentLoading,
          child: const _StripBones(),
        ),
        _StripKind.error => note(
          l10n.detailAuthorWorksLoadFailed,
          action: TextButton(
            onPressed: () => ref.read(feed.notifier).retryInitial(),
            child: Text(l10n.retry),
          ),
        ),
        _StripKind.empty => note(l10n.detailAuthorNoOtherWorks),
        _StripKind.works => SizedBox(
          key: const Key('illust-author-works'),
          height: AuthorWorksSlivers.tileExtent,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: FuncSpacing.xl),
            itemCount: works.length,
            separatorBuilder: (_, _) => const SizedBox(width: FuncSpacing.sm),
            itemBuilder: (context, index) => _WorkTile(work: works[index]),
          ),
        ),
      },
    );
  }
}

class _WorkTile extends StatelessWidget {
  const _WorkTile({required this.work});

  final IllustEntity work;

  @override
  Widget build(BuildContext context) {
    const extent = AuthorWorksSlivers.tileExtent;
    return Semantics(
      button: true,
      label: work.title,
      excludeSemantics: true,
      child: Material(
        borderRadius: FuncShape.card,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => openIllust(context, work.id, initialEntity: work),
          child: PixivImage.feed(
            work.imageUrls.squareMedium,
            layoutWidth: extent,
            width: extent,
            height: extent,
          ),
        ),
      ),
    );
  }
}

class _StripBones extends StatelessWidget {
  const _StripBones();

  @override
  Widget build(BuildContext context) => SizedBox(
    height: AuthorWorksSlivers.tileExtent,
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: FuncSpacing.xl),
      itemCount: 4,
      separatorBuilder: (_, _) => const SizedBox(width: FuncSpacing.sm),
      itemBuilder: (_, _) => const SkeletonBone(
        width: AuthorWorksSlivers.tileExtent,
        height: AuthorWorksSlivers.tileExtent,
        borderRadius: FuncShape.card,
      ),
    ),
  );
}
