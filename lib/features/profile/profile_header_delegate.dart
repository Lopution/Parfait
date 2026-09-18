import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../app/icons/app_icons.dart';
import '../../app/navigation/routes.dart';
import '../../app/person_avatar.dart';
import '../../app/pixiv_image.dart';
import '../../core/profile/profile_models.dart';
import '../../core/user/user_entity.dart';
import '../../core/user/user_repository.dart';
import '../../app/widgets/follow_switch_button.dart';
import '../../l10n/context.dart';
import '../../l10n/lookup.dart';

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
  /// of the shrinking header. The toolbar begins fading in while the details
  /// fade out, so the header has one continuous hand-off instead of a blank
  /// second stage between the two states.
  static const expandedIdentityExitProgress = 0.78;
  static const expandedDetailsFadeStart = 0.55;

  /// A native flexible-space header scrolls its background content out of the
  /// pinned toolbar. Matching the header's scroll distance keeps the identity
  /// movement at one speed instead of producing a second apparent jump near
  /// the collapsed threshold.
  static const _expandedContentTravelFactor = 1.0;

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
      ((progress - expandedDetailsFadeStart) / (1 - expandedDetailsFadeStart))
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
    this.onOpenBookmarkTags,
    this.onDownloadAll,
    this.expandedExtent = 320,
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

  /// Own-profile bookmarks tab only: opens the bookmark-tag collection.
  final VoidCallback? onOpenBookmarkTags;

  /// Works tab only: bulk-downloads every illust/manga work of the author.
  final VoidCallback? onDownloadAll;
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
              // Pushed pages (other artists) need a visible back affordance
              // while the header is still expanded — the collapsed toolbar's
              // own back button only exists once fully collapsed. /me as a
              // branch root never reports canPop, so it stays clean.
              if (canPop && geometry.backgroundOpacity > 0)
                Positioned(
                  top: topInset + 4,
                  left: 8,
                  child: Opacity(
                    opacity: geometry.backgroundOpacity,
                    child: IconButton.filledTonal(
                      tooltip: MaterialLocalizations.of(
                        context,
                      ).backButtonTooltip,
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: const Icon(Icons.arrow_back_ios_new),
                    ),
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
                              onOpenBookmarkTags: onOpenBookmarkTags,
                              onDownloadAll: onDownloadAll,
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
        oldDelegate.onOpenBookmarkTags != onOpenBookmarkTags ||
        oldDelegate.onDownloadAll != onDownloadAll ||
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
      l10nLookup(context.l10n, key);

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
        // PixShaft-style flat dim: the whole band drops contrast so the
        // white identity text stays readable over any artwork — a
        // surface-tinted gradient only worked near the bottom edge and
        // let names collide with light artwork.
        const IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: [0.0, 0.5, 1.0],
                colors: [
                  Color(0x59000000),
                  Color(0x66000000),
                  Color(0x8C000000),
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
    // The identity block sits on the dimmed artwork band: white text/icons
    // like PixShaft's user page. Without an artwork background the band is
    // the plain page surface, so theme colours must stay.
    final onArtwork = user.backgroundImageUrl != null;
    final Color? textColor = onArtwork ? Colors.white : null;
    final Color? secondaryColor = onArtwork
        ? Colors.white.withValues(alpha: 0.85)
        : null;
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
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: textColor,
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
                  color: textColor,
                  icon: const Icon(Icons.share_outlined),
                ),
              ),
            ],
          ),
        ),
        if (user.account.isNotEmpty)
          Text(
            user.account,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: secondaryColor),
          ),
        const SizedBox(height: 7),
        Row(
          children: [
            _Stat(
              icon: AppIcons.follow,
              label: '${user.totalFollowUsers}',
              color: textColor,
            ),
            _Stat(
              icon: AppIcons.friend,
              label: '${user.totalMyPixivUsers}',
              color: textColor,
            ),
            _Stat(
              icon: Icons.palette_outlined,
              label: '${user.totalIllusts}',
              color: textColor,
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
                  tooltip: context.l10n.profileEditTitle,
                  onPressed: onEditProfile,
                  color: textColor,
                  icon: const Icon(Icons.edit_outlined),
                ),
              IconButton(
                tooltip: context.l10n.settingsTitle,
                onPressed: () => openSettings(context),
                color: textColor,
                icon: const Icon(Icons.settings_outlined),
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
    required this.onOpenBookmarkTags,
    required this.onDownloadAll,
  });

  final UserEntity user;
  final bool isMe;
  final bool canPop;
  final bool showRestrictSelector;
  final UserRestrict restrict;
  final ValueChanged<UserRestrict> onRestrictChanged;
  final VoidCallback onShare;
  final VoidCallback? onEditProfile;
  final VoidCallback? onOpenBookmarkTags;
  final VoidCallback? onDownloadAll;

  String _text(BuildContext context, String key) =>
      l10nLookup(context.l10n, key);

  @override
  Widget build(BuildContext context) {
    final settingsButton = IconButton(
      tooltip: context.l10n.settingsTitle,
      onPressed: () => openSettings(context),
      icon: const Icon(Icons.settings_outlined),
    );
    final downloadAllButton = onDownloadAll == null
        ? null
        : IconButton(
            tooltip: _text(context, 'downloadAuthorWorks'),
            onPressed: onDownloadAll,
            icon: const Icon(Icons.file_download_outlined),
          );
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
              if (onOpenBookmarkTags != null)
                IconButton(
                  tooltip: _text(context, 'bookmarkTags'),
                  onPressed: onOpenBookmarkTags,
                  icon: const Icon(Icons.label_outline),
                ),
              ?downloadAllButton,
              if (onEditProfile != null)
                IconButton(
                  tooltip: _text(context, 'profileEditTitle'),
                  onPressed: onEditProfile,
                  icon: const Icon(Icons.edit_outlined),
                ),
              settingsButton,
            ],
          )
        : isMe
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ?downloadAllButton,
              if (onEditProfile != null)
                IconButton(
                  tooltip: _text(context, 'profileEditTitle'),
                  onPressed: onEditProfile,
                  icon: const Icon(Icons.edit_outlined),
                ),
              settingsButton,
            ],
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ?downloadAllButton,
              IconButton(
                tooltip: _text(context, 'profileShare'),
                onPressed: onShare,
                icon: const Icon(Icons.share_outlined),
              ),
            ],
          );

    // Three-section toolbar: leading / title / actions. The title centres
    // inside whatever space the actions leave and ellipsizes there — the
    // old full-width-centred Stack overlapped the action row once it grew
    // past the hardcoded 64px side padding (5 icons ≈ 240px on /me).
    return Row(
      children: [
        const SizedBox(width: 4),
        SizedBox(
          width: 48,
          height: 48,
          child: canPop
              ? IconButton(
                  tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.arrow_back_ios_new),
                )
              : const SizedBox.shrink(),
        ),
        Expanded(
          child: Text(
            key: const ValueKey('profile-toolbar-title'),
            user.name,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        actions,
        const SizedBox(width: 4),
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
  const _Stat({required this.icon, required this.label, this.color});

  final IconData icon;
  final String label;

  /// White over the dimmed artwork band; null keeps the theme colour for
  /// the no-background variant.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(color: color)),
        ],
      ),
    );
  }
}

