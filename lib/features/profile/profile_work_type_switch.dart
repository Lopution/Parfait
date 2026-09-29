import 'package:material_ui/material_ui.dart';

import '../../app/widgets/app_type_switch.dart';
import '../../core/profile/profile_models.dart';
import '../../l10n/context.dart';

/// The work tab's section selector, handed to whichever feed is showing so
/// it floats with that feed's list (Compact Type Switch Contract).
///
/// The profile page keeps one selection ([selected]) and one callback for
/// every work feed; each feed renders this through [sliver] once its data
/// arrives, or through [aboveState] while the feed is still loading,
/// errored, or empty so the selector stays reachable.
@immutable
class ProfileWorkTypeSwitch {
  const ProfileWorkTypeSwitch({
    required this.selected,
    required this.onSelected,
  });

  final ProfileWorkSection selected;

  /// Called with the tapped section — including the current one, which the
  /// page treats as a re-tap (scroll to top).
  final ValueChanged<ProfileWorkSection> onSelected;

  List<({ProfileWorkSection value, String label})> _options(
    BuildContext context,
  ) => [
    (value: ProfileWorkSection.illust, label: context.l10n.profileIllust),
    (value: ProfileWorkSection.manga, label: context.l10n.profileManga),
    (value: ProfileWorkSection.novel, label: context.l10n.profileNovel),
    (value: ProfileWorkSection.series, label: context.l10n.profileSeries),
  ];

  /// Floating row for a loaded feed's sliver list: it scrolls away with the
  /// content and floats back in on an upward drag. It must come right after
  /// `HeaderLocator.sliver()`, which keeps the Shared Pull-to-Refresh
  /// `isNested` contract.
  Widget sliver(BuildContext context) =>
      SliverAppTypeSwitch<ProfileWorkSection>(
        options: _options(context),
        selected: selected,
        onSelected: onSelected,
      );

  /// Fixed row above a loading/error/empty state — the selector sits at the
  /// same spot the floating version occupies once data arrives, so nothing
  /// jumps on load.
  Widget aboveState(BuildContext context, Widget state) => Column(
    children: [
      AppTypeSwitch<ProfileWorkSection>(
        options: _options(context),
        selected: selected,
        onSelected: onSelected,
      ),
      Expanded(child: state),
    ],
  );
}
