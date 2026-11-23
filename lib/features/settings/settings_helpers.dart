import 'dart:async';

import 'package:flutter/scheduler.dart' show SchedulerBinding, SchedulerPhase;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/layout/content_widths.dart';
import '../../app/motion/app_overlays.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../app/widgets/app_dialog.dart';
import '../../app/widgets/app_top_bar.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/scroll_edge_fade.dart';
import '../../app/widgets/settings_load_error.dart';
import '../../core/download/download_destination.dart';
import '../../core/download/naming_rule.dart';
import '../../core/settings/app_settings.dart';
import '../../core/settings/settings_controller.dart';
import '../../l10n/context.dart';
import '../../app/widgets/settings/persist_settings.dart';
import 'saf_tree_name.dart';

export '../../app/widgets/settings/persist_settings.dart';

/// The settings column cap (D1): centered at [ContentWidths.settings] on
/// standalone pages, or left-aligned and comfortably wider (780dp) inside the
/// wide master-detail settings pane so forms use the desktop space cleanly.
Widget settingsNarrowBody(Widget child) => _SettingsNarrowBody(child: child);

class _SettingsNarrowBody extends StatelessWidget {
  const _SettingsNarrowBody({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final embedded = SettingsDetailScope.maybeOf(context) != null;
    Widget body = Align(
      alignment: embedded ? AlignmentDirectional.topStart : Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: embedded ? 780 : ContentWidths.settings,
        ),
        child: child,
      ),
    );
    if (embedded) {
      body = ScrollEdgeFade(
        axis: Axis.vertical,
        fadeExtent: FuncSpacing.lg,
        child: body,
      );
    }
    return body;
  }
}

/// Tracks whether any [guardDraft] descendant inside a wide settings detail
/// pane currently holds unsaved changes, so category switches and outer pops
/// can prompt via [confirmDiscardDraft] before discarding them.
class SettingsDraftRegistry extends ChangeNotifier {
  final Set<Object> _dirtyTokens = <Object>{};
  bool _notifyScheduled = false;
  bool _confirmingLeave = false;
  bool _disposed = false;

  bool get hasDirtyDraft => _dirtyTokens.isNotEmpty;

  /// Prompts via [confirmDiscardDraft] when any registered form is dirty,
  /// deduplicating overlapping prompts while a confirmation dialog is open.
  Future<bool> confirmDiscardIfDirty(BuildContext context) async {
    if (!hasDirtyDraft) return true;
    if (_confirmingLeave) return false;
    _confirmingLeave = true;
    try {
      return await confirmDiscardDraft(context);
    } finally {
      _confirmingLeave = false;
    }
  }

  void setDirty(Object token, bool dirty) {
    final before = _dirtyTokens.isNotEmpty;
    if (dirty) {
      _dirtyTokens.add(token);
    } else {
      _dirtyTokens.remove(token);
    }
    if (before != _dirtyTokens.isNotEmpty) {
      _scheduleNotify();
    }
  }

  void unregister(Object token) => setDirty(token, false);

  void _scheduleNotify() {
    if (_disposed) return;
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks ||
        phase == SchedulerPhase.midFrameMicrotasks) {
      if (_notifyScheduled) return;
      _notifyScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _notifyScheduled = false;
        if (!_disposed) notifyListeners();
      });
      return;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _dirtyTokens.clear();
    super.dispose();
  }
}

/// Wraps the wide master-detail settings shell with a [PopScope] that pops the
/// nested detail navigator first and otherwise guards dirty forms registered
/// in [draftRegistry] via [confirmDiscardDraft].
Widget settingsMasterPopScope({
  required SettingsDraftRegistry draftRegistry,
  required bool detailCanPop,
  required GlobalKey<NavigatorState> detailNavigatorKey,
  required Widget child,
}) => ListenableBuilder(
  listenable: draftRegistry,
  builder: (context, _) => PopScope(
    canPop: !detailCanPop && !draftRegistry.hasDirtyDraft,
    onPopInvokedWithResult: (didPop, _) {
      if (didPop) return;
      if (detailCanPop) {
        unawaited(detailNavigatorKey.currentState?.maybePop());
        return;
      }
      final navigator = Navigator.of(context);
      unawaited(
        draftRegistry.confirmDiscardIfDirty(context).then((leave) {
          if (leave && navigator.mounted) navigator.pop();
        }),
      );
    },
    child: child,
  ),
);

