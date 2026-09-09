import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/icons/app_icons.dart';
import '../../app/person_avatar.dart';
import '../../app/pixiv_image.dart';
import '../../core/i18n/replica_strings.dart';
import '../../core/user/user_entity.dart';
import '../../core/user/user_repository.dart';
import 'follow_switch_button.dart';
import '../../l10n/context.dart';

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

  /// Historical collapsed avatar radius. The current header deliberately does
  /// not render an avatar in the toolbar; keeping the constant avoids breaking
  /// callers that use the geometry type as a small design token.
  static const collapsedAvatarRadius = 20.0;

  /// How far the expanded avatar hangs below the background image. Keeping the
  /// overhang modest leaves a dedicated gap for the name row below it.
  static const _avatarOverhang = 8.0;

  /// The expanded identity block is laid out as one unit and translated out
  /// of the shrinking header. It leaves a little earlier than the toolbar
  /// title starts, so neither the avatar nor the expanded name can cross it.
  static const expandedIdentityExitProgress = 0.78;
  static const expandedDetailsFadeStart = 0.55;

  /// A native flexible-space header scrolls its background content out of the
  /// pinned toolbar. The factor gives the identity block enough travel to
  /// clear the toolbar before the header reaches its minimum extent.
  static const _expandedContentTravelFactor = 1.25;

  final double shrinkOffset;
  final double minExtent;
  final double maxExtent;

  double get collapseRange => math.max(0, maxExtent - minExtent);

  double get progress =>
      collapseRange == 0 ? 1 : (shrinkOffset / collapseRange).clamp(0.0, 1.0);

  bool get isFullyCollapsed => shrinkOffset >= collapseRange - 0.5;

  /// Kept as a convenience for other header geometry callers. The current
  /// design has one expanded avatar rather than an expanded/collapsed pair.
  double lerp(double expanded, double collapsed) =>
      expanded + (collapsed - expanded) * progress;

  /// The avatar stays an expanded identity element instead of shrinking into
  /// the toolbar. It is clipped as the expanded block leaves the header.
  double get avatarRadius => expandedAvatarRadius;

  /// Vertical translation applied to the expanded identity block.
  double get expandedContentOffset =>
      -shrinkOffset * _expandedContentTravelFactor;

  /// Fade only the text/actions block. The avatar remains opaque until it has
  /// physically left the clipped expanded area, avoiding the old watermark
  /// effect on placeholder avatars.
  double get expandedDetailsOpacity =>
      1 -
      ((progress - expandedDetailsFadeStart) /
              (expandedIdentityExitProgress - expandedDetailsFadeStart))
          .clamp(0.0, 1.0);

  bool get showExpandedIdentity => progress < expandedIdentityExitProgress;

  /// Avatar centre in the expanded coordinate space, including the same
  /// translation used by the identity block. [collapsedLeftInset] is retained
  /// for source compatibility but is intentionally ignored: no avatar is
  /// placed in the toolbar anymore.
  Offset avatarCenter({
    required double headerWidth,
    required double backgroundHeight,
    required double collapsedLeftInset,
  }) {
    final expanded = Offset(
      headerWidth / 2,
      backgroundHeight + _avatarOverhang - expandedAvatarRadius,
    );
    return expanded.translate(0, expandedContentOffset);
  }

  double get backgroundOpacity => 1 - progress;

  /// Opacity of the collapsed toolbar chrome (back button, title, actions).
  double get collapsedOpacity =>
      ((progress - expandedIdentityExitProgress) /
              (1 - expandedIdentityExitProgress))
          .clamp(0.0, 1.0);
}

