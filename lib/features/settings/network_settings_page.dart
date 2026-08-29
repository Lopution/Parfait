import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/replica_page_route.dart';
import '../../core/i18n/replica_strings.dart';
import '../../core/network/compat/network_contracts.dart';
import '../../core/network/compat/network_providers.dart';
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

/// beta56-compatible network settings: direct/strict mode, DoH enablement and
/// endpoints, and the layered connectivity probe entry (Phase 1 / R2).
class NetworkSettingsPage extends ConsumerStatefulWidget {
  const NetworkSettingsPage({super.key});

  @override
  ConsumerState<NetworkSettingsPage> createState() => _NetworkSettingsPageState();
}

class _NetworkSettingsPageState extends ConsumerState<NetworkSettingsPage> {
  late final TextEditingController _dohController;
  late final FocusNode _dohFocusNode;
  bool _dohDirty = false;

  @override
  void initState() {
    super.initState();
    _dohController = TextEditingController();
    _dohFocusNode = FocusNode();
  }

  @override
  void dispose() {
    _dohController.dispose();
    _dohFocusNode.dispose();
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_networkText(context, 'saved'))),
      );
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

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider).value;
    if (settings == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final mode = ref.watch(networkAccessPolicyProvider).mode;
    final dohEnabled = settings.enableDoh;
    final endpoints = ref.watch(dohEndpointsProvider).join(', ');
    if (!_dohDirty && _dohController.text != endpoints) {
      _dohController.text = endpoints;
    }
    return Scaffold(
      appBar: AppBar(title: Text(_networkText(context, 'networkSettings'))),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          SwitchListTile(
            title: Text(_networkText(context, 'networkMode')),
            subtitle: Text(_networkText(context, 'networkModeHint')),
            value: mode == NetworkMode.automatic,
            onChanged: (value) {
              ref
                  .read(networkAccessPolicyProvider)
                  .setMode(value ? NetworkMode.automatic : NetworkMode.directOnly);
              setState(() {});
            },
          ),
          const Divider(),
          SwitchListTile(
            title: Text(_networkText(context, 'networkDoh')),
            subtitle: Text(_networkText(context, 'networkDohHint')),
            value: dohEnabled,
            onChanged: (value) => _persistNetwork(
              context,
              () => ref.read(settingsProvider.notifier).setDohEnabled(value),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              controller: _dohController,
              focusNode: _dohFocusNode,
              enabled: dohEnabled,
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
                onPressed: dohEnabled ? _saveEndpoints : null,
                child: Text(_networkText(context, 'saved')),
              ),
            ),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.network_check),
            title: Text(_networkText(context, 'networkProbe')),
            subtitle: Text(_networkText(context, 'networkProbeHint')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push<void>(
              ReplicaPageRoute<void>(
                builder: (_) => const NetworkProbePage(),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'DoH endpoints: $endpoints\n'
              'enableDoh: $dohEnabled',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}