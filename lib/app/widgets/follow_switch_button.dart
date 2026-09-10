import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/user/follow_actions.dart';
import '../../core/user/follow_models.dart';
import '../../core/user/follow_store.dart';
import '../theme/func_tokens.dart';
import 'app_snack_bar.dart';
import '../../l10n/lookup.dart';
import '../../l10n/context.dart';

/// Shared beta56-style follow button for profile/user-preview surfaces.
///
/// The confirmed icon/text is deliberately unchanged while the request is in
/// flight. The canonical [FollowStore] owns rollback and cross-page updates.
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
    var restrict = FollowRestrict.public;
    final selected = await showModalBottomSheet<FollowRestrict>(
      context: context,
      backgroundColor: FuncTokens.transparent,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setState) {
          final colors = Theme.of(sheetContext).colorScheme;
          return Container(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(24),
              ),
            ),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _text(sheetContext, 'followUser'),
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(userName, style: const TextStyle(fontSize: 16)),
                  if (userAccount.isNotEmpty)
                    Text(userAccount, style: const TextStyle(fontSize: 12)),
                  const SizedBox(height: 16),
                  SegmentedButton<FollowRestrict>(
                    segments: [
                      ButtonSegment(
                        value: FollowRestrict.public,
                        label: Text(_text(sheetContext, 'restrictPublic')),
                      ),
                      ButtonSegment(
                        value: FollowRestrict.private,
                        label: Text(_text(sheetContext, 'restrictPrivate')),
                      ),
                    ],
                    selected: {restrict},
                    onSelectionChanged: (value) =>
                        setState(() => restrict = value.first),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.of(sheetContext).pop(),
                          child: Text(_text(sheetContext, 'cancel')),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          onPressed: () =>
                              Navigator.of(sheetContext).pop(restrict),
                          child: Text(_text(sheetContext, 'confirm')),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (selected != null && context.mounted) {
      await ref.read(followActionsProvider).addWithRestrict(userId, selected);
    }
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
          showAppSnackBar(context, '${_text(context, 'followFailed')}: $next');
        }
      },
    );

    final width = compact ? 96.0 : 116.0;
    return SizedBox(
      width: width,
      height: compact ? 36 : 42,
      child: pending
          ? Semantics(
              container: true,
              button: true,
              enabled: false,
              label: semanticLabel,
              liveRegion: true,
              child: const Center(child: CupertinoActivityIndicator()),
            )
          : Semantics(
              container: true,
              button: true,
              toggled: followed,
              label: semanticLabel,
              onTap: () => ref.read(followActionsProvider).toggle(userId),
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
                    padding: EdgeInsets.zero,
                  ),
                  onPressed: () =>
                      ref.read(followActionsProvider).toggle(userId),
                  onLongPress: followed
                      ? null
                      : () => _showRestrictSheet(context, ref),
                  child: Text(
                    semanticLabel,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ),
    );
  }
}
