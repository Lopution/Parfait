import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/format/app_format.dart';
import '../../../../app/navigation/routes.dart';
import '../../../../app/theme/func_semantic_tokens.dart';
import '../../../../app/widgets/author_row.dart';
import '../../../../app/widgets/follow_switch_button.dart';
import '../../../../app/widgets/tag_chips.dart';
import '../../../../core/auth/account_store.dart';
import '../../../../core/entity/illust_entity.dart';
import '../../../../core/mute/mute_store.dart';
import '../../../../l10n/context.dart';
import '../../../../app/widgets/caption_rich_text.dart';
import '../../../../app/widgets/inline_translation.dart';
import '../../../../app/widgets/tag_actions_sheet.dart';
import '../../../../core/entity/illust_caption.dart';

class InfoBlock extends ConsumerWidget {
  const InfoBlock({
    super.key,
    required this.entity,
    required this.blockMode,
    required this.onToggleBlockMode,
  });

  final IllustEntity entity;
  final bool blockMode;
  final VoidCallback onToggleBlockMode;

  /// Collapsed caption height; longer captions get a Show more toggle.
  static const captionLines = 4;

  String? _postedDate(BuildContext context) {
    final created = DateTime.tryParse(entity.createDate ?? '');
    return created == null ? null : AppFormat.date(context, created);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Tag chips now block through the MuteStore: tag mutes sync with the
    // official /v1/mute list instead of the legacy local-only pref.
    final mutedTags = ref.watch(muteStoreProvider.select((s) => s.tags));
    final muteStore = ref.read(muteStoreProvider.notifier);
    final ownUserId = ref.watch(
      accountStoreProvider.select(
        (async) => async.value?.usableCurrent?.userId,
      ),
    );
    final author = entity.user;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: FuncSpacing.xl,
        vertical: FuncSpacing.xl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Official client order: the work title
          // leads the meta block, wraps without a line cap, and stays
          // selectable — a one-line AppBar title could only ellipsise.
          // Without a caption the title carries the translate button.
          if (entity.caption.isEmpty)
            _TranslatableTitle(title: entity.title)
          else
            _Title(title: entity.title),
          if (_postedDate(context) case final date?) ...[
            const SizedBox(height: FuncSpacing.xs),
            Text(
              date,
              key: const Key('illust-detail-date'),
              style: _metaStyle(context),
            ),
          ],
          const SizedBox(height: FuncSpacing.lg),
          _StatsBlock(entity: entity),
          const SizedBox(height: FuncSpacing.md),
          _BlockSurface(
            padding: const EdgeInsetsDirectional.fromSTEB(
              FuncSpacing.md,
              FuncSpacing.sm,
              FuncSpacing.md,
              FuncSpacing.sm,
            ),
            child: AuthorRow(
              key: const Key('illust-author-row'),
              userId: author.id,
              name: author.name,
              avatarUrl: author.profileImageUrl,
              avatarRadius: 24,
              trailing: author.id == ownUserId
                  ? null
                  : FollowSwitchButton(
                      userId: author.id,
                      userName: author.name,
                      userAccount: author.account,
                      compact: true,
                    ),
            ),
          ),
          if (entity.caption.isNotEmpty)
            _CaptionSection(
              key: const Key('illust-detail-caption'),
              entity: entity,
            ),
          _Section(
            key: const Key('illust-detail-tags'),
            heading: context.l10n.detailSectionTags,
            child: TagChips(
              children: [
                for (final tag in entity.tags)
                  TagChip(
                    label: tag.name,
                    translated: tag.translatedName,
                    blockMode: blockMode,
                    blocked: mutedTags.contains(tag.name),
                    onTap: () {
                      if (blockMode) {
                        unawaited(
                          toggleTagMute(
                            context,
                            muteStore,
                            tag.name,
                            muted: mutedTags.contains(tag.name),
                          ),
                        );
                      } else {
                        openTagSearch(context, tag.name);
                      }
                    },
                    // Long-press opens the direct action menu (search /
                    // copy / mute / batch-mute entry) instead of silently
                    // flipping the block mode.
                    onLongPress: () => unawaited(
                      showTagActionsSheet(
                        context,
                        tag: tag.name,
                        muted: mutedTags.contains(tag.name),
                        onSearch: () => openTagSearch(context, tag.name),
                        onToggleMute: () => unawaited(
                          toggleTagMute(
                            context,
                            muteStore,
                            tag.name,
                            muted: mutedTags.contains(tag.name),
                          ),
                        ),
                        onMuteMode: onToggleBlockMode,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: FuncSpacing.lg),
          // ID stays selectable: users quote artwork IDs. SelectableText,
          // not SelectionArea — SelectionArea pulls in the whole
          // SelectableRegion/context-menu machinery (~180KB AOT) that
          // nothing else in the app uses, while SelectableText is already
          // compiled in for the title.
          SelectableText(
            '${entity.width}×${entity.height} · ID ${entity.id}',
            key: const Key('illust-detail-footer'),
            style: _metaStyle(context),
          ),
        ],
      ),
    );
  }
}

/// The secondary metadata tier: the theme's small body text, tabular.
TextStyle _metaStyle(BuildContext context) {
  final theme = Theme.of(context);
  return theme.textTheme.bodySmall!
      .copyWith(color: theme.colorScheme.onSurfaceVariant)
      .tabular;
}

/// The work's reception at a glance: views and bookmarks as large tabular
/// figures over small labels. Every list payload carries both, so the row
/// is complete on a neighbour page before it is swiped in; the comment
/// count only the detail API has sits on the comments section instead.
/// Screen readers hear one sentence.
class _StatsBlock extends StatelessWidget {
  const _StatsBlock({required this.entity});

  final IllustEntity entity;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final views = AppFormat.count(context, entity.totalView);
    final bookmarks = AppFormat.count(context, entity.totalBookmarks);
    return Semantics(
      key: const Key('illust-detail-stats'),
      container: true,
      label: l10n.detailMetaCountsSemantics(views, bookmarks),
      child: ExcludeSemantics(
        child: _BlockSurface(
          padding: const EdgeInsets.symmetric(
            horizontal: FuncSpacing.sm,
            vertical: FuncSpacing.md,
          ),
          child: Row(
            children: [
              _Stat(value: views, label: l10n.detailStatViews),
              _Stat(value: bookmarks, label: l10n.detailStatBookmarks),
            ],
          ),
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        children: [
          // A long compact count in a narrow column shrinks, never wraps.
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              maxLines: 1,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(height: FuncSpacing.xxs),
          Text(
            label,
            textAlign: TextAlign.center,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// The neutral container the stats and author blocks stand on.
class _BlockSurface extends StatelessWidget {
  const _BlockSurface({required this.padding, required this.child});

  final EdgeInsetsGeometry padding;
  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: FuncShape.card,
    ),
    child: Padding(padding: padding, child: child),
  );
}

/// The work title: large, wrapping without a line cap, selectable.
class _Title extends StatelessWidget {
  const _Title({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => SelectableText(
    title,
    style: Theme.of(
      context,
    ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
  );
}

/// The title of a work without a caption, with the translate button at its
/// end and the translation below.
class _TranslatableTitle extends ConsumerStatefulWidget {
  const _TranslatableTitle({required this.title});

  final String title;

  @override
  ConsumerState<_TranslatableTitle> createState() => _TranslatableTitleState();
}

class _TranslatableTitleState extends ConsumerState<_TranslatableTitle>
    with InlineTranslation {
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: _Title(title: widget.title)),
          TranslateIconButton(
            translating: translating,
            shown: translationShown,
            onPressed: () => unawaited(toggleTranslation([widget.title])),
          ),
        ],
      ),
      TranslationPanel(
        translating: translating,
        translations: translations,
        failure: translationFailure,
      ),
    ],
  );
}

/// The caption section. Its translate button translates the title and the
/// caption together and shows both below the caption.
class _CaptionSection extends ConsumerStatefulWidget {
  const _CaptionSection({super.key, required this.entity});

  final IllustEntity entity;

  @override
  ConsumerState<_CaptionSection> createState() => _CaptionSectionState();
}

class _CaptionSectionState extends ConsumerState<_CaptionSection>
    with InlineTranslation {
  @override
  Widget build(BuildContext context) {
    final entity = widget.entity;
    return _Section(
      heading: context.l10n.detailSectionCaption,
      action: TranslateIconButton(
        translating: translating,
        shown: translationShown,
        onPressed: () => unawaited(
          toggleTranslation([
            entity.title,
            ?_nonBlank(captionPlainText(entity.caption)),
          ]),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Pixiv captions are HTML; render them immediately so the
          // detail content is complete on the same frame as the artwork.
          CaptionRichText(
            caption: entity.caption,
            maxLines: InfoBlock.captionLines,
          ),
          TranslationPanel(
            translating: translating,
            translations: translations,
            failure: translationFailure,
            emphasizeFirst: true,
          ),
        ],
      ),
    );
  }
}

String? _nonBlank(String text) => text.trim().isEmpty ? null : text;

/// One titled part of the info area: a heading, then its content. [action]
/// sits at the end of the heading row.
class _Section extends StatelessWidget {
  const _Section({
    super.key,
    required this.heading,
    required this.child,
    this.action,
  });

  final String heading;
  final Widget child;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: FuncSpacing.xl),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Semantics(
                header: true,
                child: Text(
                  heading,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ),
            ?action,
          ],
        ),
        // The button's own padding already spaces the heading.
        if (action == null) const SizedBox(height: FuncSpacing.sm),
        child,
      ],
    ),
  );
}
