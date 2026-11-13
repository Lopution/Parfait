part of 'user_page.dart';

/// Hands the NestedScrollView's inner controller to the selected tab only.
///
/// Every tab stays alive, and each one's feed would otherwise attach to
/// that one controller. The coordinator then drives all attached positions
/// as one: a fling on About (always at 0) was computed against a sibling
/// scrolled thousands of pixels down and died at the header, and a drag
/// moved the hidden tabs along. An unselected tab parks its feed on a
/// [_ParkedScrollController]; the position carries its offset across both
/// hand-offs.
class _SelectedTabScroll extends StatefulWidget {
  const _SelectedTabScroll({required this.selected, required this.child});

  final bool selected;
  final Widget child;

  @override
  State<_SelectedTabScroll> createState() => _SelectedTabScrollState();
}

class _SelectedTabScrollState extends State<_SelectedTabScroll> {
  _ParkedScrollController? _parked;

  @override
  void dispose() {
    _parked?.dispose();
    super.dispose();
  }

  // Always a full PrimaryScrollController, never `.none`: a feed that did
  // not inherit one registers no dependency and would miss the hand-back.
  @override
  Widget build(BuildContext context) {
    final nested = PrimaryScrollController.of(context);
    final parked = (_parked ??= _ParkedScrollController(nested))
      ..nested = nested;
    return PrimaryScrollController(
      controller: widget.selected ? nested : parked,
      // As NestedScrollView's own: the feed inherits it on every platform.
      automaticallyInheritForPlatforms: TargetPlatform.values.toSet(),
      child: widget.child,
    );
  }
}

/// Holds an unselected tab's feed off the nested coordinator, which drives
/// only the positions attached to its own inner controller. The positions
/// are still made by that controller: on a controller change, Scrollable
/// attaches its current position to the new controller before replacing
/// it, and the nested controller accepts no other kind.
class _ParkedScrollController extends ScrollController {
  _ParkedScrollController(this.nested);

  ScrollController nested;

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => nested.createScrollPosition(physics, context, oldPosition);
}

class _ProfileTabBody extends ConsumerStatefulWidget {
  const _ProfileTabBody({
    super.key,
    required this.user,
    required this.userId,
    required this.isSeries,
    required this.feedKey,
    this.header,
    required this.statistics,
  });

  final UserEntity user;
  final int userId;

  /// The series tab lists series from its own endpoint; its [feedKey]'s
  /// wire work type is unused.
  final bool isSeries;
  final ProfileFeedKey? feedKey;

  /// Fixed above the feed: the own profile's list filters, or a work
  /// list's total.
  final Widget? header;
  final List<ProfileStatisticData> statistics;

  @override
  ConsumerState<_ProfileTabBody> createState() => _ProfileTabBodyState();
}

class _ProfileTabBodyState extends ConsumerState<_ProfileTabBody>
    with AutomaticKeepAliveClientMixin<_ProfileTabBody> {
  @override
  bool get wantKeepAlive => true;

  void scrollToTop(Duration Function(Duration base) resolve) {
    // Driving the feed's own position with a local activity rewinds only
    // this list; the header stays where it is.
    final scrollable = _tabScrollable();
    final position = scrollable?.position;
    if (scrollable == null || position == null || !position.hasPixels) {
      return;
    }
    _UserPageState._drivePositionToTop(scrollable.vsync, position, resolve);
  }

  /// The feed's own scroll view — the first Scrollable below this tab
  /// body.
  ScrollableState? _tabScrollable() {
    ScrollableState? found;
    void visit(Element element) {
      if (found != null) return;
      if (element is StatefulElement && element.state is ScrollableState) {
        found = element.state as ScrollableState;
        return;
      }
      element.visitChildElements(visit);
    }

    context.visitChildElements(visit);
    return found;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final feed = _buildFeed();
    final header = widget.header;
    if (header == null) return feed;
    final column = Column(
      children: [
        header,
        Expanded(child: feed),
      ],
    );
    // The body is only as tall as what the expanded header leaves, a strip
    // on a short window: lay the tab out at a usable height and clip it
    // rather than crush the filter row. The tree is the same at any height
    // so the feed keeps its state as the header collapses.
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = math.max(constraints.maxHeight, _minTabBodyHeight);
        return ClipRect(
          child: OverflowBox(
            alignment: Alignment.topCenter,
            minHeight: height,
            maxHeight: height,
            child: column,
          ),
        );
      },
    );
  }

  Widget _buildFeed() {
    final feedKey = widget.feedKey;
    if (feedKey == null) {
      return ProfileAboutTab(user: widget.user, statistics: widget.statistics);
    }
    if (widget.isSeries) return UserSeriesFeed(userId: widget.userId);
    if (feedKey.workType == UserWorkType.novel) {
      // TabController.indexIsChanging is false during a drag gesture. Keep
      // the page mounted for both tap and swipe transitions so the destination
      // never becomes a zero-size blank child mid-flight.
      return ProfileNovelFeed(feedKey: feedKey);
    }
    if (feedKey.kind == ProfileFeedKind.following ||
        feedKey.kind == ProfileFeedKind.fans ||
        feedKey.kind == ProfileFeedKind.myPixiv) {
      return ProfileUserFeed(feedKey: feedKey);
    }
    return ProfileIllustFeed(feedKey: feedKey);
  }
}

/// A work list's total, fixed above the list like the filters on your
/// own bookmarks.
class _WorksTotal extends StatelessWidget {
  const _WorksTotal({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        FuncSpacing.lg,
        FuncSpacing.sm,
        FuncSpacing.lg,
        0,
      ),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: Text(
          context.l10n.profileWorksTotal(AppFormat.count(context, count)),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// Shortest a profile tab is laid out: the filter row plus a row of the
/// feed.
const double _minTabBodyHeight = 160;
