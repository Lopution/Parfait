import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../app/icons/app_icons.dart';
import '../../app/icons/ui_icons.dart';
import '../../app/layout/content_widths.dart';
import '../../app/navigation/route_facade.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../core/reverse_image/reverse_image_engine.dart';
import '../../core/reverse_image/reverse_image_html_parser.dart';
import '../../core/reverse_image/reverse_image_navigation_policy.dart';
import '../../l10n/context.dart';

/// Displays parsed matches from a service-rendered SauceNAO / IQDB HTML result
/// page on platforms without an in-app WebView (Linux), while keeping a browser
/// fallback that only opens validated HTTPS engine URLs.
class ReverseImageHtmlResultsView extends StatelessWidget {
  const ReverseImageHtmlResultsView({
    super.key,
    required this.spec,
    required this.html,
    required this.fallbackUri,
    required this.onOpenExternal,
  });

  final ReverseImageEngineSpec spec;
  final String html;
  final Uri fallbackUri;
  final Future<void> Function(Uri uri) onOpenExternal;

  void _openMatch(BuildContext context, ReverseImageHtmlMatch match) {
    switch (match.action) {
      case ReverseImageNavigationAction.openIllust:
        final id = match.illustId;
        if (id != null) unawaited(openIllust(context, id));
      case ReverseImageNavigationAction.openUser:
        final id = match.userId;
        if (id != null) unawaited(openUser(context, id));
      case ReverseImageNavigationAction.openExternal:
        unawaited(onOpenExternal(match.uri));
      case ReverseImageNavigationAction.navigate:
      case ReverseImageNavigationAction.reject:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final matches = parseReverseImageHtmlMatches(spec, html);
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (matches.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(FuncSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                AppIcons.imageSearch,
                size: 48,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(height: FuncSpacing.md),
              Text(l10n.searchReverseNoResults, textAlign: TextAlign.center),
              const SizedBox(height: FuncSpacing.lg),
              FilledButton.icon(
                onPressed: () => unawaited(onOpenExternal(fallbackUri)),
                icon: const Icon(AppIcons.externalLink),
                label: Text(l10n.searchReverseOpenInBrowser),
              ),
            ],
          ),
        ),
      );
    }

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: ContentWidths.article),
        child: ListView.separated(
          padding: const EdgeInsets.all(FuncSpacing.lg),
          itemCount: matches.length + 1,
          separatorBuilder: (_, _) => const SizedBox(height: FuncSpacing.sm),
          itemBuilder: (context, index) {
            if (index == matches.length) {
              return Padding(
                padding: const EdgeInsets.only(top: FuncSpacing.sm),
                child: Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: OutlinedButton.icon(
                    onPressed: () => unawaited(onOpenExternal(fallbackUri)),
                    icon: const Icon(AppIcons.externalLink, size: 18),
                    label: Text(l10n.searchReverseOpenInBrowser),
                  ),
                ),
              );
            }
            final match = matches[index];
            final inApp =
                match.action == ReverseImageNavigationAction.openIllust ||
                match.action == ReverseImageNavigationAction.openUser;
            final subtitle = match.uri.path.isEmpty || match.uri.path == '/'
                ? match.uri.host
                : '${match.uri.host}${match.uri.path}';
            return Card(
              margin: EdgeInsets.zero,
              clipBehavior: Clip.antiAlias,
              child: ListTile(
                key: ValueKey('reverse-html-match-$index'),
                leading: CircleAvatar(
                  backgroundColor: inApp
                      ? scheme.primaryContainer
                      : scheme.surfaceContainerHighest,
                  foregroundColor: inApp
                      ? scheme.onPrimaryContainer
                      : scheme.onSurfaceVariant,
                  child: Icon(
                    inApp ? AppIcons.palette : AppIcons.externalLink,
                    size: 18,
                  ),
                ),
                title: Text(
                  match.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (match.similarity != null) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: FuncSpacing.sm,
                          vertical: FuncSpacing.xxs,
                        ),
                        decoration: BoxDecoration(
                          color: scheme.secondaryContainer,
                          borderRadius: FuncShape.pill,
                        ),
                        child: Text(
                          match.similarity!,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSecondaryContainer,
                          ),
                        ),
                      ),
                      const SizedBox(width: FuncSpacing.xs),
                    ],
                    Icon(
                      inApp ? UiIcons.chevronRight : AppIcons.externalLink,
                      size: 18,
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                ),
                onTap: () => _openMatch(context, match),
              ),
            );
          },
        ),
      ),
    );
  }
}
