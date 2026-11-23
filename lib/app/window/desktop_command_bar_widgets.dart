import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/auth/account_store.dart';
import '../../core/settings/app_settings.dart';
import '../../core/settings/settings_controller.dart';
import '../../l10n/context.dart';
import '../icons/app_icons.dart';
import '../icons/ui_icons.dart';
import '../navigation/forward_history.dart';
import '../navigation/route_facade.dart';
import '../person_avatar.dart';
import '../theme/func_semantic_tokens.dart';
import '../widgets/replica_switch_tile.dart';
import '../widgets/settings/persist_settings.dart';
import 'desktop_title_bar.dart';

/// Draggable title-bar spacer between command-bar clusters.
class DesktopCommandDragSpacer extends StatelessWidget {
  const DesktopCommandDragSpacer({
    super.key,
    required this.height,
    required this.actions,
  });

  final double height;
  final DesktopWindowActions? actions;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: actions == null ? null : (_) => actions!.onStartDragging(),
        onDoubleTap: actions?.onTitleBarDoubleClick,
        child: SizedBox(height: height),
      ),
    );
  }
}

/// Centered command-bar search capsule with shortcut hint and reverse-search
/// trigger.
class DesktopCommandSearchPill extends StatelessWidget {
  const DesktopCommandSearchPill({
    super.key,
    required this.height,
    required this.hint,
    required this.keyword,
    required this.reverseTooltip,
    required this.showShortcutBadge,
    required this.onTapPill,
    required this.onTapReverse,
  });