/// Project-owned profile header. It avoids the old extended_sliver delegate.
///
/// The expanded profile follows the same separation used by PixEz's
/// [SliverAppBar]: artwork and identity content live in the flexible area,
/// while the pinned toolbar has its own controls. The avatar therefore scrolls
/// out with the name instead of travelling into the toolbar.
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
    this.topInset = 0,
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
  final double topInset;

  @override
  double get minExtent => kToolbarHeight + topInset;

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
    // The artwork band covers the whole expanded header; identity content
    // sits on a bottom gradient so the text stays readable over any image.
    final backgroundHeight = maxExtent;
    final canPop = Navigator.of(context).canPop();
    return Material(
      color: colors.surface,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return Stack(
            fit: StackFit.expand,
            clipBehavior: Clip.hardEdge,
            children: [
              // Keep the artwork pinned while it fades, as in PixEz's
              // FlexibleSpaceBar. Identity content below is translated out
              // separately so the avatar never shares the fade curve.
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: backgroundHeight,
                child: Opacity(
                  opacity: geometry.backgroundOpacity,
                  child: _ProfileBackground(user: user, withScrim: true),
                ),
              ),
              if (geometry.showExpandedIdentity)
                Positioned(
                  top: geometry.expandedContentOffset,
                  left: 0,
                  width: constraints.maxWidth,
                  height: maxExtent,
                  child: _ExpandedProfile(
                    user: user,
                    isMe: isMe,
                    backgroundHeight: backgroundHeight,
                    detailsOpacity: geometry.expandedDetailsOpacity,
                    onShare: onShare,
                    onEditProfile: onEditProfile,
                  ),
                ),
              if (geometry.collapsedOpacity > 0)
                Align(
                  alignment: Alignment.topCenter,
                  child: SizedBox(
                    // The status-bar inset belongs above the actual 56dp
                    // toolbar controls. This keeps pinned chrome out of the
                    // system UI on targetSdk 36 edge-to-edge devices.
                    height: minExtent,
                    child: Padding(
                      padding: EdgeInsets.only(top: topInset),
                      child: SizedBox(
                        height: kToolbarHeight,
                        child: Opacity(
                          opacity: geometry.collapsedOpacity,
                          child: IgnorePointer(
                            // Hit testing stays disabled until the toolbar is
                            // the only visible header state.
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
                  ),
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
        oldDelegate.onShare != onShare ||
        oldDelegate.onRestrictChanged != onRestrictChanged ||
        oldDelegate.expandedExtent != expandedExtent ||
        oldDelegate.topInset != topInset;
  }
}

class _ExpandedProfile extends StatelessWidget {
  const _ExpandedProfile({
    required this.user,
    required this.isMe,
    required this.backgroundHeight,
    required this.detailsOpacity,
    required this.onShare,
    required this.onEditProfile,
  });

  final UserEntity user;
  final bool isMe;
  final double backgroundHeight;
  final double detailsOpacity;
  final VoidCallback onShare;
  final VoidCallback? onEditProfile;

  String _profileText(BuildContext context, String key) =>
      ReplicaStrings.fromTag(
        Localizations.localeOf(context).toLanguageTag(),
        key,
      );

  @override
  Widget build(BuildContext context) {
    // Compact vertical identity: avatar then name/stats/action on the
    // darkened bottom gradient of the artwork band. Both are translated
    // together by the delegate (expandedContentOffset), so their relative
    // positions cannot cross during a collapse.
    final topInset = MediaQuery.paddingOf(context).top;
    return Align(
      alignment: Alignment.center,
      child: Padding(
        // Keep the identity block clear of the status bar; the expanded
        // artwork band starts at the screen top (edge-to-edge).
        padding: EdgeInsets.fromLTRB(24, topInset + 12, 24, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            KeyedSubtree(
              key: const ValueKey('profile-expanded-avatar'),
              child: _Avatar(
                user: user,
                radius: ReplicaProfileHeaderGeometry.expandedAvatarRadius,
              ),
            ),
            const SizedBox(height: 14),
            IgnorePointer(
              ignoring: detailsOpacity < 0.99,
              child: Opacity(
                opacity: detailsOpacity,
                child: _ExpandedProfileDetails(
                  user: user,
                  isMe: isMe,
                  onShare: onShare,
                  onEditProfile: onEditProfile,
                  profileText: _profileText,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileBackground extends StatelessWidget {
  const _ProfileBackground({required this.user, this.withScrim = false});

  final UserEntity user;

  /// When true and the user has an artwork background, a bottom gradient
  /// keeps the identity text readable over any image.
  final bool withScrim;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // Placeholder uses the page surface (not a darker band). A
    // surfaceContainerHighest block under a background image only reached
    // part of the header, leaving an obvious grey band between the artwork
    // and the identity block on every profile.
    if (user.backgroundImageUrl == null) {
      return ColoredBox(color: colors.surface);
    }
    if (!withScrim) {
      return PixivImage.detail(
        user.backgroundImageUrl!,
        fit: BoxFit.cover,
        // Background images have widely varying aspect ratios; anchoring to
        // the top keeps the main subject visible when the header crops the
        // lower part of a tall image.
        alignment: Alignment.topCenter,
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        PixivImage.detail(
          user.backgroundImageUrl!,
          fit: BoxFit.cover,
          alignment: Alignment.topCenter,
        ),
        // Gradient low enough to keep the name/stat rows legible without
        // hiding the artwork around the avatar.
        IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: const [0.45, 1],
                colors: [
                  Colors.transparent,
                  colors.surface.withValues(alpha: 0.94),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ExpandedProfileDetails extends StatelessWidget {
  const _ExpandedProfileDetails({
    required this.user,
    required this.isMe,
    required this.onShare,
    required this.onEditProfile,
    required this.profileText,
  });

  final UserEntity user;
  final bool isMe;
  final VoidCallback onShare;
  final VoidCallback? onEditProfile;
  final String Function(BuildContext context, String key) profileText;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
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
                    key: const ValueKey('profile-expanded-name'),
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
                  tooltip: context.l10n.profileShare,
                  onPressed: onShare,
                  icon: const Icon(Icons.share_outlined),
                ),
              ),
            ],
          ),
        ),
        if (user.account.isNotEmpty)
          Text(user.account, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 7),
        Wrap(
          spacing: 16,
          alignment: WrapAlignment.center,
          children: [
            _Stat(icon: AppIcons.follow, label: '${user.totalFollowUsers}'),
            _Stat(icon: AppIcons.friend, label: '${user.totalMyPixivUsers}'),
            _Stat(icon: Icons.palette_outlined, label: '${user.totalIllusts}'),
          ],
        ),
        const SizedBox(height: 8),
        if (isMe)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (onEditProfile != null)
                IconButton(
                  tooltip: context.l10n.profileEditTitle,
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
    final actions = isMe && showRestrictSelector
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
            tooltip: _text(context, 'profileShare'),
            onPressed: onShare,
            icon: const Icon(Icons.share_outlined),
          );

    return Stack(
      children: [
        // The title is genuinely centred on the screen; leading/actions sit
        // on top, so asymmetric action counts no longer shift the name.
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 64),
            child: Text(
              key: const ValueKey('profile-toolbar-title'),
              user.name,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ),
        Positioned(
          left: 8,
          top: 0,
          bottom: 0,
          child: Center(
            child: canPop
                ? IconButton(
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).backButtonTooltip,
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.arrow_back_ios_new),
                  )
                : const SizedBox.shrink(),
          ),
        ),
        Positioned(right: 8, top: 0, bottom: 0, child: Center(child: actions)),
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
    return PersonAvatar(
      imageUrl: user.profileImageUrl,
      radius: radius,
      ring: true,
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
  double get maxExtent => kToolbarHeight + (expanded && _isWorkTab ? 64 : 0);

  bool get _isWorkTab => isMe ? controller.index == 4 : controller.index == 0;

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
    final isWorkTab = _isWorkTab;
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
