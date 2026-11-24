import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../app/format/app_format.dart';
import '../../app/icons/app_icons.dart';
import '../../app/navigation/route_facade.dart';
import '../../app/person_avatar.dart';
import '../../app/pixiv_image.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../app/theme/func_tokens.dart';
import '../../app/widgets/ambient_wash.dart';
import '../../app/widgets/edge_icon_buttons.dart';
import '../../app/widgets/person_card.dart';
import '../../core/auth/account.dart';
import '../../core/user/user_entity.dart';
import '../../l10n/context.dart';
import 'settings_catalog.dart';
import 'settings_helpers.dart';

String? _resolvedAvatarUrl(Account? account, UserEntity? detail) {
  final primary = account?.profileImageUrl;
  if (primary != null && primary.isNotEmpty) return primary;
  final fallback = detail?.profileImageUrl;
  if (fallback != null && fallback.isNotEmpty) return fallback;
  return null;
}

String? _resolvedWashUrl(Account? account, UserEntity? detail) {
  final cover = detail?.backgroundImageUrl;
  if (cover != null && cover.isNotEmpty) return cover;
  return _resolvedAvatarUrl(account, detail);
}

/// Atmospheric personal header for mobile Me dashboard: subtle [AmbientWash]
/// backdrop when cover/avatar artwork is available, `PersonCard` identity
/// (preserving its single button semantic label), and a crisp live 3-column
/// stats footer once `userDetail` is loaded.
class MeAccountHeader extends StatelessWidget {
  const MeAccountHeader({super.key, required this.account, this.detail});

  final Account? account;
  final UserEntity? detail;

  static const _avatarDiameter = 54.0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final tokens = FuncSemanticTokens.of(context);
    final value = account;
    final detail = value == null ? null : this.detail;
    final url = _resolvedAvatarUrl(value, detail);
    final washUrl = _resolvedWashUrl(value, detail);
    final card = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        PersonCard(
          color: FuncTokens.transparent,
          onTap: value == null
              ? () => unawaited(openLogin(context))
              : () => unawaited(openMe(context)),
          tapHint: value == null ? null : l10n.meOpenProfile,
          endPadding: PersonCard.padding - EdgeIconButtons.glyphInset,
          trailing: value == null
              ? null
              : IconButton(
                  tooltip: l10n.accountManagement,
                  icon: const Icon(AppIcons.accountManage),
                  onPressed: () =>
                      openSettingsPage(context, SettingsPageRef.account.path),
                ),
          child: Row(
            children: [
              SizedBox.square(
                dimension: _avatarDiameter,
                child: PersonAvatar(
                  imageUrl: url,
                  radius: _avatarDiameter / 2,
                  ring: value != null,
                ),
              ),
              const SizedBox(width: FuncSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            value?.name ?? l10n.signedOut,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: tokens.display,
                          ),
                        ),
                        if (value?.isPremium ?? false) ...[
                          const SizedBox(width: FuncSpacing.sm),
                          const _PremiumBadge(),
                        ],
                      ],
                    ),
                    const SizedBox(height: FuncSpacing.xxs),
                    Text(
                      value == null
                          ? l10n.login
                          : l10n.labelValue(l10n.profileId, '${value.userId}'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (value != null && detail != null)
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: tokens.brandHairline)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: _HeaderStatCell(
                    label: l10n.profileBookmarked,
                    value: AppFormat.count(
                      context,
                      detail.totalIllustBookmarksPublic,
                    ),
                    onTap: () =>
                        unawaited(openMe(context, tab: MeTab.bookmarks)),
                  ),
                ),
                Expanded(
                  child: _HeaderStatCell(
                    label: l10n.profileFollowing,
                    value: AppFormat.count(context, detail.totalFollowUsers),
                    onTap: () =>
                        unawaited(openMe(context, tab: MeTab.following)),
                  ),
                ),
                Expanded(
                  child: _HeaderStatCell(
                    label: l10n.profileMyPixiv,
                    value: AppFormat.count(context, detail.totalMyPixivUsers),
                    onTap: () => unawaited(openMe(context, tab: MeTab.myPixiv)),
                  ),
                ),
              ],
            ),
          ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        FuncSpacing.lg,
        FuncSpacing.sm,
        FuncSpacing.lg,
        FuncSpacing.lg,
      ),
      child: Material(
        color: colors.surfaceContainer,
        shape: const RoundedRectangleBorder(borderRadius: FuncShape.panel),
        clipBehavior: Clip.antiAlias,
        child: washUrl == null
            ? card
            : Stack(
                children: [
                  Positioned.fill(
                    child: _CardWashBackdrop(
                      imageUrl: washUrl,
                      surfaceColor: colors.surfaceContainer,
                    ),
                  ),
                  card,
                ],
              ),
      ),
    );
  }
}

