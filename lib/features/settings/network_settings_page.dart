import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/motion/replica_page_route.dart';
import '../../app/widgets/settings_load_error.dart';
import '../../core/i18n/replica_strings.dart';
import '../../core/settings/app_settings.dart';
import '../../core/settings/settings_controller.dart';
import 'network_probe_page.dart';

String _networkText(BuildContext context, String key) {
  return ReplicaStrings.fromTag(
    Localizations.localeOf(context).toLanguageTag(),
    key,
  );
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${_networkText(context, 'settingsWriteFailed')}: $error',
          ),
        ),
      );
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
      appBar: AppBar(title: Text(_networkText(context, 'networkSettings'))),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              _networkText(context, 'networkModeListTitle'),
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
            title: Text(_networkText(context, 'networkProbe')),
            subtitle: Text(_networkText(context, 'networkProbeHint')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push<void>(
              ReplicaPageRoute<void>(builder: (_) => const NetworkProbePage()),
            ),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.tune),
            title: Text(_networkText(context, 'networkAdvanced')),
            subtitle: Text(_networkText(context, 'networkAdvancedHint')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push<void>(
              ReplicaPageRoute<void>(
                builder: (_) => const _NetworkAdvancedSettingsPage(),
              ),
            ),
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
          ? _networkText(context, 'networkModeAutomatic')
          : _networkText(context, 'networkModeDirectOnly'),
    ),
    subtitle: Text(
      value == NetworkMode.automatic
          ? _networkText(context, 'networkModeAutomaticHint')
          : _networkText(context, 'networkModeDirectOnlyHint'),
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
class _NetworkAdvancedSettingsPage extends ConsumerStatefulWidget {
  const _NetworkAdvancedSettingsPage();

  @override
  ConsumerState<_NetworkAdvancedSettingsPage> createState() =>
      _NetworkAdvancedSettingsPageState();
}

class _NetworkAdvancedSettingsPageState
    extends ConsumerState<_NetworkAdvancedSettingsPage> {
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_networkText(context, 'networkDohEndpointsInvalid')),
          ),
        );
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_networkText(context, 'saved'))));
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_networkText(context, 'networkEchHostInvalid')),
          ),
        );
      }
      return;
    }
    final saved = await _persistNetwork(
      context,
      () => ref.read(settingsProvider.notifier).setEchFrontHost(value),
    );
    if (saved && mounted) {
      setState(() => _echHostDirty = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_networkText(context, 'saved'))));
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_networkText(context, 'saved'))));
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
      appBar: AppBar(title: Text(_networkText(context, 'networkAdvanced'))),
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
                labelText: _networkText(context, 'networkDohEndpoints'),
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
                child: Text(_networkText(context, 'save')),
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
                labelText: _networkText(context, 'networkEchFrontHost'),
                helperText: _networkText(context, 'networkEchFrontHostHint'),
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
                child: Text(_networkText(context, 'save')),
              ),
            ),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.restart_alt),
            title: Text(_networkText(context, 'networkAdvancedReset')),
            onTap: _resetDefaults,
          ),
        ],
      ),
    );
  }
}
