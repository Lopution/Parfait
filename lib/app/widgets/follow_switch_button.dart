import 'package:cupertino_ui/cupertino_ui.dart';
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
import 'app_segmented_button.dart';
import 'fit_label.dart';
import 'undo_snack_bar.dart';

/// Toggles the follow of [userId] and plays the haptic of the settled
/// outcome: select when the change lands either way, error on failure. A
/// queued (offline) or cancelled toggle stays silent — its replay lands
/// out of context. An unfollow offers Undo, which follows again with the
/// old visibility.
Future<void> toggleFollowWithUndo(BuildContext context, int userId) async {
  // Read up front: the toggle may outlive the widget that started it.
  final container = ProviderScope.containerOf(context, listen: false);
  final store = container.read(followStoreProvider.notifier);
  final before = store.entryOf(userId)?.followed ?? false;
  final removed = await container.read(followActionsProvider).toggle(userId);
  _playFollowOutcome(store.entryOf(userId), before: before);
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

void _playFollowOutcome(FollowEntry? after, {required bool? before}) {
  if (after == null || after.isPending) return;
  if (after.error != null) {
    AppHaptics.error();
  } else if (before == null || after.followed != before) {
    AppHaptics.select();
  }
}

/// Shared beta56-style follow button for profile/user-preview surfaces.
///
/// The confirmed icon/text is deliberately unchanged while the request is in
/// flight. The canonical [FollowStore] owns rollback and cross-page updates.
/// Horizontal padding around the follow button's label.
const _labelPadding = FuncSpacing.md;

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

  Future<void> _showRestrictSheet(BuildContext context, WidgetRef ref) async {
    AppHaptics.longPress();
    await showFollowRestrictSheet(
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
    final followed = entry?.followed ?? false;
    final pending = entry?.isPending ?? false;
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
    if (pending) {
      // The spinner stays at the minimum size instead of tracking the
      // label's width, so entering the pending state never wobbles.
      return SizedBox.fromSize(
        size: minSize,
        child: Semantics(
          container: true,
          button: true,
          enabled: false,
          label: semanticLabel,
          liveRegion: true,
          child: const Center(child: CupertinoActivityIndicator()),
        ),
      );
    }
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
            onLongPress: followed
                ? null
                : () => _showRestrictSheet(context, ref),
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
                onLongPress: followed
                    ? null
                    : () => _showRestrictSheet(context, ref),
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

/// Opens the same public/private follow sheet used by [FollowSwitchButton].
/// Profile header overflow actions use this entry point so a compact toolbar
/// does not grow a second follow restriction implementation.
Future<void> showFollowRestrictSheet(
  BuildContext context,
  WidgetRef ref, {
  required int userId,
  required String userName,
  String userAccount = '',
}) async {
  var restrict = FollowRestrict.public;
  final selected = await showAppBottomSheet<FollowRestrict>(
    context: context,
    backgroundColor: FuncTokens.transparent,
    builder: (sheetContext) => StatefulBuilder(
      builder: (sheetContext, setState) {
        final colors = Theme.of(sheetContext).colorScheme;
        final contentMaxWidth =
            MediaQuery.widthOf(sheetContext) >= AppBreakpoints.expanded
            ? ContentWidths.form
            : double.infinity;
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
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _followText(sheetContext, 'followUser'),
                      style: Theme.of(sheetContext).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: FuncSpacing.sm),
                    Text(
                      userName,
                      style: FuncSemanticTokens.of(sheetContext).title,
                    ),
                    if (userAccount.isNotEmpty)
                      Text(
                        userAccount,
                        style: FuncSemanticTokens.of(sheetContext).caption,
                      ),
                    const SizedBox(height: FuncSpacing.lg),
                    AppSegmentedButton<FollowRestrict>(
                      segments: [
                        AppSegment(
                          value: FollowRestrict.public,
                          label: _followText(sheetContext, 'restrictPublic'),
                        ),
                        AppSegment(
                          value: FollowRestrict.private,
                          label: _followText(sheetContext, 'restrictPrivate'),
                        ),
                      ],
                      selected: restrict,
                      onSelected: (value) => setState(() => restrict = value),
                    ),
                    const SizedBox(height: FuncSpacing.lg),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => Navigator.of(sheetContext).pop(),
                            child: Text(_followText(sheetContext, 'cancel')),
                          ),
                        ),
                        const SizedBox(width: FuncSpacing.md),
                        Expanded(
                          child: FilledButton(
                            onPressed: () =>
                                Navigator.of(sheetContext).pop(restrict),
                            child: Text(_followText(sheetContext, 'confirm')),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
  if (selected != null && context.mounted) {
    final store = ref.read(followStoreProvider.notifier);
    await ref.read(followActionsProvider).addWithRestrict(userId, selected);
    // A restrict change on an existing follow lands without flipping it,
    // so any settled success counts.
    _playFollowOutcome(store.entryOf(userId), before: null);
  }
}

String _followText(BuildContext context, String key) =>
    l10nLookup(context.l10n, key);