class _CardWashBackdrop extends StatelessWidget {
  const _CardWashBackdrop({required this.imageUrl, required this.surfaceColor});

  final String imageUrl;
  final Color surfaceColor;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ExcludeSemantics(
        child: Stack(
          fit: StackFit.expand,
          children: [
            AmbientWash(
              image: PixivImage.providerFor(context, imageUrl, decodeWidth: 96),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    surfaceColor.withValues(alpha: 0.42),
                    surfaceColor.withValues(alpha: 0.90),
                    surfaceColor,
                  ],
                  stops: const [0, 0.72, 1],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeaderStatCell extends StatelessWidget {
  const _HeaderStatCell({
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Semantics(
      container: true,
      button: true,
      label: '$label, $value',
      onTap: onTap,
      child: ExcludeSemantics(
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: FuncSpacing.sm,
              vertical: FuncSpacing.sm + FuncSpacing.xxs,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700)
                      .tabular,
                ),
                const SizedBox(height: FuncSpacing.xxs),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Compact `40dp` identity card pinned below the `52dp` master header in the
/// wide Me workspace rail.
class MeCompactAccountHeader extends StatelessWidget {
  const MeCompactAccountHeader({super.key, required this.account, this.detail});

  final Account? account;
  final UserEntity? detail;

  static const _avatarDiameter = 40.0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final value = account;
    final url = _resolvedAvatarUrl(value, value == null ? null : detail);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        FuncSpacing.md,
        FuncSpacing.sm,
        FuncSpacing.md,
        FuncSpacing.xs,
      ),
      child: Material(
        color: colors.surfaceContainer,
        shape: const RoundedRectangleBorder(borderRadius: FuncShape.card),
        clipBehavior: Clip.antiAlias,
        child: Semantics(
          onTapHint: value == null ? null : l10n.meOpenProfile,
          child: InkWell(
            onTap: value == null
                ? () => unawaited(openLogin(context))
                : () => unawaited(openMe(context)),
            child: Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(
                FuncSpacing.md,
                FuncSpacing.sm,
                FuncSpacing.xs,
                FuncSpacing.sm,
              ),
              child: Row(
                children: [
                  SizedBox.square(
                    dimension: _avatarDiameter,
                    child: PersonAvatar(
                      imageUrl: url,
                      radius: _avatarDiameter / 2,
                      ring: value != null,
                    ),
                  ),
                  const SizedBox(width: FuncSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          value?.name ?? l10n.signedOut,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          value == null
                              ? l10n.login
                              : l10n.labelValue(
                                  l10n.profileId,
                                  '${value.userId}',
                                ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (value != null)
                    IconButton(
                      tooltip: l10n.accountManagement,
                      icon: const Icon(AppIcons.accountManage),
                      onPressed: () => openSettingsPage(
                        context,
                        SettingsPageRef.account.path,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// pixiv Premium beside the name: a neutral pill, a fact about the
/// account rather than an accent (THEME-07).
class _PremiumBadge extends StatelessWidget {
  const _PremiumBadge();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: FuncShape.pill,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: FuncSpacing.sm,
          vertical: FuncSpacing.xxs,
        ),
        child: Text(
          context.l10n.premiumBadge,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
