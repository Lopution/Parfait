import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import '../../app/person_avatar.dart';
import '../../app/pixiv_image.dart';
import '../../app/system_ui.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../core/user/user_entity.dart';
import '../../app/widgets/app_menu_button.dart';
import '../../app/widgets/app_tab_bar.dart';
import '../../app/widgets/app_top_bar.dart';
import '../../app/widgets/follow_switch_button.dart';
import '../../app/widgets/image_overlay_button.dart';
import '../../l10n/context.dart';
import 'profile_statistics.dart';

/// Pure geometry snapshot used by [ReplicaProfileHeaderDelegate] and tests.
@immutable
class ReplicaProfileHeaderGeometry {
  const ReplicaProfileHeaderGeometry({
    required this.shrinkOffset,
    required this.minExtent,
    required this.maxExtent,
  });

  /// Banner height left visible below the toolbar at full expansion. The
  /// banner's total height is `topInset + kToolbarHeight + 80`, i.e. a
  /// 136dp band excluding the status-bar inset (D1's "about 135dp").
  static const bannerBelowToolbar = 80.0;

  /// 80dp avatar centred on the banner's bottom edge.
  static const avatarRadius = 40.0;

  /// The toolbar background finishes fading in as the banner's bottom edge
  /// approaches the toolbar's bottom edge over this distance.
  static const toolbarFadeDistance = FuncSpacing.xl;

  /// First-frame estimate used until the identity block reports its real
  /// height; the header stays transparent for that frame only.
  static const initialExtentEstimate = 360.0;

  final double shrinkOffset;
  final double minExtent;
  final double maxExtent;

  double get collapseRange => math.max(0, maxExtent - minExtent);

  double get progress =>
      collapseRange == 0 ? 1 : (shrinkOffset / collapseRange).clamp(0.0, 1.0);

  bool get isFullyCollapsed => shrinkOffset >= collapseRange - 0.5;

  /// Vertical translation applied to the banner and the identity block —
  /// both scroll out of the header with the content.
  double get contentOffset => -shrinkOffset;

  /// 0 while the banner still fills the toolbar, 1 once its bottom edge has
  /// scrolled past; fades over [toolbarFadeDistance] before that.
  double get toolbarOpacity =>
      ((shrinkOffset - (bannerBelowToolbar - toolbarFadeDistance)) /
              toolbarFadeDistance)
          .clamp(0.0, 1.0);

  /// While true, the banner is still painted behind the toolbar: the back
  /// and overflow controls take the image-overlay style and the status bar
  /// asks for light icons over the artwork.
  bool get bannerBehindToolbar => toolbarOpacity < 0.5;
}

/// Project-owned profile header. It avoids the old extended_sliver delegate.
///
/// The expanded profile follows the [SliverAppBar] separation: artwork and identity content live in the flexible area,
/// while the pinned toolbar has its own controls. The avatar therefore scrolls
/// out with the name instead of travelling into the toolbar.
class ReplicaProfileHeaderDelegate extends SliverPersistentHeaderDelegate {
  ReplicaProfileHeaderDelegate({
    required this.user,
    required this.isMe,
    required this.selectedTabIndex,
    required this.onShare,
    this.stats = const [],
    this.isFollowed = false,
    this.onEditProfile,
    this.onToggleFollow,
    this.onFollowPrivately,
    this.onCopyLink,
    this.onDownloadAll,
    required this.onExpandedExtentMeasured,
    this.expandedExtent,
    this.topInset = 0,
  });

  final UserEntity user;
  final bool isMe;
  final int selectedTabIndex;
  final ValueChanged<BuildContext> onShare;

  /// The statistics line under the name: following and My Pixiv.
  final List<ProfileHeaderStat> stats;
  final bool isFollowed;
  final VoidCallback? onEditProfile;
  final VoidCallback? onToggleFollow;
  final VoidCallback? onFollowPrivately;
  final VoidCallback? onCopyLink;

  /// Works tab only: bulk-downloads every illust/manga work of the author.
  final VoidCallback? onDownloadAll;

  /// Measured expanded height (identity block + banner). Null until the
  /// first layout reports it; the header renders one transparent estimate
  /// frame before that.
  final double? expandedExtent;