/// Draft-form leave guard (same PopScope contract as ProfileEditPage):
/// a clean form pops directly; a dirty one asks via [confirmDiscardDraft]
/// before the route is dropped. When hosted inside a wide settings detail
/// pane, it also reports dirty state to the enclosing [SettingsDraftRegistry].
Widget guardDraft({required bool dirty, required Widget child}) =>
    _DraftGuard(dirty: dirty, child: child);

class _DraftGuard extends StatefulWidget {
  const _DraftGuard({required this.dirty, required this.child});

  final bool dirty;
  final Widget child;

  @override
  State<_DraftGuard> createState() => _DraftGuardState();
}

class _DraftGuardState extends State<_DraftGuard> {
  SettingsDraftRegistry? _registry;

  void _syncRegistry(SettingsDraftRegistry? next) {
    if (!identical(_registry, next)) {
      _registry?.unregister(this);
      _registry = next;
    }
    _registry?.setDirty(this, widget.dirty);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncRegistry(SettingsDetailScope.draftRegistryOf(context));
  }

  @override
  void didUpdateWidget(covariant _DraftGuard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.dirty != widget.dirty) {
      _registry?.setDirty(this, widget.dirty);
    }
  }

  @override
  void dispose() {
    _registry?.unregister(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !widget.dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        unawaited(
          confirmDiscardDraft(context).then((leave) {
            if (leave && context.mounted) Navigator.of(context).pop();
          }),
        );
      },
      child: widget.child,
    );
  }
}

/// The dirty-leave dialog: 取消 keeps editing, the filled button discards
/// the draft. Keys are shared with the profile edit flow so the wording
/// stays identical wherever the guard appears.
Future<bool> confirmDiscardDraft(BuildContext context) async {
  final leave = await showAppDialog<bool>(
    context: context,
    builder: (dialogContext) => AppAlertDialog(
      title: Text(context.l10n.profileEditLeaveTitle),
      content: Text(context.l10n.profileEditLeaveDetail),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: Text(context.l10n.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(context.l10n.profileEditLeaveConfirm),
        ),
      ],
    ),
  );
  return leave == true;
}

Widget settingsUnavailable(
  BuildContext context,
  WidgetRef ref,
  AsyncValue<AppSettings> state, {
  required String titleKey,
}) {
  return Scaffold(
    appBar: AppTopBar(
      contentWidth: ContentWidths.settings,
      title: Text(settingsText(context, titleKey)),
    ),
    body: state.when(
      loading: () => const FeedLoading(),
      error: (error, _) => SettingsLoadError(
        error: error,
        onRetry: () => ref.read(settingsProvider.notifier).reload(),
      ),
      // AsyncData<AppSettings> is never null; this branch only keeps the
      // helper total if the provider implementation changes later.
      data: (_) => const SizedBox.shrink(),
    ),
  );
}

/// Inherited hook for the wide master-detail settings host: subpages pushed
/// inside the detail pane stay on its nested [Navigator] instead of pushing
/// onto the root router over the split layout, and embedded draft forms report
/// dirty state to [draftRegistry].
class SettingsDetailScope extends InheritedWidget {
  const SettingsDetailScope({
    super.key,
    required this.onPush,
    this.draftRegistry,
    required super.child,
  });

  final Future<void> Function(String location) onPush;
  final SettingsDraftRegistry? draftRegistry;

  static Future<void> Function(String location)? maybeOf(
    BuildContext context,
  ) =>
      context.dependOnInheritedWidgetOfExactType<SettingsDetailScope>()?.onPush;

  static SettingsDraftRegistry? draftRegistryOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<SettingsDetailScope>()
      ?.draftRegistry;

  @override
  bool updateShouldNotify(SettingsDetailScope oldWidget) =>
      onPush != oldWidget.onPush || draftRegistry != oldWidget.draftRegistry;
}

Future<void> pushSettingsPage(BuildContext context, String path) {
  final detailPush = SettingsDetailScope.maybeOf(context);
  if (detailPush != null) return detailPush(path);
  return context.push<void>(path);
}

void openSettingsPage(BuildContext context, String path) {
  unawaited(pushSettingsPage(context, path));
}

/// Observes the embedded master-detail settings navigator so the master pane's
/// `PopScope` stays synced with nested push/pop depth.
class SettingsDetailStackObserver extends NavigatorObserver {
  SettingsDetailStackObserver(this.onChanged);

  final VoidCallback onChanged;

