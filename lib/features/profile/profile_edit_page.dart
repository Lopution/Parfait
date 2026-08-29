import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/pixiv_image.dart';
import '../../app/replica_page_route.dart';
import '../../core/auth/account_store.dart';
import '../../core/i18n/replica_strings.dart';
import '../../core/profile/profile_edit_controller.dart';
import '../../core/profile/profile_edit_models.dart';
import '../../core/profile/profile_edit_repository.dart';
import '../../core/profile/profile_edit_store_bridge.dart';
import '../../core/profile/profile_image.dart';
import '../../core/reverse_image/reverse_image_platform.dart';
import '../../core/user/user_entity.dart';
import '../../core/user/user_repository.dart';
import '../../core/user/user_store.dart';

String _profileEditText(BuildContext context, String key) {
  return ReplicaStrings.fromTag(
    Localizations.localeOf(context).toLanguageTag(),
    key,
  );
}

/// The current-account beta56 profile editor. The repository is injectable so
/// the form and ownership contract can be tested without changing a live
/// account; production defaults to the authenticated read-only adapter.
class ProfileEditPage extends ConsumerStatefulWidget {
  const ProfileEditPage({
    super.key,
    required this.userId,
    this.initialUser,
    this.repository,
    this.imagePlatform,
    this.controller,
  });

  final int userId;
  final UserEntity? initialUser;
  final ProfileEditRepository? repository;
  final ReverseImageInputPlatform? imagePlatform;
  final ProfileEditController? controller;

  @override
  ConsumerState<ProfileEditPage> createState() => _ProfileEditPageState();
}

class _ProfileEditPageState extends ConsumerState<ProfileEditPage> {
  ProfileEditController? _controller;
  ProviderSubscription<AsyncValue<AccountState>>? _accountSubscription;
  Object? _initializationError;
  bool _ownsController = false;

  @override
  void initState() {
    super.initState();
    _controller = widget.controller;
    if (_controller != null) return;
    _ownsController = true;
    _accountSubscription = ref.listenManual<AsyncValue<AccountState>>(
      accountStoreProvider,
      (_, _) => _controller?.checkOwner(),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_initialize());
    });
  }

  @override
  void dispose() {
    _accountSubscription?.close();
    if (_ownsController) _controller?.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    try {
      final accountState = await ref.read(accountStoreProvider.future);
      final account = accountState.usableCurrent;
      if (account == null || account.userId != widget.userId) {
        throw const ProfileEditCommitException(
          'the current account does not own this profile',
        );
      }
      final user =
          widget.initialUser ??
          ref.read(userStoreProvider)[widget.userId] ??
          await ref.read(userRepositoryProvider).fetchDetail(widget.userId);
      if (!mounted) return;
      final controller = ProfileEditController(
        repository:
            widget.repository ?? ref.read(profileEditRepositoryProvider),
        owner: _readOwner(),
        readOwner: _readOwner,
        initialUser: user,
        onConfirmed: (confirmed) => ProfileEditStoreCommitter(
          accountStore: ref.read(accountStoreProvider.notifier),
          userStore: ref.read(userStoreProvider.notifier),
        ).commit(confirmed),
      );
      setState(() => _controller = controller);
      unawaited(controller.load());
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _initializationError = error);
    }
  }

  ProfileEditOwner _readOwner() {
    final state = ref.read(accountStoreProvider).asData?.value;
    return ProfileEditOwner(
      accountId: state?.usableCurrent?.id ?? '',
      credentialRevision: state?.credentialRevision ?? -1,
    );
  }

  Future<void> _attemptPop() async {
    final controller = _controller;
    if (!mounted || controller == null || !controller.state.hasUnsavedChanges) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_profileEditText(context, 'profileEditLeaveTitle')),
        content: Text(_profileEditText(context, 'profileEditLeaveDetail')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_profileEditText(context, 'cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_profileEditText(context, 'profileEditLeaveConfirm')),
          ),
        ],
      ),
    );
    if (leave == true && mounted) {
      await controller.cancel();
      if (mounted) Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return PopScope(
      canPop: controller == null || !controller.state.hasUnsavedChanges,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_attemptPop());
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_profileEditText(context, 'profileEditTitle')),
          leading: IconButton(
            tooltip: _profileEditText(context, 'cancel'),
            onPressed: _attemptPop,
            icon: const Icon(Icons.arrow_back),
          ),
        ),
        body: controller == null
            ? _initializationError == null
                  ? const Center(child: CircularProgressIndicator())
                  : _InitializationFailure(error: _initializationError!)
            : AnimatedBuilder(
                animation: controller,
                builder: (context, _) => _ProfileEditBody(
                  controller: controller,
                  imagePlatform:
                      widget.imagePlatform ??
                      MethodChannelReverseImageInputPlatform(),
                ),
              ),
      ),
    );
  }
}

