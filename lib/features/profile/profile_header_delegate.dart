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

  /// Expanded avatar radius. 104dp across reads as an identity element next
  /// to the background band; the previous 144dp filled the band and, for the
  /// default placeholder, looked like a watermark.
  static const expandedAvatarRadius = 52.0;

  /// Collapsed avatar radius — the toolbar-row size.
  static const collapsedAvatarRadius = 20.0;

  /// How far the expanded avatar hangs below the background image. Kept from
  /// the previous layout so the gap to the name row does not change.
  static const _avatarOverhang = 24.0;

  /// The avatar reaches its collapsed anchor before the header does, so it is
  /// already parked beside the leading slot when the toolbar chrome appears.
  static const _avatarSettleProgress = 0.9;

  /// The toolbar chrome fades in only once the avatar has parked. Starting
  /// earlier would sweep the still-shrinking avatar across the title, whose
  /// 96px inset is sized for the collapsed avatar.
  static const _collapsedFadeStart = _avatarSettleProgress;

  final double shrinkOffset;
  final double minExtent;
  final double maxExtent;

  double get collapseRange => math.max(0, maxExtent - minExtent);

  double get progress =>
      collapseRange == 0 ? 1 : (shrinkOffset / collapseRange).clamp(0.0, 1.0);

  bool get isFullyCollapsed => shrinkOffset >= collapseRange - 0.5;

  double lerp(double expanded, double collapsed) =>
      expanded + (collapsed - expanded) * progress;

  /// [progress] remapped onto the avatar's own travel, which finishes early.
  double get _avatarProgress =>
      (progress / _avatarSettleProgress).clamp(0.0, 1.0);

  double get avatarRadius =>
      expandedAvatarRadius +
      (collapsedAvatarRadius - expandedAvatarRadius) * _avatarProgress;

  /// Avatar centre inside the header box, interpolated between the expanded
  /// anchor (horizontally centred, straddling the background edge) and the
  /// collapsed anchor (toolbar row, immediately right of the leading slot).
  ///
  /// [collapsedLeftInset] is the x of the avatar's left edge once collapsed:
  /// the row padding plus the back button when the route can pop.
  Offset avatarCenter({
    required double headerWidth,
    required double backgroundHeight,
    required double collapsedLeftInset,
  }) {
    final expanded = Offset(
      headerWidth / 2,
      backgroundHeight + _avatarOverhang - expandedAvatarRadius,
    );
    final collapsed = Offset(
      collapsedLeftInset + collapsedAvatarRadius,
      minExtent / 2,
    );
    return Offset.lerp(expanded, collapsed, _avatarProgress)!;
  }

  double get backgroundOpacity => 1 - progress;

  /// Opacity of the collapsed toolbar chrome (back button, title, actions).
  double get collapsedOpacity =>
      ((progress - _collapsedFadeStart) / (1 - _collapsedFadeStart)).clamp(
        0.0,
        1.0,
      );
}

/// Project-owned profile header. It avoids the old extended_sliver delegate.
///
/// The avatar is its own layer rather than living inside the expanded and
/// collapsed subtrees: it interpolates size and position continuously and
/// stays fully opaque, so it never fades out with the background image.
class ReplicaProfileHeaderDelegate extends SliverPersistentHeaderDelegate {
  ReplicaProfileHeaderDelegate({
    required this.user,
    required this.isMe,
    required this.selectedTabIndex,
    required this.showRestrictSelector,
    required this.restrict,
    required this.onRestrictChanged,
    required this.onShare,
    this.onEditProfile,
    this.expandedExtent = 430,
  });

