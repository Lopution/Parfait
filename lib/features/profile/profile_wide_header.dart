import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/format/app_format.dart';
import '../../app/icons/app_icons.dart';
import '../../app/layout/content_widths.dart';
import '../../app/motion/hero_transition.dart' show LiftableBar;
import '../../app/person_avatar.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../app/widgets/app_menu_button.dart';
import '../../app/widgets/app_tab_bar.dart';
import '../../app/widgets/app_top_bar.dart';
import '../../app/widgets/edge_icon_buttons.dart';
import '../../app/widgets/expandable_text.dart';
import '../../core/user/follow_models.dart';
import '../../core/user/user_entity.dart';
import '../../l10n/context.dart';
import 'profile_header_delegate.dart';
import 'profile_statistics.dart';

/// Overflow menu for secondary (and optionally collapsed primary) profile
/// actions rendered on wide-layout toolbars.
class ProfileSecondaryMenuButton extends StatelessWidget {
  const ProfileSecondaryMenuButton({
    super.key,
    required this.isMe,
    this.isFollowed = false,
    this.followRestrict,
    this.includePrimary = false,
    this.onShare,
    this.onEditProfile,
    this.onToggleFollow,
    this.onFollowPrivately,
    this.onDownloadAll,
    this.onCopyLink,
    this.isMuted = false,
    this.onToggleMute,
  });

  final bool isMe;
  final bool isFollowed;
  final FollowRestrict? followRestrict;
  final bool includePrimary;
  final ValueChanged<BuildContext>? onShare;
  final VoidCallback? onEditProfile;
  final VoidCallback? onToggleFollow;
  final VoidCallback? onFollowPrivately;
  final VoidCallback? onDownloadAll;
  final VoidCallback? onCopyLink;
  final bool isMuted;
  final VoidCallback? onToggleMute;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final entries = <AppMenuEntry<ValueChanged<BuildContext>>>[
      if (includePrimary && onShare != null)
        AppMenuEntry(
          value: onShare!,
          label: l10n.profileShare,
          icon: AppIcons.share,
        ),
      if (includePrimary && isMe && onEditProfile != null)
        AppMenuEntry(
          value: (_) => onEditProfile!(),
          label: l10n.profileEditTitle,
          icon: AppIcons.edit,
        ),
      if (includePrimary && !isMe && onToggleFollow != null)
        AppMenuEntry(
          value: (_) => onToggleFollow!(),
          label: isFollowed ? l10n.unfollow : l10n.follow,
          icon: AppIcons.follow,
        ),
      if (!isMe && onFollowPrivately != null)
        AppMenuEntry(
          value: (_) => onFollowPrivately!(),
          label: !isFollowed
              ? l10n.followPrivately
              : switch (followRestrict) {
                  FollowRestrict.private => l10n.followSwitchToPublic,
                  FollowRestrict.public => l10n.followSwitchToPrivate,
                  null => l10n.followSwitchVisibility,
                },
          icon: AppIcons.lock,
        ),
      if (onDownloadAll != null)
        AppMenuEntry(
          value: (_) => onDownloadAll!(),
          label: l10n.downloadAuthorWorks,
          icon: AppIcons.download,
        ),
      if (onCopyLink != null)
        AppMenuEntry(
          value: (_) => onCopyLink!(),
          label: l10n.copyLink,
          icon: AppIcons.copy,
        ),
      if (!isMe && onToggleMute != null)
        AppMenuEntry(
          value: (_) => onToggleMute!(),
          label: isMuted ? l10n.unmuteAuthor : l10n.muteAuthor,
          icon: isMuted ? AppIcons.userOffFilled : AppIcons.userOff,
        ),
    ];
    if (entries.isEmpty) return const SizedBox.shrink();
    return AppMenuButton<ValueChanged<BuildContext>>(
      onSelected: (anchorContext, run) => run(anchorContext),
      entries: entries,
    );
  }
}

/// Wide two-band panoramic profile header rendered above [WideProfileTabsDelegate].
class WideProfileBannerHeader extends StatelessWidget {
  const WideProfileBannerHeader({
    super.key,
    required this.user,
    required this.bio,
    required this.stats,
    required this.primaryAction,
    required this.shareButton,
  });

