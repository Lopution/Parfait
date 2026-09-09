import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/widgets/settings_load_error.dart';
import '../../core/settings/app_settings.dart';
import '../../core/settings/settings_controller.dart';
import '../../app/widgets/app_snack_bar.dart';
import '../../l10n/context.dart';
import '../../l10n/lookup.dart';

String _networkText(BuildContext context, String key) {
  return l10nLookup(context.l10n, key);
}

Future<bool> _persistNetwork(
  BuildContext context,
  Future<void> Function() action,
) async {
  try {
    await action();
    return true;
  } on Object catch (error) {
    if (context.mounted) {
      showAppSnackBar(context, '${context.l10n.settingsWriteFailed}: $error');
    }
    return false;
  }
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
      loading: () => const Center(child: CircularProgressIndicator()),
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
      body: ListView(
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
          ListTile(
            leading: const Icon(Icons.tune),
            title: Text(context.l10n.networkAdvanced),
            subtitle: Text(context.l10n.networkAdvancedHint),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push<void>('/settings/network/advanced'),
          ),
        ],
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
    title: Text(
      value == NetworkMode.automatic
          ? context.l10n.networkModeAutomatic
          : context.l10n.networkModeDirectOnly,
    ),
    subtitle: Text(
      value == NetworkMode.automatic
          ? context.l10n.networkModeAutomaticHint
          : context.l10n.networkModeDirectOnlyHint,
    ),
    trailing: selected
        ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary)
        : null,
    onTap: () => _persistNetwork(context, action),
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

  Future<void> _saveEndpoints() async {
    final value = _dohController.text.trim();
    if (!_dohDirty) return;
    if (value.isNotEmpty && !_validEndpointList(value)) {
      if (mounted) {
        showAppSnackBar(context, context.l10n.networkDohEndpointsInvalid);
      }
      return;
    }
    final saved = await _persistNetwork(
      context,
      () => ref
          .read(settingsProvider.notifier)
          .setDohEndpointOverride(value.isEmpty ? null : value),
    );
    if (saved && mounted) {
      setState(() => _dohDirty = false);
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

  Future<void> _saveEchHost() async {
    final value = _echHostController.text.trim();
    if (!_echHostDirty) return;
    if (value.isNotEmpty && !RegExp(r'^[a-zA-Z0-9.-]+$').hasMatch(value)) {
      if (mounted) {
        showAppSnackBar(context, context.l10n.networkEchHostInvalid);
      }
      return;
    }
    final saved = await _persistNetwork(
      context,
      () => ref.read(settingsProvider.notifier).setEchFrontHost(value),
    );
    if (saved && mounted) {
      setState(() => _echHostDirty = false);
      showAppSnackBar(context, context.l10n.saved);
    }
  }

  Future<void> _resetDefaults() async {
    final saved = await _persistNetwork(context, () async {
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
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.networkAdvanced)),
      body: ListView(
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
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonal(
                onPressed: _saveEndpoints,
                child: Text(context.l10n.save),
              ),
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
                onPressed: _saveEchHost,
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
    );
  }
}