class _InitializationFailure extends StatelessWidget {
  const _InitializationFailure({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 52),
            const SizedBox(height: 12),
            Text(_profileEditText(context, 'profileEditLoadFailed')),
            const SizedBox(height: 8),
            Text('$error', textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

class _ProfileEditBody extends StatefulWidget {
  const _ProfileEditBody({
    required this.controller,
    required this.imagePlatform,
  });

  final ProfileEditController controller;
  final ReverseImageInputPlatform imagePlatform;

  @override
  State<_ProfileEditBody> createState() => _ProfileEditBodyState();
}

class _ProfileEditBodyState extends State<_ProfileEditBody> {
  late final TextEditingController _displayName;
  late final TextEditingController _comment;
  late final TextEditingController _webpage;
  late final TextEditingController _password;
  bool _textInitialized = false;

  ProfileEditController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _displayName = TextEditingController();
    _comment = TextEditingController();
    _webpage = TextEditingController();
    _password = TextEditingController();
    _controller.addListener(_onControllerChanged);
    _syncText(_controller.state.draft);
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _displayName.dispose();
    _comment.dispose();
    _webpage.dispose();
    _password.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    _syncText(_controller.state.draft);
    if (mounted) setState(() {});
  }

  void _syncText(ProfileDraft? draft) {
    if (_textInitialized || draft == null) return;
    _displayName.text = draft.values.displayName;
    _comment.text = draft.values.comment;
    _webpage.text = draft.values.webpage;
    _textInitialized = true;
  }

  Future<void> _pickImage(ProfileField field) async {
    final reference = await widget.imagePlatform.pickImage();
    if (!mounted || reference == null) return;
    ProfileImageSelection? selection;
    try {
      selection = await ProfileImagePreprocessor.prepare(
        platform: widget.imagePlatform,
        reference: reference,
      );
      await _controller.selectImage(field, selection);
    } on Object catch (error) {
      if (selection != null) await selection.dispose();
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  Future<void> _submit() async {
    await _controller.submit(
      currentPassword: _password.text.isEmpty ? null : _password.text,
    );
    _password.clear();
  }

  @override
  Widget build(BuildContext context) {
    final state = _controller.state;
    final draft = state.draft;
    if (draft == null) {
      return _StatusBody(state: state, onRetry: _controller.load);
    }
    final capabilities = draft.capabilities;
    final editingEnabled =
        capabilities.isAvailable &&
        state.status != ProfileEditStatus.submitting &&
        state.status != ProfileEditStatus.confirmed;
    return Form(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          if (!capabilities.isAvailable)
            _NoticeCard(
              icon: Icons.info_outline,
              text:
                  capabilities.reason ??
                  _profileEditText(context, 'profileEditUnavailable'),
            ),
          if (state.failure != null)
            _NoticeCard(
              icon: Icons.error_outline,
              text: state.failure!.message,
            ),
          if (state.status == ProfileEditStatus.verificationPending)
            _NoticeCard(
              icon: Icons.mark_email_unread_outlined,
              text:
                  state.verificationMessage ??
                  _profileEditText(context, 'profileEditPending'),
            ),
          if (state.status == ProfileEditStatus.confirmed)
            _NoticeCard(
              icon: Icons.check_circle_outline,
              text: _profileEditText(context, 'profileEditConfirmed'),
            ),
          TextFormField(
            controller: _displayName,
            enabled:
                editingEnabled &&
                capabilities.supports(ProfileField.displayName),
            maxLength: ProfileTextLimits.maxDisplayNameLength,
            decoration: _decoration(
              context,
              'profileEditDisplayName',
              ProfileField.displayName,
              state,
            ),
            onChanged: (value) =>
                _controller.updateText(ProfileField.displayName, value),
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _comment,
            enabled:
                editingEnabled && capabilities.supports(ProfileField.comment),
            minLines: 3,
            maxLines: 6,
            maxLength: ProfileTextLimits.maxCommentLength,
            decoration: _decoration(
              context,
              'profileEditComment',
              ProfileField.comment,
              state,
            ),
            onChanged: (value) =>
                _controller.updateText(ProfileField.comment, value),
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _webpage,
            enabled:
                editingEnabled && capabilities.supports(ProfileField.webpage),
            keyboardType: TextInputType.url,
            maxLength: ProfileTextLimits.maxWebpageLength,
            decoration: _decoration(
              context,
              'profileEditWebpage',
              ProfileField.webpage,
              state,
            ),
            onChanged: (value) =>
                _controller.updateText(ProfileField.webpage, value),
          ),
          const SizedBox(height: 8),
          _ImageField(
            title: _profileEditText(context, 'profileEditAvatar'),
            currentUrl: draft.values.avatarUrl,
            selection: draft.avatar,
            enabled:
                editingEnabled && capabilities.supports(ProfileField.avatar),
            unsupported: !capabilities.supports(ProfileField.avatar),
            onPick: () => _pickImage(ProfileField.avatar),
          ),
          const SizedBox(height: 8),
          _ImageField(
            title: _profileEditText(context, 'profileEditBackground'),
            currentUrl: draft.values.backgroundUrl,
            selection: draft.background,
            enabled:
                editingEnabled &&
                capabilities.supports(ProfileField.background),
            unsupported: !capabilities.supports(ProfileField.background),
            onPick: () => _pickImage(ProfileField.background),
          ),
          if (capabilities.requiresCurrentPassword) ...[
            const SizedBox(height: 8),
            TextField(
              controller: _password,
              enabled: editingEnabled,
              obscureText: true,
              decoration: InputDecoration(
                labelText: _profileEditText(
                  context,
                  'profileEditCurrentPassword',
                ),
                errorText: state.currentPasswordError,
              ),
            ),
          ],
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: editingEnabled ? _submit : null,
            icon: state.status == ProfileEditStatus.submitting
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
            label: Text(_profileEditText(context, 'profileEditSave')),
          ),
        ],
      ),
    );
  }

  InputDecoration _decoration(
    BuildContext context,
    String labelKey,
    ProfileField field,
    ProfileEditState state,
  ) {
    final unsupported = !_controller.state.draft!.capabilities.supports(field);
    return InputDecoration(
      labelText: _profileEditText(context, labelKey),
      errorText: state.fieldErrors[field],
      helperText: unsupported
          ? _profileEditText(context, 'profileEditFieldUnsupported')
          : null,
      alignLabelWithHint: field == ProfileField.comment,
      border: const OutlineInputBorder(),
    );
  }
}

class _ImageField extends StatelessWidget {
  const _ImageField({
    required this.title,
    required this.currentUrl,
    required this.selection,
    required this.enabled,
    required this.unsupported,
    required this.onPick,
  });

