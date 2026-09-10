import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/comments/comment_translation.dart';
import '../../../core/comments/translation_credentials.dart';
import '../../../l10n/context.dart';
import '../settings_helpers.dart';

class TranslationCredentialsPage extends ConsumerStatefulWidget {
  const TranslationCredentialsPage({super.key, required this.baidu});

  final bool baidu;

  @override
  ConsumerState<TranslationCredentialsPage> createState() =>
      _TranslationCredentialsPageState();
}

class _TranslationCredentialsPageState
    extends ConsumerState<TranslationCredentialsPage> {
  final _appIdController = TextEditingController();
  final _secretController = TextEditingController();
  final _baseUrlController = TextEditingController();
  final _apiKeyController = TextEditingController();
  final _modelController = TextEditingController();
  bool _saving = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _appIdController.dispose();
    _secretController.dispose();
    _baseUrlController.dispose();
    _apiKeyController.dispose();
    _modelController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final store = ref.read(translationCredentialStoreProvider);
      if (widget.baidu) {
        final credentials = await store.readBaidu();
        if (credentials != null && mounted) {
          // Re-fill the form so a user can verify what is stored. Secret
          // values are filled into the obscured field only; they are never
          // rendered in status messages.
          _appIdController.text = credentials.appId;
          _secretController.text = credentials.secret;
        }
      } else {
        final credentials = await store.readLlm();
        if (credentials != null && mounted) {
          _baseUrlController.text = credentials.baseUrl;
          _apiKeyController.text = credentials.apiKey;
          _modelController.text = credentials.model ?? '';
        }
      }
    } on Object {
      if (mounted) {
        setState(() => _status = context.l10n.translateCredentialsStoreError);
      }
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _status = null;
    });
    try {
      final store = ref.read(translationCredentialStoreProvider);
      if (widget.baidu) {
        final appId = _appIdController.text.trim();
        final secret = _secretController.text.trim();
        if (appId.isEmpty || secret.isEmpty) {
          throw const CommentTranslationError('incomplete baidu credentials');
        }
        await store.writeBaidu(
          BaiduTranslationCredentials(appId: appId, secret: secret),
        );
      } else {
        final baseUrl = _baseUrlController.text.trim();
        final apiKey = _apiKeyController.text.trim();
        final uri = Uri.tryParse(baseUrl);
        if (baseUrl.isEmpty ||
            apiKey.isEmpty ||
            uri == null ||
            uri.scheme != 'https' ||
            uri.host.isEmpty) {
          throw const CommentTranslationError('invalid LLM endpoint');
        }
        final model = _modelController.text.trim();
        await store.writeLlm(
          LlmTranslationCredentials(
            baseUrl: baseUrl,
            apiKey: apiKey,
            model: model.isEmpty ? null : model,
          ),
        );
      }
      if (mounted) {
        setState(() => _status = context.l10n.translateCredentialsSaved);
      }
    } on CommentTranslationError {
      if (mounted) {
        setState(() => _status = context.l10n.translateCredentialsInvalid);
      }
    } on TranslationCredentialsStoreException {
      if (mounted) {
        setState(() => _status = context.l10n.translateCredentialsStoreError);
      }
    } on Object {
      if (mounted) {
        setState(() => _status = context.l10n.translateCredentialsStoreError);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _clear() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _status = null;
    });
    try {
      final store = ref.read(translationCredentialStoreProvider);
      if (widget.baidu) {
        await store.deleteBaidu();
      } else {
        await store.deleteLlm();
      }
      if (mounted) {
        setState(() {
          _status = context.l10n.translateCredentialsCleared;
        });
      }
    } on TranslationCredentialsStoreException {
      if (mounted) {
        setState(() => _status = context.l10n.translateCredentialsStoreError);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          settingsText(
            context,
            widget.baidu
                ? 'translateBaiduCredential'
                : 'translateLlmCredential',
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (widget.baidu)
            _credentialField(
              controller: _appIdController,
              label: context.l10n.translateBaiduAppId,
              obscure: false,
            )
          else
            _credentialField(
              controller: _baseUrlController,
              label: context.l10n.translateLlmBaseUrl,
              obscure: false,
              hint: 'https://api.example.com/v1',
            ),
          if (widget.baidu)
            _credentialField(
              controller: _secretController,
              label: context.l10n.translateBaiduSecret,
              obscure: true,
            )
          else
            _credentialField(
              controller: _apiKeyController,
              label: context.l10n.translateLlmApiKey,
              obscure: true,
            ),
          if (!widget.baidu)
            _credentialField(
              controller: _modelController,
              label: context.l10n.translateLlmModel,
              obscure: false,
            ),
          const SizedBox(height: 8),
          if (_status != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                _status!,
                style: TextStyle(color: Theme.of(context).colorScheme.primary),
              ),
            ),
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: const Icon(Icons.save_outlined),
            label: Text(context.l10n.translateCredentialsSave),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _saving ? null : _clear,
            icon: const Icon(Icons.delete_outline),
            label: Text(context.l10n.translateCredentialsClear),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(
              settingsText(
                context,
                widget.baidu
                    ? 'translateBaiduHint'
                    : 'translateLlmCredentialHint',
              ),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  Widget _credentialField({
    required TextEditingController controller,
    required String label,
    required bool obscure,
    String? hint,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: controller,
        obscureText: obscure,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }
}
