import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/user/follow_actions.dart';
import '../../core/user/follow_models.dart';
import '../../core/user/follow_store.dart';
import '../haptics/app_haptics.dart';
import '../layout/app_breakpoints.dart';
import '../layout/content_widths.dart';
import '../motion/app_overlays.dart';
import '../theme/func_semantic_tokens.dart';
import '../theme/func_tokens.dart';
import 'errors/error_details.dart';
import '../../l10n/lookup.dart';
import '../../l10n/context.dart';
import 'fit_label.dart';
import 'undo_snack_bar.dart';

/// Toggles the follow of [userId]. The button flips on this frame
/// (optimistic) with a select haptic; a failure rolls it back with an error
/// haptic and the button reports the cause. A confirmed unfollow offers
/// Undo, which follows again with the old visibility.
Future<void> toggleFollowWithUndo(BuildContext context, int userId) async {
  // Read up front: the toggle may outlive the widget that started it.
  final container = ProviderScope.containerOf(context, listen: false);
  final store = container.read(followStoreProvider.notifier);
  AppHaptics.select();
  final removed = await container.read(followActionsProvider).toggle(userId);
  if (store.entryOf(userId)?.error != null) {
    AppHaptics.error();
    return;
  }
  if (removed != null && context.mounted) {
    showUndoSnackBar(
      context,
      context.l10n.followRemoved,
      onUndo: (container) => container
          .read(followActionsProvider)
          .addWithRestrict(removed.userId, removed.restrict),
    );
  }
}

/// Horizontal padding around the follow button's label.
const _labelPadding = FuncSpacing.md;

/// Shared beta56-style follow button for profile/user-preview surfaces.
///
/// It shows the user's wish at once ([FollowEntry.shown]); the canonical
/// [FollowStore] owns rollback and cross-page updates.
class FollowSwitchButton extends ConsumerWidget {
  const FollowSwitchButton({
    super.key,
    required this.userId,
    required this.userName,
    this.userAccount = '',
    this.compact = false,
  });

  final int userId;
  final String userName;
  final String userAccount;
  final bool compact;

  String _text(BuildContext context, String key) =>
      l10nLookup(context.l10n, key);