  final UserEntity user;
  final bool isMe;
  final int selectedTabIndex;
  final bool showRestrictSelector;
  final UserRestrict restrict;
  final ValueChanged<UserRestrict> onRestrictChanged;
  final VoidCallback onShare;
  final VoidCallback? onEditProfile;
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
      child: LayoutBuilder(
        builder: (context, constraints) {
          final radius = geometry.avatarRadius;
          final center = geometry.avatarCenter(
            headerWidth: constraints.maxWidth,
            backgroundHeight: backgroundHeight,
            // Where the collapsed avatar's left edge lands: the row padding,
            // plus the back button slot when the route can pop.
            collapsedLeftInset: canPop
                ? 8 + kMinInteractiveDimension
                : 16,
          );
          return Stack(
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
                    onEditProfile: onEditProfile,
                  ),
                ),
              if (geometry.collapsedOpacity > 0)
                Align(
                  alignment: Alignment.topCenter,
                  child: SizedBox(
                    // Pinned to the toolbar strip. Letting it fill the
                    // shrinking box instead would slide the title down into
                    // the artwork and across the travelling avatar.
                    height: minExtent,
                    child: Opacity(
                      opacity: geometry.collapsedOpacity,
                      child: IgnorePointer(
                        // Hit testing stays exactly as before: the collapsed
                        // controls only take taps once they are the only
                        // thing on screen.
                        ignoring: !geometry.isFullyCollapsed,
                        child: _CollapsedProfile(
                          user: user,
                          isMe: isMe,
                          canPop: canPop,
                          showRestrictSelector: showRestrictSelector,
                          restrict: restrict,
                          onRestrictChanged: onRestrictChanged,
                          onShare: onShare,
                          onEditProfile: onEditProfile,
                        ),
                      ),
                    ),
                  ),
                ),
              Positioned(
                left: center.dx - radius,
                top: center.dy - radius,
                width: radius * 2,
                height: radius * 2,
                child: _Avatar(user: user, radius: radius),
              ),
            ],
          );
        },
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
        oldDelegate.onEditProfile != onEditProfile ||
        oldDelegate.expandedExtent != expandedExtent;
  }
}

class _ExpandedProfile extends StatelessWidget {
  const _ExpandedProfile({
    required this.user,
    required this.isMe,
    required this.backgroundHeight,
    required this.onShare,
    required this.onEditProfile,
  });

  final UserEntity user;
  final bool isMe;
  final double backgroundHeight;
  final VoidCallback onShare;
  final VoidCallback? onEditProfile;

  String _profileText(BuildContext context, String key) =>
      ReplicaStrings.fromTag(
        Localizations.localeOf(context).toLanguageTag(),
        key,
      );

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
          left: 24,
          right: 24,
          bottom: 14,
          child: Column(
            children: [
              SizedBox(
                height: 48,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 56),
                      child: Center(
                        child: Text(
                          user.name,
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      right: 0,
                      top: 0,
                      child: IconButton(
                        tooltip: 'Share',
                        onPressed: onShare,
                        icon: const Icon(Icons.share_outlined),
                      ),
                    ),
                  ],
                ),
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
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (onEditProfile != null)
                      IconButton(
                        tooltip: _profileText(context, 'profileEditTitle'),
                        onPressed: onEditProfile,
                        icon: const Icon(Icons.edit_outlined),
                      ),
                  ],
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
    required this.onEditProfile,
  });

  final UserEntity user;
  final bool isMe;
  final bool canPop;
  final bool showRestrictSelector;
  final UserRestrict restrict;
  final ValueChanged<UserRestrict> onRestrictChanged;
  final VoidCallback onShare;
  final VoidCallback? onEditProfile;

  String _text(BuildContext context, String key) => ReplicaStrings.fromTag(
    Localizations.localeOf(context).toLanguageTag(),
    key,
  );

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: EdgeInsets.only(left: canPop ? 8 : 16),
            // The avatar that used to sit here is now a delegate-level layer;
            // the title's fixed 96px inset still reserves its slot.
            child: canPop
                ? IconButton(
                    tooltip: 'Back',
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.arrow_back_ios_new),
                  )
                : const SizedBox.shrink(),
          ),
        ),
        Positioned.fill(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 96),
            child: Center(
              child: Text(
                user.name,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.only(right: 8),
            child: isMe && showRestrictSelector
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
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
                      ),
                      if (onEditProfile != null)
                        IconButton(
                          tooltip: _text(context, 'profileEditTitle'),
                          onPressed: onEditProfile,
                          icon: const Icon(Icons.edit_outlined),
                        ),
                    ],
                  )
                : isMe
                ? (onEditProfile != null
                      ? IconButton(
                          tooltip: _text(context, 'profileEditTitle'),
                          onPressed: onEditProfile,
                          icon: const Icon(Icons.edit_outlined),
                        )
                      : const SizedBox.shrink())
                : IconButton(
                    tooltip: 'Share',
                    onPressed: onShare,
                    icon: const Icon(Icons.share_outlined),
                  ),
          ),
        ),
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