  static const double bannerHeight = 164.0;
  static const double _avatarDiameter = 88.0;

  /// Outer scroll offset past which the banner and Band-1 actions have scrolled
  /// offscreen so the sticky tab bar switches into its compact collapsed mode.
  static const double collapseThreshold = bannerHeight + FuncSpacing.lg;

  final UserEntity user;
  final String? bio;
  final List<ProfileHeaderStat> stats;
  final Widget? primaryAction;
  final Widget shareButton;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isRtl = Directionality.of(context) == TextDirection.rtl;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: bannerHeight,
              child: ProfileBannerBackground(user: user),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: FuncSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Band 1: Full header width framing name/@handle beside the
                  // avatar's lower half and actions flush to the right margin.
                  ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: _avatarDiameter / 2 + FuncSpacing.md,
                    ),
                    child: Padding(
                      padding: const EdgeInsetsDirectional.fromSTEB(
                        FuncSpacing.lg + _avatarDiameter + FuncSpacing.lg,
                        FuncSpacing.sm,
                        FuncSpacing.lg - EdgeIconButtons.glyphInset,
                        0,
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  key: const ValueKey('profile-expanded-name'),
                                  user.name,
                                  style: theme.textTheme.headlineSmall
                                      ?.copyWith(fontWeight: FontWeight.w700),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                if (user.account.isNotEmpty) ...[
                                  const SizedBox(height: FuncSpacing.xxs),
                                  Text(
                                    '@${user.account}',
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ],
                            ),
                          ),
                          const SizedBox(width: FuncSpacing.lg),
                          if (primaryAction != null) ...[
                            primaryAction!,
                            const SizedBox(width: FuncSpacing.xs),
                          ],
                          shareButton,
                        ],
                      ),
                    ),
                  ),
                  // Band 2: Single-line inline stats and bio flush-left with
                  // the 16dp avatar margin, capped for readable bio measure.
                  if (stats.isNotEmpty || (bio != null && bio!.isNotEmpty))
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: FuncSpacing.lg,
                      ),
                      child: Align(
                        alignment: AlignmentDirectional.topStart,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(
                            maxWidth: ContentWidths.management,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (stats.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(
                                    top: FuncSpacing.xs,
                                  ),
                                  child: Transform.translate(
                                    offset: Offset(
                                      isRtl ? FuncSpacing.xs : -FuncSpacing.xs,
                                      0,
                                    ),
                                    child: _WideProfileInlineStats(
                                      stats: stats,
                                    ),
                                  ),
                                ),
                              if (bio != null && bio!.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(
                                    top: FuncSpacing.xs,
                                  ),
                                  child: ExpandableText(
                                    TextSpan(text: bio!),
                                    key: const ValueKey('profile-wide-bio'),
                                    maxLines: 3,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      height: 1.45,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        PositionedDirectional(
          start: FuncSpacing.lg,
          top: bannerHeight - _avatarDiameter / 2,
          child: KeyedSubtree(
            key: const ValueKey('profile-expanded-avatar'),
            child: PersonAvatar(
              imageUrl: user.profileImageUrl,
              radius: _avatarDiameter / 2,
              ring: true,
            ),
          ),
        ),
      ],
    );
  }
}

/// Horizontal inline counters for the wide panoramic profile header (`50 关注`),
/// preserving per-stat semantics keys and tap navigation.
class _WideProfileInlineStats extends StatelessWidget {
  const _WideProfileInlineStats({required this.stats});

  final List<ProfileHeaderStat> stats;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final figureStyle = theme.textTheme.titleMedium
        ?.copyWith(fontWeight: FontWeight.w700)
        .tabular;
    final labelStyle = theme.textTheme.bodyMedium?.copyWith(
      color: colors.onSurfaceVariant,
    );