  final double height;
  final String hint;
  final String keyword;
  final String reverseTooltip;
  final bool showShortcutBadge;
  final VoidCallback onTapPill;
  final VoidCallback onTapReverse;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final hasKeyword = keyword.isNotEmpty;
    final tokens = FuncSemanticTokens.of(context);
    final shortcutLabel = theme.platform == TargetPlatform.macOS
        ? '⌘K'
        : 'Ctrl K';
    return Material(
      key: const Key('desktop-command-search-pill'),
      color: colors.surfaceContainer,
      shape: RoundedRectangleBorder(
        borderRadius: FuncShape.pill,
        side: BorderSide(color: tokens.brandHairline),
      ),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: height,
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                container: true,
                button: true,
                label: hasKeyword ? keyword : hint,
                excludeSemantics: true,
                child: InkWell(
                  onTap: onTapPill,
                  child: SizedBox.expand(
                    child: Row(
                      children: [
                        const SizedBox(width: FuncSpacing.md),
                        Icon(
                          AppIcons.search,
                          size: 15,
                          color: colors.onSurfaceVariant,
                        ),
                        const SizedBox(width: FuncSpacing.sm),
                        Expanded(
                          child: Text(
                            hasKeyword ? keyword : hint,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: hasKeyword
                                  ? colors.onSurface
                                  : colors.onSurfaceVariant,
                            ),
                          ),
                        ),
                        if (showShortcutBadge && !hasKeyword) ...[
                          const SizedBox(width: FuncSpacing.xs),
                          DecoratedBox(
                            decoration: BoxDecoration(
                              color: colors.surfaceContainerHigh,
                              borderRadius: FuncShape.badge,
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: FuncSpacing.xs,
                                vertical: FuncSpacing.xxs,
                              ),
                              child: Text(
                                shortcutLabel,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  fontWeight: FontWeight.w500,
                                  color: tokens.contentSecondary,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
            desktopCommandIconButton(
              context,
              key: const Key('desktop-command-reverse-search'),
              constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
              padding: const EdgeInsets.all(FuncSpacing.xs),
              iconSize: 16,
              tooltip: reverseTooltip,
              onPressed: onTapReverse,
              icon: const Icon(AppIcons.imageSearch),
            ),
            const SizedBox(width: FuncSpacing.xxs),
          ],
        ),
      ),
    );
  }
}

/// Content-filter popover body (local R-18 and AI-work toggles).
class DesktopCommandFilterPopover extends ConsumerWidget {
  const DesktopCommandFilterPopover({
    super.key,
    required this.fallbackSettings,
  });

  final AppSettings fallbackSettings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final settings = ref.watch(settingsProvider).value ?? fallbackSettings;
    const tilePadding = EdgeInsets.symmetric(
      horizontal: FuncSpacing.md,
      vertical: FuncSpacing.xs,
    );
    return Theme(
      data: Theme.of(
        context,
      ).copyWith(materialTapTargetSize: MaterialTapTargetSize.shrinkWrap),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 40),
            child: ReplicaSwitchTile(
              key: const Key('desktop-command-filter-r18'),
              contentPadding: tilePadding,
              title: Text(l10n.blockR18),
              value: settings.enableLocalBlockR18,
              onTap: () => unawaited(
                persistSettings(
                  context,
                  () => ref
                      .read(settingsProvider.notifier)
                      .setLocalBlockR18(!settings.enableLocalBlockR18),
                ),
              ),
            ),
          ),
          const Divider(height: 1),
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 40),
            child: ReplicaSwitchTile(
              key: const Key('desktop-command-filter-ai'),
              contentPadding: tilePadding,
              title: Text(l10n.blockAI),
              value: settings.enableLocalBlockAI,
              onTap: () => unawaited(
                persistSettings(
                  context,
                  () => ref
                      .read(settingsProvider.notifier)
                      .setLocalBlockAI(!settings.enableLocalBlockAI),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Account-switcher popover body for `DesktopCommandBar`.
class DesktopCommandAccountPopover extends ConsumerWidget {
  const DesktopCommandAccountPopover({super.key, required this.router});

  final GoRouter router;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final state = ref.watch(accountStoreProvider).value;
    final accounts = state?.accounts ?? const [];
    final currentId = state?.current?.id;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            FuncSpacing.lg,
            FuncSpacing.md,
            FuncSpacing.lg,
            FuncSpacing.xs,
          ),
          child: Text(
            l10n.accountSignedIn,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        if (accounts.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: FuncSpacing.lg,
              vertical: FuncSpacing.md,
            ),
            child: Text(l10n.noAccounts),
          )
        else
          for (final account in accounts)
            ListTile(
              key: Key('desktop-command-account-${account.id}'),
              dense: true,
              leading: PersonAvatar(
                imageUrl: account.profileImageUrl,
                radius: 14,
              ),
              title: Text(
                account.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '@${account.userId}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: account.id == currentId
                  ? Icon(
                      UiIcons.check,
                      color: Theme.of(context).colorScheme.primary,
                    )
                  : null,
              onTap: () {
                Navigator.of(context).pop();
                if (account.id != currentId) {
                  unawaited(
                    ref
                        .read(accountStoreProvider.notifier)
                        .switchAccount(account.id),
                  );
                }
              },
            ),
        const Divider(height: 1),
        ListTile(
          key: const Key('desktop-command-account-settings'),
          dense: true,
          leading: const Icon(AppIcons.accountManage),
          title: Text(l10n.accountSettings),
          onTap: () {
            Navigator.of(context).pop();
            final currentUri = liveRouterUri(router);
            if (currentUri.path == settingsAccountPath) {
              ForwardHistoryStack.ofRouter(
                router,
              ).syncSettingsDetail(settingsAccountPath);
            } else {
              router.go(settingsAccountPath);
            }
          },
        ),
      ],
    );
  }
}

/// Command bar buttons mount in `MaterialApp.router(builder: ...)` above
/// `Router`'s `Overlay`; only wire Material tooltips when an `Overlay` exists,
/// mirroring `DesktopWindowCaptionButtons` semantics fallback.
Widget desktopCommandIconButton(
  BuildContext context, {
  required Key key,
  required BoxConstraints constraints,
  required EdgeInsetsGeometry padding,
  required double iconSize,
  required String tooltip,
  required VoidCallback? onPressed,
  required Widget icon,
}) {
  final hasOverlay = Overlay.maybeOf(context) != null;
  return IconButton(
    key: key,
    constraints: constraints,
    padding: padding,
    iconSize: iconSize,
    style: IconButton.styleFrom(
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
    tooltip: hasOverlay ? tooltip : null,
    onPressed: onPressed,
    icon: hasOverlay ? icon : Semantics(tooltip: tooltip, child: icon),
  );
}

Widget maybeWrapCommandTooltip(
  BuildContext context, {
  required String message,
  bool excludeFromSemantics = false,
  required Widget child,
}) {
  if (Overlay.maybeOf(context) != null) {
    return Tooltip(
      message: message,
      excludeFromSemantics: excludeFromSemantics,
      child: child,
    );
  }
  if (excludeFromSemantics) return child;
  return Semantics(tooltip: message, child: child);
}
