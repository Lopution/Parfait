import 'dart:async';
import 'dart:io';

import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/motion/app_overlays.dart';
import '../../../app/widgets/app_snack_bar.dart';
import '../../../core/logging/crash_log.dart';
import '../../../core/settings/shared_preferences.dart';
import '../../../core/updater/update_manifest.dart';
import '../../../core/updater/update_providers.dart';
import '../../../core/updater/update_service.dart';
import '../../../l10n/context.dart';
import '../settings_helpers.dart';

class AboutSettingsPage extends ConsumerStatefulWidget {
  const AboutSettingsPage({super.key});

  @override
  ConsumerState<AboutSettingsPage> createState() => _AboutSettingsPageState();
}

class _AboutSettingsPageState extends ConsumerState<AboutSettingsPage> {
  static const _unlockTaps = 7;
  static const _sourceRepositoryUrl = 'https://github.com/$updateRepository';
  int _versionTaps = 0;

  /// Android's build-number gesture: the version tile counts presses and
  /// unlocks the developer entries after [_unlockTaps]. The countdown only
  /// surfaces on the last few taps so casual presses stay silent.
  void _onVersionTap() {
    if (ref.read(developerOptionsProvider)) return;
    _versionTaps++;
    final remaining = _unlockTaps - _versionTaps;
    if (remaining <= 0) {
      _versionTaps = 0;
      unawaited(ref.read(developerOptionsProvider.notifier).unlock());
      showAppSnackBar(context, context.l10n.developerOptionsUnlocked);
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

  Future<void> _copySourceUrl() async {
    await Clipboard.setData(const ClipboardData(text: _sourceRepositoryUrl));
    if (mounted) {
      showAppSnackBar(context, context.l10n.linkCopied);
    }
  }

  @override
  Widget build(BuildContext context) {
    final appName = 'Pixiv Func';
    final updateService = ref.watch(updateServiceProvider);
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.aboutSettings)),
      body: settingsNarrowBody(
        ListView(
          children: [
            const ListTile(
              leading: Icon(Icons.apps),
              title: Text('Pixiv Func'),
            ),
            // Version comes from the platform package, not a literal — the
            // pubspec `version:` line is the single source of truth (R1).
            FutureBuilder<PackageInfo>(
              future: PackageInfo.fromPlatform(),
              builder: (context, snapshot) {
                final info = snapshot.data;
                final label = info == null
                    ? '—'
                    : '${info.version}+${info.buildNumber}';
                return Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.info_outline),
                      title: Text(context.l10n.aboutVersion),
                      trailing: Text(label),
                      onTap: _onVersionTap,
                    ),
                    ListTile(
                      leading: const Icon(Icons.menu_book_outlined),
                      title: Text(context.l10n.aboutLicense),
                      subtitle: Text(context.l10n.aboutLicenseText),
                      onTap: () => showLicensePage(
                        context: context,
                        applicationName: appName,
                        applicationVersion: info?.version,
                      ),
                    ),
                  ],
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.people_outline),
              title: Text(context.l10n.aboutAttribution),
              subtitle: Text(context.l10n.aboutAttributionText),
            ),
            ListTile(
              leading: const Icon(Icons.code),
              title: Text(context.l10n.aboutSource),
              subtitle: const Text('github.com/$updateRepository'),
              // The row opens the repository; copying the URL is the
              // secondary trailing action (settings action row, not a
              // navigation row).
              onTap: _openSourceRepository,
              trailing: IconButton(
                icon: const Icon(Icons.copy_outlined),
                tooltip: context.l10n.copy,
                onPressed: _copySourceUrl,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.bug_report_outlined),
              title: Text(context.l10n.aboutExportLogs),
              onTap: () => _exportCrashLog(context),
            ),
            // Read-back of the display mode the engine actually got —
            // OEM ROMs (MIUI/HyperOS, ColorOS) can keep a third-party app at
            // 60Hz despite the preferred-mode request, which looks exactly
            // like a uniform low-fps app. This is the only user-visible way
            // to check it without adb.
            if (Platform.isAndroid)
              FutureBuilder<DisplayMode>(
                future: FlutterDisplayMode.active,
                builder: (context, snapshot) => ListTile(
                  leading: const Icon(Icons.speed_outlined),
                  title: Text(context.l10n.aboutDisplayRefreshRate),
                  trailing: Text(
                    snapshot.hasData
                        ? '${snapshot.data!.refreshRate.toStringAsFixed(0)} Hz'
                        : '—',
                  ),
                ),
              ),
            const Divider(),
            updateService.when(
              loading: () => ListTile(
                leading: const Icon(Icons.system_update_outlined),
                title: Text(context.l10n.aboutCheckUpdate),
                subtitle: Text(context.l10n.aboutCheckingUpdate),
              ),
              error: (_, _) => ListTile(
                leading: const Icon(Icons.warning_amber_outlined),
                title: Text(context.l10n.aboutCheckUpdate),
                subtitle: Text(context.l10n.aboutUpdateUnavailable),
              ),
              data: (service) => _AboutUpdateSection(service: service),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _exportCrashLog(BuildContext context) async {
  final directory = await getApplicationSupportDirectory();
  final file = CrashLog.fileFor(directory);
  final hasLog = await file.exists() && await file.length() > 0;
  if (!context.mounted) return;
  if (!hasLog) {
    showAppSnackBar(context, context.l10n.aboutNoLogs);
    return;
  }
  await SharePlus.instance.share(
    ShareParams(files: [XFile(file.path)], subject: 'pixiv-func-crash.log'),
  );
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
  }

  @override
  void didUpdateWidget(covariant _AboutUpdateSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.service, widget.service)) {
      _capability = widget.service.capability();
      _checkResult = null;
      _applyResult = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<UpdateCapability>(
      future: _capability,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return ListTile(
            leading: const Icon(Icons.system_update_outlined),
            title: Text(context.l10n.aboutCheckUpdate),
            subtitle: Text(context.l10n.aboutCheckingUpdate),
          );
        }
        final capability = snapshot.data;
        if (snapshot.hasError || capability == null) {
          return ListTile(
            leading: const Icon(Icons.warning_amber_outlined),
            title: Text(context.l10n.aboutCheckUpdate),
            subtitle: Text(context.l10n.aboutUpdateUnavailable),
          );
        }
        if (capability.storeManaged ||
            capability.flavor == UpdateFlavor.fdroid) {
          return ListTile(
            leading: const Icon(Icons.store_outlined),
            title: Text(context.l10n.aboutCheckUpdate),
            subtitle: Text(context.l10n.aboutUpdateStore),
          );
        }
        if (!capability.enabled) {
          return ListTile(
            leading: const Icon(Icons.warning_amber_outlined),
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
      UpdateCheckStatus.available =>
        '${context.l10n.aboutUpdateAvailable}: ${release!.manifest.version}',
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.system_update_outlined),
            title: Text(context.l10n.aboutCheckUpdate),
            subtitle: Text(
              _checking
                  ? context.l10n.aboutCheckingUpdate
                  : _applying
                  ? context.l10n.aboutUpdateDownloading
                  : statusText ?? '',
            ),
          ),
          if (_checking || _applying) const LinearProgressIndicator(),
          if (applyText != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(applyText),
            ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _checking
                ? null
                : _applying
                ? _cancelApply
                : release == null
                ? _check
                : () => _confirmAndApply(context, release),
            icon: Icon(
              _applying
                  ? Icons.close
                  : release == null
                  ? Icons.refresh
                  : Icons.download_outlined,
            ),
            label: Text(
              _applying
                  ? context.l10n.cancel
                  : release == null
                  ? context.l10n.aboutCheckUpdate
                  : context.l10n.aboutUpdateDownload,
            ),
          ),
        ],
      ),
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
      builder: (context) => AlertDialog(
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