/// Pinned profile tab bar and the beta56 re-tap type selector.
class ReplicaProfileTabsDelegate extends SliverPersistentHeaderDelegate {
  ReplicaProfileTabsDelegate({
    required this.controller,
    required this.isMe,
    required this.expanded,
    required this.section,
    required this.onTabTap,
    required this.onSectionChanged,
  });

  final TabController controller;
  final bool isMe;
  final bool expanded;
  final ProfileWorkSection section;
  final ValueChanged<int> onTabTap;
  final ValueChanged<ProfileWorkSection> onSectionChanged;

  @override
  double get minExtent => kToolbarHeight;

  @override
  double get maxExtent => kToolbarHeight + (expanded && _isWorkTab ? 64 : 0);

  bool get _isWorkTab => isMe ? controller.index == 4 : controller.index == 0;

  String _text(BuildContext context, String key) =>
      l10nLookup(context.l10n, key);

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
            child: LayoutBuilder(
              builder: (context, constraints) {
                // Uniform label scale: all tabs share one font size, shrunk
                // until the widest translation fits its equal-width slot.
                // Same layout in every locale — longer languages just render
                // at a smaller size instead of crowding or truncating.
                const baseSize = 14.0;
                final slotWidth =
                    constraints.maxWidth / labels.length -
                    16; // labelPadding horizontal 8 x2
                var maxLabelWidth = 0.0;
                for (final key in labels) {
                  final painter = TextPainter(
                    text: TextSpan(
                      text: _text(context, key),
                      style: const TextStyle(
                        fontSize: baseSize,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    textDirection: Directionality.of(context),
                    maxLines: 1,
                    textScaler: MediaQuery.textScalerOf(context),
                  )..layout();
                  if (painter.width > maxLabelWidth) {
                    maxLabelWidth = painter.width;
                  }
                }
                final scale = slotWidth > 0 && maxLabelWidth > 0
                    ? (slotWidth / maxLabelWidth).clamp(0.55, 1.0)
                    : 1.0;
                final labelStyle = TextStyle(
                  fontSize: baseSize * scale,
                  fontWeight: FontWeight.w500,
                );
                return TabBar(
                  controller: controller,
                  // Profile tabs mirror the five-slot bottom navigation. Keep
                  // every tab in an equal-width slot; the shared scaled font
                  // keeps long translations inside the header without
                  // horizontal scrolling.
                  isScrollable: false,
                  indicatorSize: TabBarIndicatorSize.label,
                  labelPadding: const EdgeInsets.symmetric(horizontal: 8),
                  labelStyle: labelStyle,
                  unselectedLabelStyle: labelStyle,
                  onTap: onTabTap,
                  tabs: [
                    for (final label in labels)
                      Tab(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            _text(context, label),
                            maxLines: 1,
                            softWrap: false,
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
          if (expanded && isWorkTab)
            SizedBox(
              height: 64,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final type in ProfileWorkSection.values) ...[
                      if (type != ProfileWorkSection.illust)
                        const SizedBox(width: 8),
                      ChoiceChip(
                        label: Text(
                          _text(context, switch (type) {
                            ProfileWorkSection.illust => 'profileIllust',
                            ProfileWorkSection.manga => 'profileManga',
                            ProfileWorkSection.novel => 'profileNovel',
                            ProfileWorkSection.series => 'profileSeries',
                          }),
                        ),
                        selected: section == type,
                        onSelected: (_) => onSectionChanged(type),
                      ),
                    ],
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
      oldDelegate.section != section;
}
