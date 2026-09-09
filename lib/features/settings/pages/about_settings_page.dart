import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/updater/update_providers.dart';
import '../../../core/updater/update_service.dart';
import '../../../l10n/context.dart';

class AboutSettingsPage extends ConsumerWidget {
  const AboutSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appName = 'Pixiv Func';
    final updateService = ref.watch(updateServiceProvider);
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.aboutSettings)),
      body: ListView(
        children: [
          const ListTile(
            leading: Icon(Icons.apps),
            title: Text('Pixiv Func'),
            subtitle: Text('0.1.0+1'),
          ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: Text(context.l10n.aboutVersion),
            trailing: const Text('0.1.0+1'),
          ),
          ListTile(
            leading: const Icon(Icons.menu_book_outlined),
            title: Text(context.l10n.aboutLicense),
            subtitle: Text(context.l10n.aboutLicenseText),
            onTap: () => showLicensePage(
              context: context,
              applicationName: appName,
              applicationVersion: '0.1.0+1',
            ),
          ),
          ListTile(
            leading: const Icon(Icons.people_outline),
            title: Text(context.l10n.aboutAttribution),
            subtitle: Text(context.l10n.aboutAttributionText),
          ),
          ListTile(
            leading: const Icon(Icons.code),
            title: Text(context.l10n.aboutSource),
            subtitle: const Text('github.com/Lopution/Pixiv-func'),
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
    );
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
      UpdateCheckStatus.invalid ||
      UpdateCheckStatus.rateLimited ||
      UpdateCheckStatus.offline ||
      UpdateCheckStatus.failed ||
      UpdateCheckStatus.busy => context.l10n.aboutUpdateFailed,
      null => null,
    };
    final applyText = switch (_applyResult?.status) {
      UpdateApplyStatus.installPermissionRequired =>
        context.l10n.aboutUpdatePermission,
      UpdateApplyStatus.installStarted => context.l10n.aboutUpdateStarted,
      UpdateApplyStatus.failed ||
      UpdateApplyStatus.canceled => context.l10n.aboutUpdateFailed,
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
              _checking || _applying
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
    final confirmed = await showDialog<bool>(
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
