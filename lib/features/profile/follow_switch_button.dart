import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/replica_strings.dart';
import '../../core/user/follow_actions.dart';
import '../../core/user/follow_models.dart';
import '../../core/user/follow_store.dart';

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

  String _text(BuildContext context, String key) => ReplicaStrings.fromTag(
    Localizations.localeOf(context).toLanguageTag(),
    key,
  );

  Future<void> _showRestrictSheet(BuildContext context, WidgetRef ref) async {
    var restrict = FollowRestrict.public;
    final selected = await showModalBottomSheet<FollowRestrict>(
      context: context,
      backgroundColor: Colors.transparent,
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
    ref.listen<Object?>(
      followStoreProvider.select((state) => state[userId]?.error),
      (previous, next) {
        if (next != null && previous != next) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            SnackBar(content: Text('${_text(context, 'followFailed')}: $next')),
          );
        }
      },
    );

    final width = compact ? 96.0 : 116.0;
    return SizedBox(
      width: width,
      height: compact ? 36 : 42,
      child: pending
          ? const Center(child: CupertinoActivityIndicator())
          : OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: followed ? colors.onSurface : colors.onPrimary,
                backgroundColor: followed ? colors.surface : colors.primary,
                side: BorderSide(
                  color: followed ? colors.onSurface : colors.primary,
                ),
                padding: EdgeInsets.zero,
              ),
              onPressed: () => ref.read(followActionsProvider).toggle(userId),
              onLongPress: followed
                  ? null
                  : () => _showRestrictSheet(context, ref),
              child: Text(
                _text(context, followed ? 'followed' : 'follow'),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
    );
  }
}