  void _notify() {
    WidgetsBinding.instance.addPostFrameCallback((_) => onChanged());
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _notify();

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => _notify();

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _notify();

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _notify();
}

/// Supported app languages as (native display name, BCP-47 tag) pairs —
/// the language page lists them and the settings root reuses the table
/// for the current-value summary. Native names are locale-independent
/// on purpose: the picker must be readable in any UI language.
const List<(String, String)> languageItems = [
  ('简体中文', 'zh-CN'),
  ('English', 'en-US'),
  ('日本語', 'ja-JP'),
  ('Русский', 'ru-RU'),
];

/// Native display name for [tag]; falls back to the raw tag so an
/// unexpected persisted value stays visible instead of blanking out.
String languageDisplayName(String tag) {
  for (final (name, itemTag) in languageItems) {
    if (itemTag == tag) return name;
  }
  return tag;
}

String themeModeLabel(BuildContext context, int themeCode) {
  return switch (themeCode) {
    AppSettings.darkTheme => context.l10n.dark,
    AppSettings.lightTheme => context.l10n.light,
    _ => context.l10n.system,
  };
}

String imageSourceLabel(BuildContext context, ImageSourceMode mode) {
  return switch (mode) {
    ImageSourceMode.auto => context.l10n.imageSourceAuto,
    ImageSourceMode.normal => context.l10n.imageSourceNormal,
    ImageSourceMode.pixivCat => context.l10n.imageSourcePixivCat,
    ImageSourceMode.pixivRe => context.l10n.imageSourcePixivRe,
    ImageSourceMode.pixivNl => context.l10n.imageSourcePixivNl,
    ImageSourceMode.custom => context.l10n.imageSourceCustom,
  };
}

String animationSpeedLabel(BuildContext context, AnimationSpeed speed) {
  return switch (speed) {
    AnimationSpeed.fast => context.l10n.animationSpeedFast,
    AnimationSpeed.normal => context.l10n.animationSpeedNormal,
    AnimationSpeed.slow => context.l10n.animationSpeedSlow,
  };
}

String networkModeLabel(BuildContext context, NetworkMode mode) {
  return switch (mode) {
    NetworkMode.automatic => context.l10n.networkModeAutomatic,
    NetworkMode.compatPrefer => context.l10n.networkModeCompatPrefer,
    NetworkMode.directOnly => context.l10n.networkModeDirectOnly,
  };
}

String translationProviderLabel(
  BuildContext context,
  TranslationProvider provider,
) {
  return switch (provider) {
    TranslationProvider.disabled => context.l10n.translateDisabled,
    TranslationProvider.baidu => context.l10n.translateBaidu,
    TranslationProvider.translationLlm => context.l10n.translateLlm,
    TranslationProvider.google => context.l10n.translateGoogle,
    TranslationProvider.indexTranslate => context.l10n.translateIndex,
  };
}

String namingPresetLabel(BuildContext context, NamingPreset preset) {
  return switch (preset) {
    NamingPreset.id => context.l10n.namingPresetId,
    NamingPreset.artistTitleId => context.l10n.namingPresetArtistTitleId,
    NamingPreset.titleId => context.l10n.namingPresetTitleId,
    NamingPreset.custom => context.l10n.namingPresetCustom,
  };
}

String downloadDestinationLabel(
  BuildContext context,
  DownloadDestination destination,
) {
  final platform = Theme.of(context).platform;
  final isDesktop =
      platform == TargetPlatform.windows ||
      platform == TargetPlatform.macOS ||
      platform == TargetPlatform.linux;
  return switch (destination.kind) {
    DownloadDestinationKind.pixivAlbum =>
      (isDesktop
              ? context.l10n.saveLocationDesktopDefaultFolder
              : context.l10n.saveLocationPixivAlbum)
          .replaceFirst('（默认）', '（\u2060默\u2060认\u2060）'),
    DownloadDestinationKind.customAlbum =>
      '${isDesktop ? context.l10n.saveLocationDesktopCustomSubfolder : context.l10n.saveLocationCustomAlbum} '
          '(${destination.customAlbumName})',
    DownloadDestinationKind.safFolder => switch (destination.safTreeUri) {
      final uri? when uri.isNotEmpty => safTreeDisplayName(context.l10n, uri),
      _ =>
        isDesktop
            ? context.l10n.saveLocationDesktopCustomFolder
            : context.l10n.saveLocationSafFolder,
    },
  };
}
