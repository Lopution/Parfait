import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/icons/app_icons.dart';
import '../../app/pixiv_image.dart';
import '../../core/i18n/replica_strings.dart';
import '../../core/user/user_entity.dart';
import '../../core/user/user_repository.dart';
import 'follow_switch_button.dart';

/// Pure geometry snapshot used by [ReplicaProfileHeaderDelegate] and tests.
@immutable
class ReplicaProfileHeaderGeometry {
  const ReplicaProfileHeaderGeometry({
    required this.shrinkOffset,
    required this.minExtent,
    required this.maxExtent,
  });

  final double shrinkOffset;
  final double minExtent;
  final double maxExtent;

  double get collapseRange => math.max(0, maxExtent - minExtent);

  double get progress =>
      collapseRange == 0 ? 1 : (shrinkOffset / collapseRange).clamp(0.0, 1.0);

  bool get isFullyCollapsed => shrinkOffset >= collapseRange - 0.5;

  double lerp(double expanded, double collapsed) =>
      expanded + (collapsed - expanded) * progress;

  double get avatarRadius => lerp(72, 20);

  double get backgroundOpacity => 1 - progress;
}

/// Project-owned profile header. It avoids the old extended_sliver delegate:
/// the collapsed title is rendered only at the fully-collapsed extent, never
/// during the transition.
class ReplicaProfileHeaderDelegate extends SliverPersistentHeaderDelegate {
  ReplicaProfileHeaderDelegate({
    required this.user,
    required this.isMe,
    required this.selectedTabIndex,
    required this.showRestrictSelector,
    required this.restrict,
    required this.onRestrictChanged,
    required this.onShare,
    this.onSettings,
    this.expandedExtent = 430,
  });

  final UserEntity user;
  final bool isMe;
  final int selectedTabIndex;
  final bool showRestrictSelector;
  final UserRestrict restrict;
  final ValueChanged<UserRestrict> onRestrictChanged;
  final VoidCallback onShare;
  final VoidCallback? onSettings;
  final double expandedExtent;

  @override
  double get minExtent => kToolbarHeight;

  @override
  double get maxExtent => math.max(expandedExtent, minExtent);

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final geometry = ReplicaProfileHeaderGeometry(
      shrinkOffset: shrinkOffset,
      minExtent: minExtent,
      maxExtent: maxExtent,
    );
    final colors = Theme.of(context).colorScheme;
    final backgroundHeight = maxExtent - 178;
    final canPop = Navigator.of(context).canPop();
    return Material(
      color: colors.surface,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (!geometry.isFullyCollapsed)
            Opacity(
              opacity: geometry.backgroundOpacity,
              child: _ExpandedProfile(
                user: user,
                isMe: isMe,
                backgroundHeight: backgroundHeight,
                onShare: onShare,
                onSettings: onSettings,
              ),
            ),
          if (geometry.isFullyCollapsed)
            _CollapsedProfile(
              user: user,
              isMe: isMe,
              canPop: canPop,
              showRestrictSelector: showRestrictSelector,
              restrict: restrict,
              onRestrictChanged: onRestrictChanged,
              onShare: onShare,
              onSettings: onSettings,
            ),
        ],
      ),
    );
  }

  @override
  bool shouldRebuild(covariant ReplicaProfileHeaderDelegate oldDelegate) {
    return oldDelegate.user != user ||
        oldDelegate.isMe != isMe ||
        oldDelegate.selectedTabIndex != selectedTabIndex ||
        oldDelegate.showRestrictSelector != showRestrictSelector ||
        oldDelegate.restrict != restrict ||
        oldDelegate.expandedExtent != expandedExtent;
  }
}

class _ExpandedProfile extends StatelessWidget {
  const _ExpandedProfile({
    required this.user,
    required this.isMe,
    required this.backgroundHeight,
    required this.onShare,
    required this.onSettings,
  });