    return Wrap(
      spacing: FuncSpacing.md,
      runSpacing: FuncSpacing.xxs,
      children: [
        for (final stat in stats)
          Builder(
            builder: (context) {
              final figure = AppFormat.count(context, stat.value);
              return Semantics(
                key: ValueKey('profile-stat-${stat.id}-header'),
                container: true,
                button: stat.onTap != null,
                label: '${stat.label}, $figure',
                onTap: stat.onTap,
                child: ExcludeSemantics(
                  child: InkWell(
                    borderRadius: FuncShape.control,
                    onTap: stat.onTap,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 36),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: FuncSpacing.xs,
                          vertical: FuncSpacing.xxs,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.baseline,
                          textBaseline: TextBaseline.alphabetic,
                          children: [
                            Text(figure, style: figureStyle),
                            const SizedBox(width: FuncSpacing.xs),
                            Text(stat.label, style: labelStyle),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}

/// Sticky tab bar below [WideProfileBannerHeader]. Once the banner scrolls
/// away on desktop chrome ([collapsed]), shows a compact leading avatar + name
/// while the trailing overflow folds in the primary actions.
class WideProfileTabsDelegate extends SliverPersistentHeaderDelegate {
  const WideProfileTabsDelegate({
    required this.controller,
    required this.labels,
    required this.onTabTap,
    required this.dragBehavior,
    required this.scrolled,
    required this.collapsed,
    required this.user,
    required this.useDesktopChrome,
    required this.showsGalleryControls,
    required this.followed,
    required this.muted,
    required this.selectedTabKey,
    required this.hairline,
    required this.trailing,
  });

  final TabController controller;
  final List<String> labels;
  final ValueChanged<int> onTabTap;
  final ScrollBehavior dragBehavior;
  final bool scrolled;
  final bool collapsed;
  final UserEntity user;
  final bool useDesktopChrome;
  final bool showsGalleryControls;
  final bool followed;
  final bool muted;
  final Object? selectedTabKey;
  final Color hairline;
  final Widget? trailing;

  @override
  double get minExtent =>
      useDesktopChrome ? kDesktopPageHeaderHeight : kToolbarHeight;

  @override
  double get maxExtent => minExtent;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final theme = Theme.of(context);
    return LiftableBar(
      child: ScrollEdgeShadow(
        visible: scrolled,
        child: Material(
          key: const ValueKey('profile-tabs'),
          color: theme.scaffoldBackgroundColor,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: scrolled
                  ? null
                  : Border(bottom: BorderSide(color: hairline)),
            ),
            child: SizedBox(
              height: minExtent,
              child: Row(
                children: [
                  if (collapsed && useDesktopChrome)
                    Padding(
                      padding: const EdgeInsetsDirectional.only(
                        start: FuncSpacing.lg,
                        end: FuncSpacing.sm,
                      ),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 180),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            PersonAvatar(
                              imageUrl: user.profileImageUrl,
                              radius: 12,
                            ),
                            const SizedBox(width: FuncSpacing.sm),
                            Flexible(
                              child: Text(
                                key: const ValueKey(
                                  'profile-wide-collapsed-name',
                                ),
                                user.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsetsDirectional.only(
                        start: FuncSpacing.xxs,
                      ),
                      child: ScrollConfiguration(
                        behavior: dragBehavior,
                        child: AppTabBar(
                          controller: controller,
                          onTap: onTabTap,
                          labels: labels,
                          maxEqualSlotWidth: 76,
                        ),
                      ),
                    ),
                  ),
                  ?trailing,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant WideProfileTabsDelegate oldDelegate) =>
      oldDelegate.controller != controller ||
      !listEquals(oldDelegate.labels, labels) ||
      oldDelegate.onTabTap != onTabTap ||
      oldDelegate.dragBehavior != dragBehavior ||
      oldDelegate.scrolled != scrolled ||
      oldDelegate.collapsed != collapsed ||
      oldDelegate.user != user ||
      oldDelegate.useDesktopChrome != useDesktopChrome ||
      oldDelegate.showsGalleryControls != showsGalleryControls ||
      oldDelegate.followed != followed ||
      oldDelegate.muted != muted ||
      oldDelegate.selectedTabKey != selectedTabKey ||
      oldDelegate.hairline != hairline;
}
