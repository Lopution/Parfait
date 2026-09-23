import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/motion/app_overlays.dart';
import '../../app/widgets/feed/feed_states.dart';
import '../../app/widgets/settings_load_error.dart';
import '../../core/network/compat/network_contracts.dart' show NetworkRouteKind;
import '../../core/network/compat/network_providers.dart';
import '../../core/settings/app_settings.dart';
import '../../core/settings/settings_controller.dart';
import '../../app/widgets/app_snack_bar.dart';
import '../../l10n/context.dart';
import '../../l10n/lookup.dart';
import 'settings_helpers.dart';

String _networkText(BuildContext context, String key) {
  return l10nLookup(context.l10n, key);
}

Widget _networkUnavailable(
  BuildContext context,
  WidgetRef ref,
  AsyncValue<AppSettings> state, {
  required String titleKey,
}) {
  return Scaffold(
    appBar: AppBar(title: Text(_networkText(context, titleKey))),
    body: state.when(
      loading: () => const FeedLoading(),
      error: (error, _) => SettingsLoadError(
        error: error,
        onRetry: () => ref.read(settingsProvider.notifier).reload(),
      ),
      data: (_) => const SizedBox.shrink(),
    ),
  );
}

/// D3 network settings: the normal page only exposes network mode, the
/// probe entry and the advanced page. Implementation nouns (DoH/ECH/SNI)
/// live on the advanced page, not here.
class NetworkSettingsPage extends ConsumerWidget {
  const NetworkSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(settingsProvider);
    final settings = state.value;
    if (settings == null) {
      return _networkUnavailable(
        context,
        ref,
        state,
        titleKey: 'networkSettings',
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.networkSettings)),
      body: settingsNarrowBody(
        ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(
                context.l10n.networkModeListTitle,
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            _modeTile(
              context,
              settings.networkMode,
              NetworkMode.automatic,
              () => ref
                  .read(settingsProvider.notifier)
                  .setNetworkMode(NetworkMode.automatic),
            ),
            _modeTile(
              context,
              settings.networkMode,
              NetworkMode.compatPrefer,
              () => ref
                  .read(settingsProvider.notifier)
                  .setNetworkMode(NetworkMode.compatPrefer),
            ),
            _modeTile(
              context,
              settings.networkMode,
              NetworkMode.directOnly,
              () => ref
                  .read(settingsProvider.notifier)
                  .setNetworkMode(NetworkMode.directOnly),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.network_check),
              title: Text(context.l10n.networkProbe),
              subtitle: Text(context.l10n.networkProbeHint),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push<void>('/settings/network/probe'),
            ),
            const Divider(),
            const _ThirdPartyReachabilitySection(),
            const Divider(),
            const _EffectiveRoutesSection(),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.tune),
              title: Text(context.l10n.networkAdvanced),
              subtitle: Text(context.l10n.networkAdvancedHint),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push<void>('/settings/network/advanced'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Common mode tile: selected mode renders the check icon (project style;
/// RadioListTile is deprecated on this Flutter version).
Widget _modeTile(
  BuildContext context,
  NetworkMode current,
  NetworkMode value,
  Future<void> Function() action,
) {
  final selected = current == value;
  return ListTile(
    title: Text(switch (value) {
      NetworkMode.automatic => context.l10n.networkModeAutomatic,
      NetworkMode.compatPrefer => context.l10n.networkModeCompatPrefer,
      NetworkMode.directOnly => context.l10n.networkModeDirectOnly,
    }),
    subtitle: Text(switch (value) {
      NetworkMode.automatic => context.l10n.networkModeAutomaticHint,
      NetworkMode.compatPrefer => context.l10n.networkModeCompatPreferHint,
      NetworkMode.directOnly => context.l10n.networkModeDirectOnlyHint,
    }),
    trailing: selected
        ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary)
        : null,
    onTap: () => persistSettings(context, action),
  );
}

/// Advanced network settings: implementation-level knobs for power users.
/// Only DoH endpoint override, ECH front host and reset-to-default survive
/// after C17 removed the global insecure switch and C16 removed the native
/// login WebView intercept.
class NetworkAdvancedSettingsPage extends ConsumerStatefulWidget {
  const NetworkAdvancedSettingsPage({super.key});

  @override
  ConsumerState<NetworkAdvancedSettingsPage> createState() =>
      _NetworkAdvancedSettingsPageState();
}

class _NetworkAdvancedSettingsPageState
    extends ConsumerState<NetworkAdvancedSettingsPage> {
  late final TextEditingController _dohController;
  late final FocusNode _dohFocusNode;
  bool _dohDirty = false;
  late final TextEditingController _echHostController;
  late final FocusNode _echHostFocusNode;
  bool _echHostDirty = false;

  @override
  void initState() {
    super.initState();
    _dohController = TextEditingController();
    _dohFocusNode = FocusNode();
    _echHostController = TextEditingController();
    _echHostFocusNode = FocusNode();
  }

  @override
  void dispose() {
    _dohController.dispose();
    _dohFocusNode.dispose();
    _echHostController.dispose();
    _echHostFocusNode.dispose();
    super.dispose();
  }

  bool get _dirty => _dohDirty || _echHostDirty;

  /// Page-level draft: one Save commits whichever of the two fields changed.
  /// Every dirty field validates before any write, so an invalid entry never
  /// silently blocks (or partially commits alongside) the other field.
  Future<void> _saveAll() async {
    final dohValue = _dohController.text.trim();
    if (_dohDirty && dohValue.isNotEmpty && !_validEndpointList(dohValue)) {
      showAppSnackBar(context, context.l10n.networkDohEndpointsInvalid);
      return;
    }
    final echValue = _echHostController.text.trim();
    if (_echHostDirty &&
        echValue.isNotEmpty &&
        !RegExp(r'^[a-zA-Z0-9.-]+$').hasMatch(echValue)) {
      showAppSnackBar(context, context.l10n.networkEchHostInvalid);
      return;
    }
    final saved = await persistSettings(context, () async {
      if (_dohDirty) {
        await ref
            .read(settingsProvider.notifier)
            .setDohEndpointOverride(dohValue.isEmpty ? null : dohValue);
      }
      if (_echHostDirty) {
        await ref.read(settingsProvider.notifier).setEchFrontHost(echValue);
      }
    });
    if (saved && mounted) {
      setState(() {
        _dohDirty = false;
        _echHostDirty = false;
      });
      showAppSnackBar(context, context.l10n.saved);
    }
  }

  static bool _validEndpointList(String value) {
    final entries = value
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (entries.isEmpty) return false;
    for (final entry in entries) {
      final uri = Uri.tryParse(entry);
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.host.isEmpty ||
          // IP-literal or hostname: IP-literal endpoints keep the
          // certificate's iPAddress SAN; hostname endpoints go through
          // the static anycast override (defaults) or their own DNS.
          !RegExp(r'^[a-zA-Z0-9.-]+$').hasMatch(uri.host)) {
        return false;
      }
    }
    return true;
  }

  /// Resetting rewrites two stored fields at once, so it asks first —
  /// destructive-lite like the credentials clear.
  Future<void> _resetDefaults() async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.l10n.networkAdvancedReset),
        content: Text(context.l10n.networkAdvancedResetConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(context.l10n.networkAdvancedReset),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final saved = await persistSettings(context, () async {
      await ref.read(settingsProvider.notifier).setDohEnabled(true);
      await ref.read(settingsProvider.notifier).setDohEndpointOverride(null);
      await ref
          .read(settingsProvider.notifier)
          .setEchFrontHost(AppSettings.defaultEchFrontHost);
    });
    if (saved && mounted) {
      _dohController.text = ref.read(dohEndpointsProvider).join(', ');
      _echHostController.text = AppSettings.defaultEchFrontHost;
      setState(() {
        _dohDirty = false;
        _echHostDirty = false;
      });
      showAppSnackBar(context, context.l10n.saved);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(settingsProvider);
    final settings = state.value;
    if (settings == null) {
      return _networkUnavailable(
        context,
        ref,
        state,
        titleKey: 'networkAdvanced',
      );
    }
    final endpoints = ref.watch(dohEndpointsProvider).join(', ');
    if (!_dohDirty && _dohController.text != endpoints) {
      _dohController.text = endpoints;
    }
    final echHost = settings.echFrontHost;
    if (!_echHostDirty && _echHostController.text != echHost) {
      _echHostController.text = echHost;
    }
    return guardDraft(
      dirty: _dirty,
      child: Scaffold(
        appBar: AppBar(title: Text(context.l10n.networkAdvanced)),
        body: settingsNarrowBody(
          ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: TextField(
                  controller: _dohController,
                  focusNode: _dohFocusNode,
                  maxLines: 2,
                  decoration: InputDecoration(
                    labelText: context.l10n.networkDohEndpoints,
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (_) => setState(() => _dohDirty = true),
                ),
              ),
              const Divider(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: TextField(
                  controller: _echHostController,
                  focusNode: _echHostFocusNode,
                  decoration: InputDecoration(
                    labelText: context.l10n.networkEchFrontHost,
                    helperText: context.l10n.networkEchFrontHostHint,
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (_) => setState(() => _echHostDirty = true),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.tonal(
                    onPressed: _dirty ? _saveAll : null,
                    child: Text(context.l10n.save),
                  ),
                ),
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.restart_alt),
                title: Text(context.l10n.networkAdvancedReset),
                onTap: _resetDefaults,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Per-host route kinds the ladder has settled on for this network
/// identity. Not reactive — route memory changes mid-request — so the
/// section snapshots on build and refreshes on demand.
class _EffectiveRoutesSection extends ConsumerStatefulWidget {
  const _EffectiveRoutesSection();

  @override
  ConsumerState<_EffectiveRoutesSection> createState() =>
      _EffectiveRoutesSectionState();
}

class _EffectiveRoutesSectionState
    extends ConsumerState<_EffectiveRoutesSection> {
  Map<String, NetworkRouteKind> _routes = const {};

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    setState(() {
      _routes = ref.read(networkAccessPolicyProvider).effectiveRouteSnapshot();
    });
  }

  String _kindLabel(BuildContext context, NetworkRouteKind kind) {
    return switch (kind) {
      NetworkRouteKind.direct => context.l10n.networkRouteKindDirect,
      NetworkRouteKind.ech => context.l10n.networkProbeStepEch,
      NetworkRouteKind.dohRealSni => context.l10n.networkProbeStepDoh,
      NetworkRouteKind.noSni => context.l10n.networkProbeStepNoSni,
      NetworkRouteKind.insecureNoSni => context.l10n.networkRouteKindCompat,
    };
  }

  @override
  Widget build(BuildContext context) {
    final entries = _routes.entries.toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  context.l10n.networkEffectiveRoutes,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.refresh, size: 20),
                tooltip: context.l10n.refresh,
                onPressed: _refresh,
              ),
            ],
          ),
        ),
        if (entries.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              context.l10n.networkEffectiveRoutesEmpty,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          )
        else
          for (final entry in entries)
            ListTile(
              dense: true,
              title: Text(entry.key),
              trailing: Text(
                _kindLabel(context, entry.value),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
      ],
    );
  }
}

/// Reachability of the app's third-party exits (reverse-image engines,
/// translation). These go through ordinary system routing — a user
/// VPN/TUN applies — and deliberately never touch the Pixiv ladder.
class _ThirdPartyReachabilitySection extends StatefulWidget {
  const _ThirdPartyReachabilitySection();

