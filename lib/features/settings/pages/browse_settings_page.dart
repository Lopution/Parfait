import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/widgets/settings/settings_control.dart';
import '../../../app/widgets/settings/settings_section.dart';
import '../../../core/settings/app_settings.dart';
import '../../../core/settings/settings_controller.dart';
import '../../../l10n/context.dart';
import '../settings_helpers.dart';

class BrowseSettingsPage extends ConsumerWidget {
  const BrowseSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(settingsProvider);
    final settings = state.value;
    if (settings == null) {
      return settingsUnavailable(
        context,
        ref,
        state,
        titleKey: 'browseSettings',
      );
    }
    final sources = [
      (AppSettings.normalImageSource, context.l10n.imageSourceNormal),
    ];
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.browseSettings)),
      body: ListView(
        children: [
          // C13: a single product option is not a meaningful choice; the
          // whole section is hidden until a second product-level image
          // source exists.
          if (sources.length > 1) ...[
            SettingsSection(title: Text(context.l10n.imageSource)),
            for (final source in sources)
              ListTile(
                title: Text(source.$2),
                trailing: settings.imageSource == source.$1
                    ? Icon(
                        Icons.check,
                        color: Theme.of(context).colorScheme.primary,
                      )
                    : null,
                onTap: () => persistSettings(
                  context,
                  () => ref
                      .read(settingsProvider.notifier)
                      .selectImageSource(source.$1),
                ),
              ),
            const Divider(),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              context.l10n.previewQuality,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: SegmentedButton<PreviewQuality>(
              segments: [
                for (final quality in PreviewQuality.values)
                  ButtonSegment<PreviewQuality>(
                    value: quality,
                    label: Text(_qualityText(context, quality)),
                  ),
              ],
              selected: {settings.previewQuality},
              onSelectionChanged: (selected) => persistSettings(
                context,
                () => ref
                    .read(settingsProvider.notifier)
                    .setPreviewQuality(selected.first),
              ),
            ),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              context.l10n.detailQuality,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: SegmentedButton<DetailQuality>(
              segments: [
                for (final quality in const [
                  DetailQuality.large,
                  DetailQuality.original,
                ])
                  ButtonSegment<DetailQuality>(
                    value: quality,
                    label: Text(_qualityText(context, quality)),
                  ),
              ],
              selected: {settings.detailQuality},
              onSelectionChanged: (selected) => persistSettings(
                context,
                () => ref
                    .read(settingsProvider.notifier)
                    .setDetailQuality(selected.first),
              ),
            ),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              context.l10n.viewQuality,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: SegmentedButton<ViewQuality>(
              segments: [
                for (final quality in const [
                  ViewQuality.large,
                  ViewQuality.original,
                ])
                  ButtonSegment<ViewQuality>(
                    value: quality,
                    label: Text(_qualityText(context, quality)),
                  ),
              ],
              selected: {settings.viewQuality},
              onSelectionChanged: (selected) => persistSettings(
                context,
                () => ref
                    .read(settingsProvider.notifier)
                    .setViewQuality(selected.first),
              ),
            ),
          ),
          const Divider(),
          SettingsControl(
            title: Text(context.l10n.pixivHistory),
            value: settings.enablePixivHistory,
            onChanged: (value) => persistSettings(
              context,
              () => ref
                  .read(settingsProvider.notifier)
                  .setPixivHistoryEnabled(value),
            ),
          ),
          SettingsControl(
            title: Text(context.l10n.blockR18),
            value: settings.enableLocalBlockR18,
            onChanged: (value) => persistSettings(
              context,
              () => ref.read(settingsProvider.notifier).setLocalBlockR18(value),
            ),
          ),
          SettingsControl(
            title: Text(context.l10n.blockAI),
            value: settings.enableLocalBlockAI,
            onChanged: (value) => persistSettings(
              context,
              () => ref.read(settingsProvider.notifier).setLocalBlockAI(value),
            ),
          ),
        ],
      ),
    );
  }
}

String _qualityText(BuildContext context, Object quality) {
  return switch (quality) {
    PreviewQuality.medium ||
    ViewQuality.medium ||
    DetailQuality.medium => context.l10n.qualityMedium,
    PreviewQuality.large ||
    ViewQuality.large ||
    DetailQuality.large => context.l10n.qualityLarge,
    ViewQuality.original ||
    DetailQuality.original => context.l10n.qualityOriginal,
    _ => context.l10n.qualityLarge,
  };
}
