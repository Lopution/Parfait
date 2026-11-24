import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show LicenseEntry, LicenseRegistry;
import 'package:flutter/services.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/motion/app_overlays.dart';
import '../../../app/widgets/app_spinner.dart';
import '../../../app/motion/reveal.dart';
import '../../../app/theme/func_semantic_tokens.dart';
import '../../../app/widgets/app_dialog.dart';
import '../../../app/widgets/app_progress_bar.dart';
import '../../../app/widgets/app_snack_bar.dart';
import '../../../app/widgets/app_top_bar.dart';
import '../../../app/widgets/edge_icon_buttons.dart';
import '../../../app/widgets/settings/settings_action_tile.dart';
import '../../../app/widgets/settings/settings_group.dart';
import '../../../app/widgets/settings/settings_group_content.dart';
import '../../../app/widgets/settings/settings_tile.dart';
import '../../../core/logging/crash_log.dart';
import '../../../core/platform/app_storage_paths.dart';
import '../../../core/platform/platform_caps.dart';
import '../../../core/settings/shared_preferences.dart';
import '../../../core/share/share_service.dart';
import '../../../core/updater/update_manifest.dart';
import '../../../core/updater/update_providers.dart';
import '../../../core/updater/update_service.dart';
import '../../../l10n/context.dart';
import '../settings_helpers.dart';
import '../../../app/clipboard.dart';
import '../settings_catalog.dart';
import '../../../app/layout/content_widths.dart';
import '../../../app/icons/app_icons.dart';
import '../../../app/icons/ui_icons.dart';

class AboutSettingsPage extends ConsumerStatefulWidget {
  const AboutSettingsPage({super.key});

  @override
  ConsumerState<AboutSettingsPage> createState() => _AboutSettingsPageState();
}

class _AboutSettingsPageState extends ConsumerState<AboutSettingsPage> {
  static const _unlockTaps = 7;
  static const _sourceRepositoryUrl = 'https://github.com/$updateRepository';
  int _versionTaps = 0;

  /// Version comes from the platform package, not a literal: the pubspec
  /// `version:` line is the single source of truth. The build number is
  /// left out: it is the versionCode with the split APK's ABI offset (2001
  /// for arm64 0.9.0), which means nothing to a reader.
  late final Future<PackageInfo> _packageInfo = PackageInfo.fromPlatform();
  late final Future<DisplayMode?> _activeDisplayMode = _readActiveDisplayMode();