  @override
  State<_ThirdPartyReachabilitySection> createState() =>
      _ThirdPartyReachabilitySectionState();
}

enum _Reachability { checking, reachable, unreachable }

class _ThirdPartyReachabilitySectionState
    extends State<_ThirdPartyReachabilitySection> {
  static const _targets = {
    'SauceNAO': 'saucenao.com',
    'ascii2d': 'ascii2d.net',
    'Google Translate': 'translate.googleapis.com',
  };

  static const _timeout = Duration(seconds: 5);

  final Map<String, _Reachability> _status = {
    for (final name in _targets.keys) name: _Reachability.checking,
  };

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    setState(() {
      for (final name in _targets.keys) {
        _status[name] = _Reachability.checking;
      }
    });
    await Future.wait(
      _targets.entries.map((entry) async {
        final client = http.Client();
        var result = _Reachability.unreachable;
        try {
          // Any HTTP status — even an error page — proves reachability;
          // the probe measures transport, not service health.
          await client.head(Uri.https(entry.value, '/')).timeout(_timeout);
          result = _Reachability.reachable;
        } on Object {
          // unreachable
        } finally {
          client.close();
        }
        if (mounted) setState(() => _status[entry.key] = result);
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  context.l10n.networkThirdParty,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.refresh, size: 20),
                tooltip: context.l10n.refresh,
                onPressed: _check,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // D7: the check still fires on page entry; the note tells the
              // user so the "checking" state is not mistaken for a manual tap.
              Text(
                context.l10n.networkThirdPartyAuto,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              Text(
                context.l10n.networkThirdPartyHint,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        for (final entry in _targets.entries)
          ListTile(
            dense: true,
            title: Text(entry.key),
            subtitle: Text(entry.value),
            trailing: switch (_status[entry.key]) {
              _Reachability.checking || null => Text(
                context.l10n.networkChecking,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              _Reachability.reachable => Text(
                context.l10n.networkReachable,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
              _Reachability.unreachable => Text(
                context.l10n.networkUnreachable,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            },
          ),
      ],
    );
  }
}