  final String title;
  final String? currentUrl;
  final ProfileImageSelection? selection;
  final bool enabled;
  final bool unsupported;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final preview = selection == null
        ? currentUrl == null || currentUrl!.isEmpty
              ? const Icon(Icons.image_outlined, size: 42)
              : PixivImage(
                  url: currentUrl!,
                  width: 54,
                  height: 54,
                  fit: BoxFit.cover,
                )
        : Image.file(
            File(selection!.path),
            width: 54,
            height: 54,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) =>
                const Icon(Icons.image_outlined, size: 42),
          );
    return Card(
      child: ListTile(
        leading: SizedBox.square(dimension: 54, child: Center(child: preview)),
        title: Text(title),
        subtitle: Text(
          unsupported
              ? _profileEditText(context, 'profileEditFieldUnsupported')
              : selection == null
              ? _profileEditText(context, 'profileEditImageChoose')
              : '${selection!.width} × ${selection!.height}',
        ),
        trailing: OutlinedButton(
          onPressed: enabled ? onPick : null,
          child: Text(_profileEditText(context, 'profileEditChooseImage')),
        ),
      ),
    );
  }
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon),
            const SizedBox(width: 10),
            Expanded(child: Text(text)),
          ],
        ),
      ),
    );
  }
}

class _StatusBody extends StatelessWidget {
  const _StatusBody({required this.state, required this.onRetry});

  final ProfileEditState state;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final failure = state.failure;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (state.status == ProfileEditStatus.loading ||
                state.status == ProfileEditStatus.submitting)
              const CircularProgressIndicator()
            else
              const Icon(Icons.info_outline, size: 52),
            const SizedBox(height: 16),
            Text(
              failure?.message ??
                  _profileEditText(context, 'profileEditLoadFailed'),
              textAlign: TextAlign.center,
            ),
            if (failure?.retryable == true) ...[
              const SizedBox(height: 16),
              FilledButton(
                onPressed: onRetry,
                child: Text(_profileEditText(context, 'retry')),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

void showProfileEditPage(BuildContext context, int userId) {
  Navigator.of(context).push<void>(
    ReplicaPageRoute<void>(builder: (_) => ProfileEditPage(userId: userId)),
  );
}