  Future<void> _showActionsSheet(BuildContext context, WidgetRef ref) async {
    AppHaptics.longPress();
    await showFollowActionsSheet(
      context,
      ref,
      userId: userId,
      userName: userName,
      userAccount: userAccount,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entry = ref.watch(
      followStoreProvider.select((state) => state[userId]),
    );
    final followed = entry?.shown ?? false;
    final unsettled = entry?.isUnsettled ?? false;
    final colors = Theme.of(context).colorScheme;
    final semanticLabel = _text(context, followed ? 'followed' : 'follow');
    ref.listen<Object?>(
      followStoreProvider.select((state) => state[userId]?.error),
      (previous, next) {
        if (next != null && previous != next) {
          showErrorSnackBar(
            context,
            action: _text(context, 'followFailed'),
            error: next,
          );
        }
      },
    );

    // Minimum size, not fixed: a long translation (e.g. ru at a large text
    // scale) widens the button instead of truncating the label. Slots that
    // still cannot fit the grown button bound it (e.g. a ListTile trailing
    // capped at half the row); only then does the label scale down, to
    // LabelFit.minScale, and past that ellipsize.
    final minSize = compact ? const Size(96, 36) : const Size(116, 42);
    // The sheet acts on a settled state only.
    final onLongPress = unsettled
        ? null
        : () => _showActionsSheet(context, ref);
    final labelStyle = Theme.of(
      context,
    ).textTheme.labelLarge!.copyWith(fontWeight: FontWeight.w600);
    return LayoutBuilder(
      builder: (context, constraints) => ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: minSize.width,
          minHeight: minSize.height,
        ),
        child: IntrinsicWidth(
          child: Semantics(
            container: true,
            button: true,
            toggled: followed,
            label: semanticLabel,
            onTap: () => toggleFollowWithUndo(context, userId),
            onLongPress: onLongPress,
            child: ExcludeSemantics(
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: followed
                      ? colors.onSurface
                      : colors.onPrimary,
                  backgroundColor: followed ? colors.surface : colors.primary,
                  side: BorderSide(
                    color: followed ? colors.onSurface : colors.primary,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: _labelPadding,
                  ),
                  textStyle: labelStyle,
                  minimumSize: minSize,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  // The long-press haptic is AppHaptics.longPress; the
                  // framework's own would double it (this also drops the tap
                  // click sound).
                  enableFeedback: false,
                ),
                onPressed: () => toggleFollowWithUndo(context, userId),
                onLongPress: onLongPress,
                // Drawn in the button's text style, measured in the same.
                child: FitLabel(
                  semanticLabel,
                  fit: LabelFit.group(
                    labels: [semanticLabel],
                    style: labelStyle,
                    textScaler: MediaQuery.textScalerOf(context),
                    textDirection: Directionality.of(context),
                    slotWidth: constraints.maxWidth - 2 * _labelPadding,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _FollowSheetAction { followPublic, followPrivate, unfollow }

/// The follow sheet of [FollowSwitchButton]'s long press and the profile
/// header: direct actions for the current state — follow publicly or
/// privately; once followed, switch the visibility or unfollow (with Undo).
Future<void> showFollowActionsSheet(
  BuildContext context,
  WidgetRef ref, {
  required int userId,
  required String userName,
  String userAccount = '',
}) async {
  final action = await showAppBottomSheet<_FollowSheetAction>(
    context: context,
    backgroundColor: FuncTokens.transparent,
    builder: (_) => _FollowActionsSheet(
      userId: userId,
      userName: userName,
      userAccount: userAccount,
    ),
  );
  if (action == null || !context.mounted) return;
  final store = ref.read(followStoreProvider.notifier);
  switch (action) {
    case _FollowSheetAction.unfollow:
      // The entry may have changed while the sheet was open; a toggle on
      // an unfollowed user would follow instead.
      if (store.entryOf(userId)?.shown ?? false) {
        await toggleFollowWithUndo(context, userId);
      }
    case _FollowSheetAction.followPublic || _FollowSheetAction.followPrivate:
      AppHaptics.select();
      await ref
          .read(followActionsProvider)
          .addWithRestrict(
            userId,
            action == _FollowSheetAction.followPrivate
                ? FollowRestrict.private
                : FollowRestrict.public,
          );
      if (store.entryOf(userId)?.error != null) AppHaptics.error();
  }
}

class _FollowActionsSheet extends ConsumerWidget {
  const _FollowActionsSheet({
    required this.userId,
    required this.userName,
    required this.userAccount,
  });

  static const _buttonSize = Size.fromHeight(kMinInteractiveDimension);

  final int userId;
  final String userName;
  final String userAccount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entry = ref.watch(
      followStoreProvider.select((state) => state[userId]),
    );
    final followed = entry?.shown ?? false;
    final restrict = entry?.restrict;
    final colors = Theme.of(context).colorScheme;
    final tokens = FuncSemanticTokens.of(context);
    final contentMaxWidth =
        MediaQuery.widthOf(context) >= AppBreakpoints.expanded
        ? ContentWidths.form
        : double.infinity;
    void pick(_FollowSheetAction action) => Navigator.of(context).pop(action);
    Widget outlined(String key, _FollowSheetAction action) => OutlinedButton(
      style: OutlinedButton.styleFrom(minimumSize: _buttonSize),
      onPressed: () => pick(action),
      child: Text(_followText(context, key)),
    );
    final actions = followed
        ? [
            // An unknown visibility offers both switches.
            if (restrict != FollowRestrict.private)
              outlined(
                'followSwitchToPrivate',
                _FollowSheetAction.followPrivate,
              ),
            if (restrict != FollowRestrict.public)
              outlined('followSwitchToPublic', _FollowSheetAction.followPublic),
            outlined('unfollow', _FollowSheetAction.unfollow),
          ]
        : [
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: _buttonSize),
              onPressed: () => pick(_FollowSheetAction.followPublic),
              child: Text(_followText(context, 'followPublicAction')),
            ),
            outlined('followPrivately', _FollowSheetAction.followPrivate),
          ];
    return Align(
      // Same cap as the bookmark edit sheet: form sheets center at
      // ContentWidths.form on expanded surfaces (parent §5.5).
      alignment: Alignment.topCenter,
      heightFactor: 1.0,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: contentMaxWidth),
        child: Container(
          padding: const EdgeInsets.fromLTRB(
            FuncSpacing.xl,
            FuncSpacing.lg,
            FuncSpacing.xl,
            FuncSpacing.xl,
          ),
          decoration: BoxDecoration(
            color: colors.surfaceContainer,
            borderRadius: FuncShape.sheet,
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                MergeSemantics(
                  child: Semantics(
                    header: true,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(userName, style: tokens.title),
                        if (userAccount.isNotEmpty)
                          Text(userAccount, style: tokens.caption),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: FuncSpacing.lg),
                for (final (index, action) in actions.indexed) ...[
                  if (index > 0) const SizedBox(height: FuncSpacing.sm),
                  action,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _followText(BuildContext context, String key) =>
    l10nLookup(context.l10n, key);