  /// Reports the identity block's natural height after each layout, so the
  /// caller can update [expandedExtent] when content (fonts, language,
  /// stats) changes.
  final ValueChanged<double> onExpandedExtentMeasured;
  final double topInset;

  @override
  double get minExtent => kToolbarHeight + topInset;

  @override
  double get maxExtent => math.max(
    expandedExtent ?? ReplicaProfileHeaderGeometry.initialExtentEstimate,
    minExtent,
  );

  List<_ProfileHeaderAction> _actions(BuildContext context) => [
    _ProfileHeaderAction(
      value: 'share',
      label: context.l10n.profileShare,
      icon: Icons.share_outlined,
      primary: true,
      onSelected: onShare,
      buildInline: (context) => Builder(
        builder: (buttonContext) => IconButton(
          tooltip: context.l10n.profileShare,
          onPressed: () => onShare(buttonContext),
          icon: const Icon(Icons.share_outlined),
        ),
      ),
    ),
    if (isMe && onEditProfile != null)
      _ProfileHeaderAction(
        value: 'editProfile',
        label: context.l10n.profileEditTitle,
        icon: Icons.edit_outlined,
        primary: true,
        onSelected: (_) => onEditProfile!(),
        // Text sits on the page surface now, so the neutral tonal style is
        // enough — no filled pink or on-artwork white variant.
        buildInline: (context) => FilledButton.tonal(
          onPressed: onEditProfile,
          child: Text(context.l10n.profileEditTitle),
        ),
      ),
    if (!isMe && onToggleFollow != null)
      _ProfileHeaderAction(
        value: 'toggleFollow',
        label: isFollowed ? context.l10n.unfollow : context.l10n.follow,
        icon: Icons.person_add_alt_1_outlined,
        primary: true,
        onSelected: (_) => onToggleFollow!(),
        buildInline: (_) => FollowSwitchButton(
          userId: user.id,
          userName: user.name,
          userAccount: user.account,
        ),
      ),
    if (!isMe && !isFollowed && onFollowPrivately != null)
      _ProfileHeaderAction(
        value: 'followPrivately',
        label: context.l10n.followPrivately,
        icon: Icons.lock_outline,
        onSelected: (_) => onFollowPrivately!(),
      ),
    if (onDownloadAll != null)
      _ProfileHeaderAction(
        value: 'downloadAll',
        label: context.l10n.downloadAuthorWorks,
        icon: Icons.download_outlined,
        onSelected: (_) => onDownloadAll!(),
      ),
    if (onCopyLink != null)
      _ProfileHeaderAction(
        value: 'copyLink',
        label: context.l10n.copyLink,
        icon: Icons.copy_outlined,
        onSelected: (_) => onCopyLink!(),
      ),
  ];

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
    final actions = _actions(context);
    final hasCover = user.backgroundImageUrl != null;
    final bannerHeight =
        topInset +
        kToolbarHeight +
        ReplicaProfileHeaderGeometry.bannerBelowToolbar;
    // Layered header, bottom to top: banner → identity (clipped below the
    // toolbar) → fading toolbar surface → collapsed title → persistent
    // back/overflow controls.
    // The overlay affordance and the cover-scoped status bar share one
    // predicate (R4/R6): only while real artwork still sits behind the
    // toolbar do the persistent controls get the image-overlay style and
    // the status bar light icons. A cover-less surfaceContainerHigh band
    // and the collapsed toolbar both take the normal surface treatment.
    final overArtwork = hasCover && geometry.bannerBehindToolbar;
    return FuncSystemBars(
      background: overArtwork ? Brightness.dark : Theme.of(context).brightness,
      child: Opacity(
        // First frame only: the delegate still holds the estimate extent
        // while the real identity height is being measured.
        opacity: expandedExtent == null ? 0 : 1,
        child: Material(
          color: colors.surface,
          child: LayoutBuilder(
            builder: (context, constraints) {
              return Stack(
                fit: StackFit.expand,
                clipBehavior: Clip.hardEdge,
                children: [
                  // 1. Banner band: cover image, or a surfaceContainerHigh
                  // strip so the header separates from the page colour.
                  Positioned(
                    top: geometry.contentOffset,
                    left: 0,
                    right: 0,
                    height: bannerHeight,
                    child: _ProfileBackground(user: user),
                  ),
                  // 2. Identity block at natural height, clipped below the
                  // toolbar's bottom edge so avatar and text never enter
                  // the toolbar. Stays mounted (Offstage) when collapsed so
                  // the measurement keeps reporting.
                  Positioned(
                    top: minExtent,
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: ClipRect(
                      child: OverflowBox(
                        minHeight: 0,
                        maxHeight: double.infinity,
                        alignment: Alignment.topCenter,
                        child: Transform.translate(
                          offset: Offset(0, geometry.contentOffset - minExtent),
                          child: Offstage(
                            offstage: geometry.isFullyCollapsed,
                            child: _ReportSize(
                              onSize: (size) =>
                                  onExpandedExtentMeasured(size.height),
                              child: _ExpandedIdentity(
                                user: user,
                                bannerHeight: bannerHeight,
                                actions: actions,
                                stats: stats,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  // 3. Toolbar surface fading in as the banner leaves.
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    height: minExtent,
                    child: IgnorePointer(
                      child: Opacity(
                        opacity: geometry.toolbarOpacity,
                        child: ColoredBox(color: colors.surface),
                      ),
                    ),
                  ),
                  // 4. Collapsed toolbar title mounts only at full collapse.
                  if (geometry.isFullyCollapsed)
                    Align(
                      alignment: Alignment.topCenter,
                      child: SizedBox(
                        // The status-bar inset belongs above the actual
                        // 56dp toolbar controls. This keeps pinned chrome
                        // out of the system UI on targetSdk 36
                        // edge-to-edge devices.
                        height: minExtent,
                        child: Padding(
                          padding: EdgeInsets.only(top: topInset),
                          child: SizedBox(
                            height: kToolbarHeight,
                            child: _CollapsedProfile(user: user),
                          ),
                        ),
                      ),
                    ),
                  // 5. Persistent controls: mounted and tappable through
                  // the whole collapse interval. They switch to the
                  // image-overlay affordance only while real artwork still
                  // sits behind them (`overArtwork`).
                  Positioned(
                    top: topInset + 4,
                    right: 8,
                    child: _ProfileHeaderMoreButton(
                      actions: actions,
                      includePrimary: true,
                      overArtwork: overArtwork,
                    ),
                  ),
                  // One persistent back button for both header states —
                  // stays mounted through the pop animation instead of
                  // being unmounted by a canPop flip (P3/P4).
                  Positioned(
                    top: topInset + 4,
                    left: 8,
                    child: _HeaderBackButton(overArtwork: overArtwork),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant ReplicaProfileHeaderDelegate oldDelegate) {
    return oldDelegate.user != user ||
        oldDelegate.isMe != isMe ||
        oldDelegate.selectedTabIndex != selectedTabIndex ||
        oldDelegate.onEditProfile != onEditProfile ||
        oldDelegate.isFollowed != isFollowed ||
        oldDelegate.onToggleFollow != onToggleFollow ||
        oldDelegate.onFollowPrivately != onFollowPrivately ||
        oldDelegate.onCopyLink != onCopyLink ||
        oldDelegate.onDownloadAll != onDownloadAll ||
        oldDelegate.onShare != onShare ||
        !listEquals(oldDelegate.stats, stats) ||
        oldDelegate.expandedExtent != expandedExtent ||
        oldDelegate.onExpandedExtentMeasured != onExpandedExtentMeasured ||
        oldDelegate.topInset != topInset;
  }
}

/// Banner artwork band. No scrim and no over-artwork text: the identity
/// content sits on the page surface below the banner, so nothing readable
/// is painted over the image and the overlay controls carry their own
/// filled background.
class _ProfileBackground extends StatelessWidget {
  const _ProfileBackground({required this.user});

  final UserEntity user;

  @override
  Widget build(BuildContext context) {
    if (user.backgroundImageUrl == null) {
      // No cover uploaded: a lighter opaque container separates the banner
      // from the page colour and still hides the feed items scrolling
      // underneath (the tab strip below is opaque, so that seam is covered
      // too).
      return ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
      );
    }
    return PixivImage.detail(
      user.backgroundImageUrl!,
      fit: BoxFit.cover,
      // Background images have widely varying aspect ratios; anchoring to
      // the top keeps the main subject visible when the header crops the
      // lower part of a tall image.
      alignment: Alignment.topCenter,
    );
  }
}

/// Everything below the toolbar while expanded, laid out at natural
/// height: a banner spacer (the banner itself is painted by the layered
/// header), the overlapping 80dp avatar, the name row — name and @account
/// on the left, share and the main action on the right — and the
/// statistics line. The measured height of this widget drives
/// [ReplicaProfileHeaderDelegate.expandedExtent].
class _ExpandedIdentity extends StatelessWidget {
  const _ExpandedIdentity({
    required this.user,
    required this.bannerHeight,
    required this.actions,
    required this.stats,
  });

  /// The main action never takes more than this share of the name row; a
  /// long name ellipsizes first, and the button's own label fitting
  /// handles anything wider.
  static const mainActionMaxShare = 0.45;

  final UserEntity user;
  final double bannerHeight;
  final List<_ProfileHeaderAction> actions;
  final List<ProfileHeaderStat> stats;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    _ProfileHeaderAction? share;
    _ProfileHeaderAction? main;
    for (final action in actions) {
      if (action.value == 'share') {
        share = action;
      } else if (action.primary && action.buildInline != null) {
        main ??= action;
      }
    }
    const avatarRadius = ReplicaProfileHeaderGeometry.avatarRadius;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(height: bannerHeight),
            // The avatar's lower half.
            const SizedBox(height: avatarRadius + FuncSpacing.sm),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: FuncSpacing.lg),
              child: LayoutBuilder(
                builder: (context, constraints) => Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            key: const ValueKey('profile-expanded-name'),
                            user.name,
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (user.account.isNotEmpty)
                            Text(
                              '@${user.account}',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ),
                    ),
                    if (share?.buildInline != null)
                      share!.buildInline!(context),
                    if (main?.buildInline != null)
                      Padding(
                        padding: const EdgeInsetsDirectional.only(
                          start: FuncSpacing.xs,
                        ),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: constraints.maxWidth * mainActionMaxShare,
                          ),
                          child: main!.buildInline!(context),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (stats.isNotEmpty)
              Padding(
                // The links carry their own xs inset; line their text up
                // with the name.
                padding: const EdgeInsets.symmetric(
                  horizontal: FuncSpacing.lg - FuncSpacing.xs,
                ),
                child: ProfileStatLine(stats: stats),
              ),
            const SizedBox(height: FuncSpacing.sm),
          ],
        ),
        // 80dp avatar centred on the banner's bottom edge, left-aligned.
        PositionedDirectional(
          start: FuncSpacing.lg,
          top: bannerHeight - avatarRadius,
          child: KeyedSubtree(
            key: const ValueKey('profile-expanded-avatar'),
            child: _Avatar(user: user, radius: avatarRadius),
          ),
        ),
      ],
    );
  }
}

/// Reports its laid-out size after every frame so the delegate's
/// [expandedExtent] tracks real content height (R1) instead of a
/// hard-coded value.
class _ReportSize extends SingleChildRenderObjectWidget {
  const _ReportSize({required this.onSize, required super.child});

  final ValueChanged<Size> onSize;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderReportSize(onSize);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderReportSize renderObject,
  ) {
    renderObject.onSize = onSize;
  }
}

class _RenderReportSize extends RenderProxyBox {
  _RenderReportSize(this.onSize);

  ValueChanged<Size> onSize;

  @override
  void performLayout() {
    super.performLayout();
    // A size change must not mark anything dirty during layout; the
    // delegate field is updated from the post-frame callback instead.
    final reported = size;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      onSize(reported);
    });
  }
}

@immutable
class _ProfileHeaderAction {
  const _ProfileHeaderAction({
    required this.value,
    required this.label,
    required this.icon,
    required this.onSelected,
    this.primary = false,
    this.buildInline,
  });

  final String value;
  final String label;
  final IconData icon;
  final ValueChanged<BuildContext> onSelected;
  final bool primary;
  final WidgetBuilder? buildInline;
}

class _ProfileHeaderMoreButton extends StatelessWidget {
  const _ProfileHeaderMoreButton({
    required this.actions,
    this.includePrimary = false,
    this.overArtwork = false,
  });

  final List<_ProfileHeaderAction> actions;
  final bool includePrimary;

  /// While artwork sits behind the control it carries the shared
  /// [ImageOverlayButton] palette — a fixed 55% black fill keeps the
  /// glyph legible over any image. On the normal surface there is no
  /// fill at all.
  final bool overArtwork;

  @override
  Widget build(BuildContext context) {
    final entries = actions
        .where((action) => includePrimary || !action.primary)
        .toList();
    if (entries.isEmpty) return const SizedBox.shrink();
    return AppMenuButton<_ProfileHeaderAction>(
      // AppMenuButton builds its own IconButton, so it cannot wrap an
      // ImageOverlayButton — the shared style keeps the affordance
      // identical instead of duplicating the token list.
      style: overArtwork ? ImageOverlayButton.buttonStyle() : null,
      onSelected: (anchorContext, action) => action.onSelected(anchorContext),
      entries: [
        for (final action in entries)
          AppMenuEntry(value: action, icon: action.icon, label: action.label),
      ],
    );
  }
}

class _CollapsedProfile extends StatelessWidget {
  const _CollapsedProfile({required this.user});

  final UserEntity user;

  @override
  Widget build(BuildContext context) {
    // Three-section toolbar: leading spacer / centred title / trailing
    // spacer. The persistent back and overflow buttons overlay the two
    // 48px slots, so both ends reserve identical 56px chrome and the
    // title stays centred on screen.
    return Row(
      children: [
        const SizedBox(width: FuncSpacing.sm),
        const SizedBox(width: 48, height: 48),
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
        const SizedBox(width: 48, height: 48),
        const SizedBox(width: FuncSpacing.sm),
      ],
    );
  }
}

/// The profile header's single back affordance. [Navigator.canPop] flips
/// false the moment [Route.pop] removes the route from history — before
/// the pop animation finishes — which would unmount the button mid-slide
/// and leave it out of the pop snapshot. The first evaluation is latched:
/// a pushed page keeps its button until the route is gone.
class _HeaderBackButton extends StatefulWidget {
  const _HeaderBackButton({this.overArtwork = false});

  /// While artwork sits behind the button it takes the shared
  /// [ImageOverlayButton] style; on the normal surface it is a plain
  /// toolbar icon with no fill (R4).
  final bool overArtwork;

  @override
  State<_HeaderBackButton> createState() => _HeaderBackButtonState();
}

class _HeaderBackButtonState extends State<_HeaderBackButton> {
  var _canPop = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_canPop) _canPop = Navigator.of(context).canPop();
  }

  @override
  Widget build(BuildContext context) {
    if (!_canPop) return const SizedBox.shrink();
    final tooltip = MaterialLocalizations.of(context).backButtonTooltip;
    const icon = Icon(Icons.arrow_back_ios_new);
    void pop() => Navigator.of(context).maybePop();
    if (widget.overArtwork) {
      return ImageOverlayButton(icon: icon, tooltip: tooltip, onPressed: pop);
    }
    return IconButton(tooltip: tooltip, onPressed: pop, icon: icon);
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

/// Pinned profile tab bar, a constant 56dp: one tab per work type the user
/// has (with its count), then the profile's other tabs.
class ReplicaProfileTabsDelegate extends SliverPersistentHeaderDelegate {
  ReplicaProfileTabsDelegate({
    required this.controller,
    required this.labels,
    required this.onTabTap,
    this.scrolled = false,
  });

  final TabController controller;
  final List<String> labels;
  final ValueChanged<int> onTabTap;

  /// Whether a tab's content has scrolled under the strip. The strip is
  /// the page's top edge then, and shows the top bar's edge line.
  final bool scrolled;

  @override
  double get minExtent => kToolbarHeight;

  @override
  double get maxExtent => minExtent;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return Material(
      key: const ValueKey('profile-tabs'),
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SizedBox(
        height: kToolbarHeight,
        child: Stack(
          fit: StackFit.expand,
          children: [
            AppTabBar(controller: controller, onTap: onTabTap, labels: labels),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: ScrollEdgeLine(visible: scrolled),
            ),
          ],
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant ReplicaProfileTabsDelegate oldDelegate) =>
      oldDelegate.controller != controller ||
      !listEquals(oldDelegate.labels, labels) ||
      oldDelegate.onTabTap != onTabTap ||
      oldDelegate.scrolled != scrolled;
}