  static Future<DisplayMode?> _readActiveDisplayMode() async {
    try {
      return await FlutterDisplayMode.active;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Android's build-number gesture: the version tile counts presses and
  /// unlocks the developer entries after [_unlockTaps]. The countdown only
  /// surfaces on the last few taps so casual presses stay silent. A failed
  /// write is reported; the entries stay for this session.
  void _onVersionTap() {
    if (ref.read(developerOptionsProvider)) return;
    _versionTaps++;
    final remaining = _unlockTaps - _versionTaps;
    if (remaining <= 0) {
      _versionTaps = 0;
      showAppSnackBar(context, context.l10n.developerOptionsUnlocked);
      unawaited(
        persistSettings(
          context,
          () => ref.read(developerOptionsProvider.notifier).unlock(),
        ),
      );
    } else if (remaining <= 3) {
      showAppSnackBar(
        context,
        context.l10n.developerOptionsCountdown(remaining),
      );
    }
  }

  /// Fire-and-forget like the spotlight outbound links: the browser owns
  /// the failure surface when no handler can open the URL.
  void _openSourceRepository() {
    unawaited(
      launchUrl(
        Uri.parse(_sourceRepositoryUrl),
        mode: LaunchMode.externalApplication,
      ),
    );
  }

  Future<void> _copySourceUrl() => copyToClipboard(
    context,
    _sourceRepositoryUrl,
    message: context.l10n.linkCopied,
  );

  @override
  Widget build(BuildContext context) {
    final appName = 'Parfait';
    final updateService = ref.watch(updateServiceProvider);
    return Scaffold(
      appBar: AppTopBar(
        contentWidth: ContentWidths.settings,
        title: Text(context.l10n.aboutSettings),
      ),
      body: settingsNarrowBody(
        ListView(
          padding: const EdgeInsets.only(
            top: FuncSpacing.sm,
            bottom: FuncSpacing.xl,
          ),
          children: [
            // Facts about the app, not rows: no card, nothing to press.
            _AppHeader(
              name: appName,
              attribution: Text(context.l10n.aboutAttributionText),
            ),
            SettingsGroup(
              children: [
                // The version tile is also the developer-options easter
                // egg; it looks like any value row on purpose.
                FutureBuilder<PackageInfo>(
                  future: _packageInfo,
                  builder: (context, snapshot) => SettingsActionTile(
                    icon: AppIcons.info,
                    setting: Setting.aboutVersion,
                    trailing: Text(snapshot.data?.version ?? '—'),
                    onTap: _onVersionTap,
                  ),
                ),
                SettingsTile(
                  icon: AppIcons.localNovel,
                  setting: Setting.aboutLicense,
                  subtitle: Text(context.l10n.aboutLicenseText),
                  onTap: () =>
                      openSettingsPage(context, '/settings/about/licenses'),
                ),
                SettingsActionTile(
                  icon: AppIcons.code,
                  setting: Setting.aboutSource,
                  subtitle: const _ExternalLinkText(
                    'github.com/$updateRepository',
                  ),
                  // The row opens the repository; copying the URL is the
                  // secondary trailing action (settings action row, not a
                  // navigation row).
                  onTap: _openSourceRepository,
                  trailing: EdgeIconButtons(
                    children: [
                      IconButton(
                        icon: const Icon(AppIcons.copy),
                        tooltip: context.l10n.copy,
                        onPressed: _copySourceUrl,
                      ),
                    ],
                  ),
                ),
                Builder(
                  builder: (tileContext) => SettingsActionTile(
                    icon: AppIcons.bugReport,
                    setting: Setting.aboutExportLogs,
                    onTap: () => _exportCrashLog(
                      tileContext,
                      shareService: ref.read(shareServiceProvider),
                      isDesktop: ref.read(platformCapsProvider).isDesktop,
                    ),
                  ),
                ),
                // Read-back of the display mode the engine actually got —
                // OEM ROMs (MIUI/HyperOS, ColorOS) can keep a third-party
                // app at 60Hz despite the preferred-mode request, which
                // looks exactly like a uniform low-fps app. This is the
                // only user-visible way to check it without adb.
                if (Setting.aboutDisplayRefreshRate.available)
                  FutureBuilder<DisplayMode?>(
                    future: _activeDisplayMode,
                    builder: (context, snapshot) => SettingsActionTile(
                      icon: AppIcons.gauge,
                      setting: Setting.aboutDisplayRefreshRate,
                      trailing: Text(
                        snapshot.data != null
                            ? '${snapshot.data!.refreshRate.toStringAsFixed(0)} Hz'
                            : '—',
                      ),
                    ),
                  ),
              ],
            ),
            // The self-update block is one entry point, so it forms its own
            // group below the app info rows.
            SettingsGroup(
              setting: Setting.aboutCheckUpdate,
              children: [
                updateService.when(
                  loading: () => SettingsActionTile(
                    icon: AppIcons.update,
                    title: Text(context.l10n.aboutCheckUpdate),
                    subtitle: Text(context.l10n.aboutCheckingUpdate),
                  ),
                  error: (_, _) => SettingsActionTile(
                    icon: UiIcons.warning,
                    title: Text(context.l10n.aboutCheckUpdate),
                    subtitle: Text(context.l10n.aboutUpdateUnavailable),
                  ),
                  data: (service) => _AboutUpdateSection(service: service),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _exportCrashLog(
  BuildContext context, {
  required ShareService shareService,
  required bool isDesktop,
}) async {
  final shareOrigin = shareOriginOf(context);
  final directory = await AppStoragePaths.active.resolveSupportDir();
  final file = CrashLog.fileFor(directory);
  final hasLog = await file.exists() && await file.length() > 0;
  if (!context.mounted) return;
  if (!hasLog) {
    showAppSnackBar(context, context.l10n.aboutNoLogs);
    return;
  }
  if (isDesktop) {
    final location = await getSaveLocation(suggestedName: 'parfait-crash.log');
    if (location == null) return;
    try {
      await File(location.path).writeAsBytes(await file.readAsBytes());
      if (context.mounted) showAppSnackBar(context, context.l10n.saved);
    } on Object {
      if (context.mounted) showAppSnackBar(context, context.l10n.errorStorage);
    }
    return;
  }
  try {
    await shareService.shareFiles(
      [XFile(file.path)],
      subject: 'parfait-crash.log',
      sharePositionOrigin: shareOrigin,
    );
  } on Object {
    if (context.mounted) showAppSnackBar(context, context.l10n.errorUnknown);
  }
}

class _AboutUpdateSection extends StatefulWidget {
  const _AboutUpdateSection({required this.service});

  final UpdateService service;

  @override
  State<_AboutUpdateSection> createState() => _AboutUpdateSectionState();
}

class _AboutUpdateSectionState extends State<_AboutUpdateSection> {
  late Future<UpdateCapability> _capability;
  UpdateCheckResult? _checkResult;
  UpdateApplyResult? _applyResult;
  var _checking = false;
  var _applying = false;

  @override
  void initState() {
    super.initState();
    _capability = widget.service.capability();
    // Restore the service's remembered check and any in-flight download so
    // leaving and returning to About preserves progress and cancellation.
    _syncFromService();
    widget.service.addStatusListener(_onServiceStatusChanged);
  }

  @override
  void didUpdateWidget(covariant _AboutUpdateSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.service, widget.service)) {
      oldWidget.service.removeStatusListener(_onServiceStatusChanged);
      _capability = widget.service.capability();
      _syncFromService();
      widget.service.addStatusListener(_onServiceStatusChanged);
    }
  }

  @override
  void dispose() {
    widget.service.removeStatusListener(_onServiceStatusChanged);
    super.dispose();
  }

  void _syncFromService() {
    _checkResult = widget.service.lastCheck;
    _applyResult = widget.service.lastApplyResult;
    _checking = widget.service.isChecking;
    _applying = widget.service.isApplying;
  }

  void _onServiceStatusChanged() {
    if (!mounted) return;
    setState(_syncFromService);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<UpdateCapability>(
      future: _capability,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return SettingsActionTile(
            icon: AppIcons.update,
            title: Text(context.l10n.aboutCheckUpdate),
            subtitle: Text(context.l10n.aboutCheckingUpdate),
          );
        }
        final capability = snapshot.data;
        if (snapshot.hasError || capability == null) {
          return SettingsActionTile(
            icon: UiIcons.warning,
            title: Text(context.l10n.aboutCheckUpdate),
            subtitle: Text(context.l10n.aboutUpdateUnavailable),
          );
        }
        if (capability.storeManaged ||
            capability.flavor == UpdateFlavor.fdroid) {
          final android = Theme.of(context).platform == TargetPlatform.android;
          return SettingsActionTile(
            icon: android ? AppIcons.store : UiIcons.warning,
            title: Text(context.l10n.aboutCheckUpdate),
            subtitle: Text(
              android
                  ? context.l10n.aboutUpdateStore
                  : context.l10n.aboutUpdateUnavailable,
            ),
          );
        }
        if (!capability.enabled) {
          return SettingsActionTile(
            icon: UiIcons.warning,
            title: Text(context.l10n.aboutCheckUpdate),
            subtitle: Text(context.l10n.aboutUpdateUnavailable),
          );
        }
        return _githubUpdateControls(context);
      },
    );
  }

  Widget _githubUpdateControls(BuildContext context) {
    final result = _checkResult;
    final release = result?.release;
    final statusText = switch (result?.status) {
      UpdateCheckStatus.available => context.l10n.labelValue(
        context.l10n.aboutUpdateAvailable,
        '${release!.manifest.version}',
      ),
      UpdateCheckStatus.disabled => context.l10n.aboutUpdateUnavailable,
      UpdateCheckStatus.noUpdate => context.l10n.aboutUpdateNoUpdate,
      UpdateCheckStatus.prerelease => context.l10n.aboutUpdatePrerelease,
      // Failure states split by the action the user can take (R10): retry
      // after fixing the network, wait out GitHub rate limiting, report an
      // invalid manifest, or just acknowledge a busy/generic failure.
      UpdateCheckStatus.offline => context.l10n.aboutUpdateOffline,
      UpdateCheckStatus.rateLimited => context.l10n.aboutUpdateRateLimited,
      UpdateCheckStatus.invalid => context.l10n.aboutUpdateInvalid,
      UpdateCheckStatus.busy => context.l10n.aboutUpdateBusy,
      UpdateCheckStatus.failed => context.l10n.aboutUpdateFailed,
      null => null,
    };
    final applyText = switch (_applyResult?.status) {
      UpdateApplyStatus.installPermissionRequired =>
        context.l10n.aboutUpdatePermission,
      UpdateApplyStatus.installStarted => context.l10n.aboutUpdateStarted,
      UpdateApplyStatus.canceled => context.l10n.aboutUpdateCanceled,
      UpdateApplyStatus.failed => context.l10n.aboutUpdateFailed,
      _ => null,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsActionTile(
          icon: AppIcons.update,
          title: Text(context.l10n.aboutCheckUpdate),
          subtitle: Text(
            _checking
                ? context.l10n.aboutCheckingUpdate
                : _applying
                ? context.l10n.aboutUpdateDownloading
                : statusText ?? '',
          ),
        ),
        Reveal(
          child: _checking || _applying
              ? const SettingsGroupContent(child: AppProgressBar())
              : null,
        ),
        Reveal(
          child: applyText == null
              ? null
              : SettingsGroupContent(child: Text(applyText)),
        ),
        SettingsGroupContent(
          child: FilledButton.icon(
            onPressed: _checking
                ? null
                : _applying
                ? _cancelApply
                : release == null
                ? _check
                : () => _confirmAndApply(context, release),
            icon: Icon(
              _applying
                  ? UiIcons.close
                  : release == null
                  ? UiIcons.refresh
                  : AppIcons.download,
            ),
            label: Text(
              _applying
                  ? context.l10n.cancel
                  : release == null
                  ? context.l10n.aboutCheckUpdate
                  : context.l10n.aboutUpdateDownload,
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _check() async {
    if (_checking || _applying) return;
    setState(() {
      _checking = true;
      _checkResult = null;
      _applyResult = null;
    });
    try {
      final result = await widget.service.check();
      if (mounted) setState(() => _checkResult = result);
    } on Object {
      if (mounted) {
        setState(
          () => _checkResult = const UpdateCheckResult(
            status: UpdateCheckStatus.failed,
            errorCode: 'check_failed',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _cancelApply() async {
    try {
      await widget.service.cancel();
    } on Object {
      if (mounted) {
        setState(
          () => _applyResult = const UpdateApplyResult(
            status: UpdateApplyStatus.failed,
            errorCode: 'cancel_failed',
          ),
        );
      }
    }
  }

  Future<void> _confirmAndApply(
    BuildContext context,
    UpdateRelease release,
  ) async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) => AppAlertDialog(
        title: Text(context.l10n.aboutUpdateConfirmTitle),
        content: Text(context.l10n.aboutUpdateConfirmDetail),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.confirm),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _applying = true;
      _applyResult = null;
    });
    try {
      final result = await widget.service.apply(release, confirmed: true);
      if (mounted) setState(() => _applyResult = result);
    } on Object {
      if (mounted) {
        setState(
          () => _applyResult = const UpdateApplyResult(
            status: UpdateApplyStatus.failed,
            errorCode: 'apply_failed',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }
}

/// The launcher icon, the app's name and its attribution, on the page
/// surface where the group titles start.
class _AppHeader extends StatelessWidget {
  const _AppHeader({required this.name, required this.attribution});

  final String name;
  final Widget attribution;

  static const _artworkSize = 56.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      // A group's margin and its rows' inset: where the titles start.
      padding: const EdgeInsets.fromLTRB(
        FuncSpacing.xxl,
        FuncSpacing.sm,
        FuncSpacing.xxl,
        FuncSpacing.xl,
      ),
      child: Row(
        children: [
          // Decoration: the name beside it names the app.
          Image.asset(
            'assets/branding/parfait_icon.png',
            width: _artworkSize,
            height: _artworkSize,
            excludeFromSemantics: true,
          ),
          const SizedBox(width: FuncSpacing.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: theme.textTheme.titleLarge),
                const SizedBox(height: FuncSpacing.xxs),
                DefaultTextStyle.merge(
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  child: attribution,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A link's text that leaves the app, ending in the glyph that says so,
/// in the text's own size and colour.
class _ExternalLinkText extends StatelessWidget {
  const _ExternalLinkText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style;
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: text),
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Padding(
              padding: const EdgeInsetsDirectional.only(start: FuncSpacing.xs),
              child: Icon(
                AppIcons.externalLink,
                size: style.fontSize,
                color: style.color,
                applyTextScaling: true,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Open-source licenses page wrapped in [AppTopBar] so mobile and desktop keep
/// the app's unified header instead of Flutter's default [LicensePage] chrome.
class LicensesSettingsPage extends StatefulWidget {
  const LicensesSettingsPage({super.key, this.applicationVersion});

  final String? applicationVersion;

  @override
  State<LicensesSettingsPage> createState() => _LicensesSettingsPageState();
}

class _LicensesSettingsPageState extends State<LicensesSettingsPage> {
  late final Future<_LicenseCatalog> _catalog = _load();

  Future<_LicenseCatalog> _load() async {
    final results = await Future.wait<Object>([
      PackageInfo.fromPlatform(),
      LicenseRegistry.licenses.toList(),
    ]);
    final info = results[0] as PackageInfo;
    final entries = results[1] as List<LicenseEntry>;
    final byPackage = <String, List<String>>{};
    for (final entry in entries) {
      final buffer = StringBuffer();
      for (final paragraph in entry.paragraphs) {
        if (paragraph.text.isEmpty) continue;
        if (buffer.isNotEmpty) buffer.write('\n\n');
        if (paragraph.indent > 0) {
          buffer.write('  ' * paragraph.indent);
        }
        buffer.write(paragraph.text);
      }
      final block = buffer.toString();
      if (block.isEmpty) continue;
      for (final package in entry.packages) {
        (byPackage[package] ??= []).add(block);
      }
    }
    final packages = byPackage.entries.toList()
      ..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));
    return _LicenseCatalog(version: info.version, packages: packages);
  }

  @override
  Widget build(BuildContext context) {
    final materialL10n = MaterialLocalizations.of(context);
    final embedded = SettingsDetailScope.maybeOf(context) != null;
    final contentWidth = embedded ? 780.0 : ContentWidths.settings;
    return Scaffold(
      appBar: AppTopBar(
        contentWidth: contentWidth,
        title: Text(materialL10n.licensesPageTitle),
      ),
      body: settingsNarrowBody(
        FutureBuilder<_LicenseCatalog>(
          future: _catalog,
          builder: (context, snapshot) {
            final data = snapshot.data;
            if (data == null) {
              return const Center(child: AppSpinner());
            }
            final effectiveVersion = widget.applicationVersion ?? data.version;
            return ListView(
              padding: const EdgeInsets.only(
                top: FuncSpacing.sm,
                bottom: FuncSpacing.xl,
              ),
              children: [
                _AppHeader(
                  name: 'Parfait',
                  attribution: Text(
                    effectiveVersion.isEmpty
                        ? context.l10n.aboutLicenseText
                        : '$effectiveVersion\n${context.l10n.aboutLicenseText}',
                  ),
                ),
                SettingsGroup(
                  children: [
                    for (final entry in data.packages)
                      SettingsTile(
                        title: entry.key,
                        subtitle: Text(
                          materialL10n.licensesPackageDetailText(
                            entry.value.length,
                          ),
                        ),
                        onTap: () => unawaited(
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => _PackageLicensesPage(
                                packageName: entry.key,
                                blocks: entry.value,
                                contentWidth: contentWidth,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _LicenseCatalog {
  const _LicenseCatalog({required this.version, required this.packages});

  final String version;
  final List<MapEntry<String, List<String>>> packages;
}

class _PackageLicensesPage extends StatelessWidget {
  const _PackageLicensesPage({
    required this.packageName,
    required this.blocks,
    required this.contentWidth,
  });

  final String packageName;
  final List<String> blocks;
  final double contentWidth;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppTopBar(contentWidth: contentWidth, title: Text(packageName)),
      body: settingsNarrowBody(
        ListView(
          padding: const EdgeInsets.only(
            top: FuncSpacing.sm,
            bottom: FuncSpacing.xl,
          ),
          children: [
            SettingsGroup(
              children: [
                for (final block in blocks)
                  SettingsGroupContent(
                    child: SelectableText(
                      block,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
