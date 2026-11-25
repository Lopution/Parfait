import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/context.dart';
import '../motion/app_overlays.dart';
import '../theme/func_semantic_tokens.dart';

bool _shortcutsSheetOpen = false;

/// Shows the grouped keyboard shortcut reference dialog. Re-entrant calls
/// while the dialog is already open are ignored so repeated `?` presses never
/// stack duplicate overlays.
Future<void> showKeyboardShortcutsSheet(BuildContext context) async {
  if (_shortcutsSheetOpen) return;
  _shortcutsSheetOpen = true;
  try {
    await showAppAdaptiveDialog<void>(
      context: context,
      maxWidth: 520,
      builder: (_) => const _KeyboardShortcutsDialog(),
    );
  } finally {
    _shortcutsSheetOpen = false;
  }
}

class _KeyboardShortcutsDialog extends StatelessWidget {
  const _KeyboardShortcutsDialog();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tokens = FuncSemanticTokens.of(context);
    final platform = Theme.of(context).platform;
    final isApple =
        platform == TargetPlatform.macOS || platform == TargetPlatform.iOS;
    final mod = isApple ? 'Cmd' : 'Ctrl';
    final backForward = isApple ? 'Cmd+[ / Cmd+]' : 'Alt+← / Alt+→';

    final groups = [
      (
        title: l10n.shortcutsGroupNavigation,
        items: [
          (label: l10n.shortcutNavBackForward, keys: backForward),
          (label: l10n.shortcutNavTabs, keys: '$mod+1..5'),
          (label: l10n.shortcutNavSearch, keys: '$mod+F / $mod+K / /'),
          (label: l10n.shortcutNavRefresh, keys: '$mod+R / F5'),
          (label: l10n.shortcutNavSettings, keys: '$mod+,'),
          (label: l10n.shortcutNavRailOrBookmarks, keys: '$mod+B'),
          (label: l10n.shortcutNavSelectAll, keys: '$mod+A'),
          (label: l10n.shortcutNavShortcuts, keys: '? / $mod+/'),
        ],
      ),
      (
        title: l10n.shortcutsGroupArtwork,
        items: [
          (label: l10n.shortcutArtworkBookmark, keys: 'B / Shift+B'),
          (label: l10n.shortcutArtworkSave, keys: 'S / $mod+S'),
          (label: l10n.shortcutArtworkCopy, keys: '$mod+C'),
          (label: l10n.shortcutArtworkChrome, keys: 'F'),
          (label: l10n.shortcutArtworkInfo, keys: 'I'),
          (label: l10n.shortcutArtworkSwitchWork, keys: '[ / ] / Shift+←/→'),
          (label: l10n.shortcutArtworkSwitchPage, keys: '← / → / J / K'),
          (label: l10n.shortcutArtworkZoom, keys: '+ / - / 0'),
        ],
      ),
      (
        title: l10n.shortcutsGroupNovel,
        items: [
          (label: l10n.shortcutArtworkBookmark, keys: 'B'),
          (label: l10n.shortcutNovelToc, keys: 'T'),
          (label: l10n.shortcutArtworkChrome, keys: 'F'),
          (
            label: l10n.shortcutNovelNavigate,
            keys: '← / → / ↑ / ↓ / Space / Home / End',
          ),
        ],
      ),
    ];

    return Focus(
      autofocus: true,
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          Navigator.of(context).maybePop();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            FuncSpacing.xl,
            FuncSpacing.lg,
            FuncSpacing.xl,
            FuncSpacing.lg,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.keyboardShortcutsTitle,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(
                      MaterialLocalizations.of(context).closeButtonTooltip,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: FuncSpacing.md),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < groups.length; i++) ...[
                        if (i > 0) const SizedBox(height: FuncSpacing.lg),
                        Text(
                          groups[i].title,
                          style: tokens.label.copyWith(
                            color: tokens.contentSecondary,
                          ),
                        ),
                        const SizedBox(height: FuncSpacing.xs),
                        for (final item in groups[i].items)
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical: FuncSpacing.xs,
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(item.label, style: tokens.body),
                                ),
                                const SizedBox(width: FuncSpacing.md),
                                _ShortcutKeyBadge(label: item.keys),
                              ],
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ShortcutKeyBadge extends StatelessWidget {
  const _ShortcutKeyBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final tokens = FuncSemanticTokens.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surfaceRaised,
        borderRadius: FuncShape.badge,
        border: Border.all(color: tokens.divider),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: FuncSpacing.sm,
          vertical: FuncSpacing.xs,
        ),
        child: Text(
          label,
          style: tokens.caption.copyWith(
            color: tokens.contentPrimary,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}
