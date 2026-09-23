import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/motion/app_overlays.dart';
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
  bool _busy = false;
  bool _clearing = false;
  String? _status;
  bool _statusIsError = false;

  /// Pristine snapshot of what the secure store last committed (or the
  /// empty form). While a controller diverges the page is dirty and
  /// leaving asks to discard the draft instead of dropping it silently.
  List<String> _pristine = const [];

  List<TextEditingController> get _controllers => widget.baidu
      ? [_appIdController, _secretController]
      : [_baseUrlController, _apiKeyController, _modelController];

  List<String> _snapshot() => [for (final c in _controllers) c.text];

  bool get _dirty {
    for (var i = 0; i < _controllers.length; i++) {
      if (_controllers[i].text != _pristine[i]) return true;
    }
    return false;
  }

  void _onFieldChanged() {
    // Keep `_dirty` (and therefore PopScope's canPop) current on every
    // keystroke.
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _pristine = List.filled(_controllers.length, '');
    for (final controller in _controllers) {
      controller.addListener(_onFieldChanged);
    }
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
      if (mounted) _pristine = _snapshot();
    } on Object {
      if (mounted) {
        setState(() {
          _status = context.l10n.translateCredentialsStoreError;
          _statusIsError = true;
        });
      }
    }
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _clearing = false;
      _status = null;
      _statusIsError = false;
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
        setState(() {
          _pristine = _snapshot();
          _status = context.l10n.translateCredentialsSaved;
          _statusIsError = false;
        });
      }
    } on CommentTranslationError {
      if (mounted) {
        setState(() {
          _status = context.l10n.translateCredentialsInvalid;
          _statusIsError = true;
        });
      }
    } on TranslationCredentialsStoreException {
      if (mounted) {
        setState(() {
          _status = context.l10n.translateCredentialsStoreError;
          _statusIsError = true;
        });
      }
    } on Object {
      if (mounted) {
        setState(() {
          _status = context.l10n.translateCredentialsStoreError;
          _statusIsError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clear() async {
    if (_busy) return;
    // Destructive-lite: the stored secret is gone for good and must be
    // re-entered before translation works again, so it asks first.
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.l10n.translateCredentialsClear),
        content: Text(context.l10n.translateCredentialsClearConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(context.l10n.translateCredentialsClear),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _clearing = true;
      _status = null;
      _statusIsError = false;
    });
    try {
      final store = ref.read(translationCredentialStoreProvider);
      if (widget.baidu) {
        await store.deleteBaidu();
      } else {
        await store.deleteLlm();
      }
      if (mounted) {
        // The stored row is gone, so the form must not keep showing the
        // deleted values as if they were still configured.
        if (widget.baidu) {
          _appIdController.clear();
          _secretController.clear();
        } else {
          _baseUrlController.clear();
          _apiKeyController.clear();
          _modelController.clear();
        }
        setState(() {
          _pristine = _snapshot();
          _status = context.l10n.translateCredentialsCleared;
          _statusIsError = false;
        });
      }
    } on TranslationCredentialsStoreException {
      // The delete failed — keep the entered values so the user can
      // retry or copy them out instead of losing input.
      if (mounted) {
        setState(() {
          _status = context.l10n.translateCredentialsStoreError;
          _statusIsError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return guardDraft(
      dirty: _dirty,
      child: Scaffold(
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
        body: settingsNarrowBody(
          ListView(
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
                    style: TextStyle(
                      color: _statusIsError
                          ? Theme.of(context).colorScheme.error
                          : Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
              FilledButton.icon(
                onPressed: _busy ? null : _save,
                icon: _busy && !_clearing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined),
                label: Text(context.l10n.translateCredentialsSave),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _busy ? null : _clear,
                icon: _busy && _clearing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.delete_outline),
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
        ),
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
