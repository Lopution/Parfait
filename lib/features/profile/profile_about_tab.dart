import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/clipboard.dart';
import '../../app/layout/content_widths.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../app/widgets/edge_icon_buttons.dart';
import '../../app/widgets/errors/error_details.dart';
import '../../app/widgets/inline_translation.dart';
import '../../core/platform/android_intent_channel.dart';
import '../../core/user/user_entity.dart';
import '../../l10n/context.dart';
import 'profile_statistics.dart';

/// User profile About tab: basic identity details, translated introduction,
/// external profile links, and statistics.
class ProfileAboutTab extends ConsumerWidget {
  const ProfileAboutTab({
    super.key,
    required this.user,
    required this.statistics,
  });

  final UserEntity user;
  final List<ProfileStatisticData> statistics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final comment = user.comment;
    final links = <({String label, String value, String id})>[
      if (user.webpage != null)
        (
          label: context.l10n.profileWebsite,
          value: user.webpage!,
          id: 'website',
        ),
      if (user.twitterUrl != null)
        (label: 'Twitter', value: user.twitterUrl!, id: 'twitter'),
      if (user.pawooUrl != null)
        (label: 'Pawoo', value: user.pawooUrl!, id: 'pawoo'),
    ];
    // Rows ending in icon buttons pad themselves (LAYOUT-15); the rest sit
    // in the page margin.
    Widget inMargin(Widget child) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: FuncSpacing.lg),
      child: child,
    );
    final entries = <Widget>[
      _ProfileAboutTextEntry(
        label: context.l10n.profileId,
        value: '${user.id}',
      ),
      if (user.account.isNotEmpty)
        _ProfileAboutTextEntry(
          label: context.l10n.profileAccount,
          value: user.account,
        ),
      if (comment != null) _ProfileIntroduction(text: comment),
      for (final link in links)
        _ProfileSocialLinkRow(
          key: ValueKey('profile-link-${link.id}'),
          id: link.id,
          label: link.label,
          value: link.value,
          onOpen: () =>
              unawaited(_openProfileSocialLink(context, ref, link.value)),
          onCopy: () => unawaited(_copyProfileSocialLink(context, link.value)),
        ),
      inMargin(const Divider()),
      inMargin(
        Text(
          context.l10n.profileStats,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      const SizedBox(height: FuncSpacing.sm),
      for (final statistic in statistics)
        inMargin(ProfileStatistic(statistic: statistic)),
    ];
    return ContentWidthCap(
      maxWidth: ContentWidths.management,
      child: ListView(
        key: PageStorageKey('profile-about-${user.id}'),
        restorationId: 'profile-about-${user.id}',
        padding: const EdgeInsets.only(
          top: FuncSpacing.md,
          bottom: FuncSpacing.xxl,
        ),
        children: entries,
      ),
    );
  }
}

/// The margin of an About row that ends in icon buttons: the last glyph,
/// not its target, ends on the page margin (LAYOUT-15).
const _buttonRowMargin = EdgeInsetsDirectional.only(
  start: FuncSpacing.lg,
  end: FuncSpacing.lg - EdgeIconButtons.glyphInset,
);

class _ProfileAboutTextEntry extends StatelessWidget {
  const _ProfileAboutTextEntry({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: FuncSpacing.lg,
      vertical: FuncSpacing.sm,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: FuncSpacing.xs),
        SelectableText(value),
      ],
    ),
  );
}

/// The user's introduction, with the translate button on its label row and
/// the translation below the text.
class _ProfileIntroduction extends ConsumerStatefulWidget {
  const _ProfileIntroduction({required this.text});

  final String text;

  @override
  ConsumerState<_ProfileIntroduction> createState() =>
      _ProfileIntroductionState();
}

class _ProfileIntroductionState extends ConsumerState<_ProfileIntroduction>
    with InlineTranslation {
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: FuncSpacing.sm),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: _buttonRowMargin,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  context.l10n.profileIntroduction,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              if (widget.text.trim().isNotEmpty)
                TranslateIconButton(
                  translating: translating,
                  shown: translationShown,
                  onPressed: () => unawaited(toggleTranslation([widget.text])),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: FuncSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SelectableText(widget.text),
              TranslationPanel(
                translating: translating,
                translations: translations,
                failure: translationFailure,
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _ProfileSocialLinkRow extends StatelessWidget {
  const _ProfileSocialLinkRow({
    super.key,
    required this.id,
    required this.label,
    required this.value,
    required this.onOpen,
    required this.onCopy,
  });

  final String id;
  final String label;
  final String value;
  final VoidCallback onOpen;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) => Padding(
    padding: _buttonRowMargin.add(
      const EdgeInsets.symmetric(vertical: FuncSpacing.sm),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: FuncSpacing.xs),
        Row(
          children: [
            Expanded(child: SelectableText(value)),
            IconButton(
              key: ValueKey('profile-link-open-$id'),
              tooltip: context.l10n.openLink,
              onPressed: onOpen,
              icon: const Icon(Icons.open_in_new),
            ),
            IconButton(
              key: ValueKey('profile-link-copy-$id'),
              tooltip: context.l10n.copyLink,
              onPressed: onCopy,
              icon: const Icon(Icons.copy_outlined),
            ),
          ],
        ),
      ],
    ),
  );
}

Future<void> _openProfileSocialLink(
  BuildContext context,
  WidgetRef ref,
  String url,
) async {
  try {
    await ref.read(outboundUrlOpenerProvider).openExternal(url);
  } on Object catch (error) {
    if (!context.mounted) return;
    showErrorSnackBar(
      context,
      action: context.l10n.illustDetailOpenLinkFailed,
      error: error,
    );
  }
}

Future<void> _copyProfileSocialLink(BuildContext context, String url) =>
    copyToClipboard(context, url, message: context.l10n.linkCopied);