  final UserEntity user;
  final bool isMe;
  final double backgroundHeight;
  final VoidCallback onShare;
  final VoidCallback? onSettings;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Stack(
      children: [
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: backgroundHeight,
          child: user.backgroundImageUrl == null
              ? ColoredBox(color: colors.surfaceContainerHighest)
              : PixivImage(url: user.backgroundImageUrl!, fit: BoxFit.cover),
        ),
        Positioned(
          top: backgroundHeight - 72,
          left: 0,
          right: 0,
          child: Center(child: _Avatar(user: user, radius: 72)),
        ),
        Positioned(
          left: 24,
          right: 24,
          bottom: 14,
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      user.name,
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Share',
                    onPressed: onShare,
                    icon: const Icon(Icons.share_outlined),
                  ),
                ],
              ),
              if (user.account.isNotEmpty)
                Text(
                  user.account,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              const SizedBox(height: 7),
              Wrap(
                spacing: 16,
                alignment: WrapAlignment.center,
                children: [
                  _Stat(
                    icon: AppIcons.follow,
                    label: '${user.totalFollowUsers}',
                  ),
                  _Stat(
                    icon: AppIcons.friend,
                    label: '${user.totalMyPixivUsers}',
                  ),
                  _Stat(
                    icon: Icons.palette_outlined,
                    label: '${user.totalIllusts}',
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (isMe)
                IconButton(
                  tooltip: 'Settings',
                  onPressed: onSettings,
                  icon: const Icon(Icons.settings_outlined),
                )
              else
                FollowSwitchButton(
                  userId: user.id,
                  userName: user.name,
                  userAccount: user.account,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CollapsedProfile extends StatelessWidget {
  const _CollapsedProfile({
    required this.user,
    required this.isMe,
    required this.canPop,
    required this.showRestrictSelector,
    required this.restrict,
    required this.onRestrictChanged,
    required this.onShare,
    required this.onSettings,
  });

  final UserEntity user;
  final bool isMe;
  final bool canPop;
  final bool showRestrictSelector;
  final UserRestrict restrict;
  final ValueChanged<UserRestrict> onRestrictChanged;
  final VoidCallback onShare;
  final VoidCallback? onSettings;

  String _text(BuildContext context, String key) => ReplicaStrings.fromTag(
    Localizations.localeOf(context).toLanguageTag(),
    key,
  );

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (canPop)
          IconButton(
            tooltip: 'Back',
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.arrow_back_ios_new),
          )
        else
          const SizedBox(width: 16),
        _Avatar(user: user, radius: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            user.name,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        if (isMe && showRestrictSelector)
          PopupMenuButton<UserRestrict>(
            tooltip: _text(context, 'restrictSelector'),
            initialValue: restrict,
            onSelected: onRestrictChanged,
            itemBuilder: (context) => [
              PopupMenuItem(
                value: UserRestrict.public,
                child: Text(_text(context, 'restrictPublic')),
              ),
              PopupMenuItem(
                value: UserRestrict.private,
                child: Text(_text(context, 'restrictPrivate')),
              ),
            ],
            icon: const Icon(Icons.filter_alt_outlined),
          )
        else if (isMe)
          IconButton(
            tooltip: 'Settings',
            onPressed: onSettings,
            icon: const Icon(Icons.settings_outlined),
          )
        else
          IconButton(
            tooltip: 'Share',
            onPressed: onShare,
            icon: const Icon(Icons.share_outlined),
          ),
        const SizedBox(width: 8),
      ],
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.user, required this.radius});

  final UserEntity user;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: radius,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: ClipOval(
        child: user.profileImageUrl == null
            ? Icon(Icons.person_outline, size: radius)
            : SizedBox(
                width: radius * 2,
                height: radius * 2,
                child: PixivImage(
                  url: user.profileImageUrl!,
                  fit: BoxFit.cover,
                ),
              ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [Icon(icon, size: 14), const SizedBox(width: 4), Text(label)],
    );
  }
}

/// Pinned profile tab bar and the beta56 re-tap type selector.
class ReplicaProfileTabsDelegate extends SliverPersistentHeaderDelegate {
  ReplicaProfileTabsDelegate({
    required this.controller,
    required this.isMe,
    required this.expanded,
    required this.workType,
    required this.onTabTap,
    required this.onWorkTypeChanged,
  });

  final TabController controller;
  final bool isMe;
  final bool expanded;
  final UserWorkType workType;
  final ValueChanged<int> onTabTap;
  final ValueChanged<UserWorkType> onWorkTypeChanged;

  @override
  double get minExtent => kToolbarHeight;

  @override
  double get maxExtent => kToolbarHeight + (expanded ? 64 : 0);

  String _text(BuildContext context, String key) => ReplicaStrings.fromTag(
    Localizations.localeOf(context).toLanguageTag(),
    key,
  );

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final labels = isMe
        ? [
            'profileBookmarked',
            'profileFollowing',
            'profileFans',
            'profileMyPixiv',
            'profileWork',
          ]
        : [
            'profileWork',
            'profileBookmarked',
            'profileFollowing',
            'profileAbout',
          ];
    final isWorkTab = isMe ? controller.index == 4 : controller.index == 0;
    return Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Column(
        children: [
          SizedBox(
            height: kToolbarHeight,
            child: TabBar(
              controller: controller,
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              onTap: onTabTap,
              tabs: [
                for (final label in labels) Tab(text: _text(context, label)),
              ],
            ),
          ),
          if (expanded && isWorkTab)
            SizedBox(
              height: 64,
              child: Center(
                child: Wrap(
                  spacing: 8,
                  children: [
                    for (final type in [
                      UserWorkType.illust,
                      UserWorkType.manga,
                      UserWorkType.novel,
                    ])
                      ChoiceChip(
                        label: Text(
                          _text(context, switch (type) {
                            UserWorkType.illust => 'profileIllust',
                            UserWorkType.manga => 'profileManga',
                            UserWorkType.novel => 'profileNovel',
                          }),
                        ),
                        selected: workType == type,
                        onSelected: (_) => onWorkTypeChanged(type),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  bool shouldRebuild(covariant ReplicaProfileTabsDelegate oldDelegate) =>
      oldDelegate.controller != controller ||
      oldDelegate.isMe != isMe ||
      oldDelegate.expanded != expanded ||
      oldDelegate.workType != workType;
}
