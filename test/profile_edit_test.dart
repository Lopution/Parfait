import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/auth/account.dart';
import 'package:pixiv_func/core/auth/account_repository.dart';
import 'package:pixiv_func/core/auth/account_store.dart';
import 'package:pixiv_func/core/auth/credential.dart';
import 'package:pixiv_func/core/auth/credential_store.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:pixiv_func/core/profile/profile_edit_controller.dart';
import 'package:pixiv_func/core/profile/profile_edit_models.dart';
import 'package:pixiv_func/core/profile/profile_edit_store_bridge.dart';
import 'package:pixiv_func/core/profile/profile_image.dart';
import 'package:pixiv_func/core/reverse_image/image_input.dart';
import 'package:pixiv_func/core/reverse_image/reverse_image_platform.dart';
import 'package:pixiv_func/core/user/user_entity.dart';
import 'package:pixiv_func/core/user/user_store.dart';
import 'package:pixiv_func/features/profile/profile_edit_page.dart';

void main() {
  test('builds a minimal patch from dirty supported fields only', () {
    final user = _user();
    final capabilities = ProfileCapabilities(
      editableFields: {
        ProfileField.displayName,
        ProfileField.comment,
        ProfileField.avatar,
      },
      channel: ProfileEditChannel.appApi,
    );
    final draft =
        ProfileDraft.fromUser(
          accountId: '42',
          credentialRevision: 7,
          user: user,
          capabilities: capabilities,
        ).copyWith(
          values: ProfileValues.fromUser(
            user,
          ).copyWith(displayName: 'New name', comment: 'New bio'),
          avatar: ProfileImageSelection(
            path: '/private/profile-avatar.png',
            mimeType: 'image/png',
            sizeBytes: 128,
            width: 320,
            height: 320,
          ),
        );

    final patch = draft.buildPatch();

    expect(patch.textFields, {
      ProfileField.displayName: 'New name',
      ProfileField.comment: 'New bio',
    });
    expect(patch.images.keys, {ProfileField.avatar});
    expect(patch.toWireFields(), {'name': 'New name', 'comment': 'New bio'});
    expect(patch.toString(), isNot(contains('/private/profile-avatar.png')));
  });

  test('validates bounded text and safe web page values', () {
    final values = ProfileValues(
      displayName: 'x' * (ProfileTextLimits.maxDisplayNameLength + 1),
      comment: 'ok',
      webpage: 'javascript:alert(1)',
    );

    final errors = ProfileTextValidator.validate(values);

    expect(errors[ProfileField.displayName], isNotNull);
    expect(errors[ProfileField.webpage], isNotNull);
  });

  test('verification pending never commits effective user metadata', () async {
    final repository = _FakeRepository(
      capabilities: ProfileCapabilities(
        editableFields: {ProfileField.displayName},
        channel: ProfileEditChannel.appApi,
        verification: ProfileVerificationRequirement.emailConfirmation,
      ),
      outcome: ProfileEditVerificationPending(
        fields: {ProfileField.displayName},
        message: 'email confirmation required',
      ),
    );
    var committed = 0;
    final controller = ProfileEditController(
      repository: repository,
      owner: _owner(),
      readOwner: () => _owner(),
      initialUser: _user(),
      onConfirmed: (_) async => committed++,
    );
    addTearDown(controller.dispose);

    await controller.load();
    controller.updateText(ProfileField.displayName, 'pending name');
    await controller.submit();

    expect(controller.state.status, ProfileEditStatus.verificationPending);
    expect(committed, 0);
    expect(controller.state.draft!.base.displayName, 'old name');
    expect(controller.state.draft!.values.displayName, 'pending name');
  });

  test('confirmed response commits only after the ownership check', () async {
    final changed = _user().copyWith(name: 'confirmed name');
    final repository = _FakeRepository(
      capabilities: ProfileCapabilities(
        editableFields: {ProfileField.displayName},
        channel: ProfileEditChannel.appApi,
      ),
      outcome: ProfileEditConfirmed(changed),
    );
    UserEntity? committed;
    final controller = ProfileEditController(
      repository: repository,
      owner: _owner(),
      readOwner: () => _owner(),
      initialUser: _user(),
      onConfirmed: (user) async => committed = user,
    );
    addTearDown(controller.dispose);

    await controller.load();
    controller.updateText(ProfileField.displayName, 'confirmed name');
    await controller.submit();

    expect(controller.state.status, ProfileEditStatus.confirmed);
    expect(committed?.name, 'confirmed name');
    expect(repository.requests.single.patch.textFields, {
      ProfileField.displayName: 'confirmed name',
    });
  });

  test('late confirmed response after account switch cannot commit', () async {
    final response = Completer<ProfileEditOutcome>();
    final repository = _FakeRepository(
      capabilities: ProfileCapabilities(
        editableFields: {ProfileField.displayName},
        channel: ProfileEditChannel.appApi,
      ),
      deferredOutcome: response,
    );
    var active = _owner();
    var committed = 0;
    final controller = ProfileEditController(
      repository: repository,
      owner: active,
      readOwner: () => active,
      initialUser: _user(),
      onConfirmed: (_) async => committed++,
    );
    addTearDown(controller.dispose);

    await controller.load();
    controller.updateText(ProfileField.displayName, 'account A');
    final submit = controller.submit();
    active = const ProfileEditOwner(
      accountId: 'account-b',
      credentialRevision: 8,
    );
    response.complete(ProfileEditConfirmed(_user().copyWith(name: 'wrong')));
    await submit;

    expect(controller.state.status, ProfileEditStatus.failure);
    expect(controller.state.failure?.code, ProfileEditFailureCode.staleOwner);
    expect(committed, 0);
  });

  test(
    'current password is cleared from the submit request lifecycle',
    () async {
      final repository = _FakeRepository(
        capabilities: ProfileCapabilities(
          editableFields: {ProfileField.displayName},
          channel: ProfileEditChannel.appApi,
          requiresCurrentPassword: true,
        ),
        outcome: ProfileEditConfirmed(_user().copyWith(name: 'saved')),
      );
      final controller = ProfileEditController(
        repository: repository,
        owner: _owner(),
        readOwner: () => _owner(),
        initialUser: _user(),
        onConfirmed: (_) async {},
      );
      addTearDown(controller.dispose);

      await controller.load();
      controller.updateText(ProfileField.displayName, 'saved');
      await controller.submit(currentPassword: 'do-not-log-me');

      final request = repository.requests.single;
      expect(request.currentPassword, isNull);
      expect(request.toString(), isNot(contains('do-not-log-me')));
      expect(
        controller.state.draft.toString(),
        isNot(contains('do-not-log-me')),
      );
    },
  );

  test(
    'unsupported dirty fields stay visible and never reach the repository',
    () async {
      final repository = _FakeRepository(
        capabilities: ProfileCapabilities(
          editableFields: {ProfileField.displayName},
          channel: ProfileEditChannel.appApi,
        ),
        outcome: ProfileEditConfirmed(_user()),
      );
      final controller = ProfileEditController(
        repository: repository,
        owner: _owner(),
        readOwner: () => _owner(),
        initialUser: _user(),
        onConfirmed: (_) async {},
      );
      addTearDown(controller.dispose);

      await controller.load();
      controller.updateText(ProfileField.comment, 'unsupported change');
      await controller.submit();

      expect(controller.state.status, ProfileEditStatus.ready);
      expect(controller.state.fieldErrors[ProfileField.comment], isNotNull);
      expect(controller.state.draft!.values.comment, 'unsupported change');
      expect(repository.requests, isEmpty);
    },
  );

  test('cancel releases selected images and leaves no stale path', () async {
    var cleanupCount = 0;
    final repository = _FakeRepository(
      capabilities: ProfileCapabilities(
        editableFields: {ProfileField.avatar},
        channel: ProfileEditChannel.appApi,
      ),
      outcome: ProfileEditConfirmed(_user()),
    );
    final controller = ProfileEditController(
      repository: repository,
      owner: _owner(),
      readOwner: () => _owner(),
      initialUser: _user(),
      onConfirmed: (_) async {},
    );
    addTearDown(controller.dispose);

    await controller.load();
    await controller.selectImage(
      ProfileField.avatar,
      ProfileImageSelection(
        path: '/private/avatar.png',
        mimeType: 'image/png',
        sizeBytes: 128,
        width: 10,
        height: 10,
        cleanup: () async => cleanupCount++,
      ),
    );
    await controller.cancel();

    expect(controller.state.status, ProfileEditStatus.canceled);
    expect(controller.state.draft, isNull);
    expect(cleanupCount, 1);
  });

  test(
    'confirmed metadata updates AccountStore and canonical UserStore',
    () async {
      final metadata = _MemoryAccountMetadata();
      final credentials = _MemoryCredentials();
      final container = ProviderContainer(
        overrides: [
          accountMetadataRepositoryProvider.overrideWithValue(metadata),
          credentialStoreProvider.overrideWithValue(credentials),
        ],
      );
      addTearDown(container.dispose);
      await container.read(accountStoreProvider.future);
      final accountStore = container.read(accountStoreProvider.notifier);
      await accountStore.upsertAccount(
        const Account(id: 'account-a', userId: 42, name: 'old name'),
        const Credential(accessToken: 'access', refreshToken: 'refresh'),
      );
      final userStore = container.read(userStoreProvider.notifier);
      userStore.mergeAll([_user()]);

      await ProfileEditStoreCommitter(
        accountStore: accountStore,
        userStore: userStore,
      ).commit(_user().copyWith(name: 'updated name'));

      expect(
        container.read(accountStoreProvider).requireValue.current!.name,
        'updated name',
      );
      expect(userStore.get(42)!.name, 'updated name');
    },
  );

  test(
    'profile image preparation validates metadata and cleans up once',
    () async {
      final directory = await Directory.systemTemp.createTemp('profile-image-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/avatar.png')
        ..writeAsBytesSync(_pngHeader(320, 240));
      final platform = _ImagePlatform(file);

      final selection = await ProfileImagePreprocessor.prepare(
        platform: platform,
        reference: const ReverseImageInputReference(
          contentUri: 'content://picker/1',
          mimeType: 'image/png',
          sizeBytes: 128,
          hasReadUriPermission: true,
          source: ReverseImageInputSource.picker,
        ),
      );

      expect(selection.width, 320);
      expect(selection.height, 240);
      await selection.dispose();
      await selection.dispose();
      expect(platform.deletedPaths, [file.path]);
    },
  );

  testWidgets('renders beta56 field order and asks before leaving dirty form', (
    tester,
  ) async {
    final repository = _FakeRepository(
      capabilities: ProfileCapabilities(
        editableFields: ProfileField.values,
        channel: ProfileEditChannel.appApi,
      ),
      outcome: ProfileEditConfirmed(_user()),
    );
    final controller = ProfileEditController(
      repository: repository,
      owner: _owner(),
      readOwner: () => _owner(),
      initialUser: _user(),
      onConfirmed: (_) async {},
    );
    addTearDown(controller.dispose);
    await controller.load();

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en', 'US'),
        supportedLocales: const [Locale('en', 'US')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: ProfileEditPage(userId: 42, controller: controller),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Display name'), findsOneWidget);
    expect(find.text('Bio'), findsOneWidget);
    expect(find.text('Web page'), findsOneWidget);
    expect(find.text('Avatar'), findsOneWidget);
    expect(find.text('Background image'), findsOneWidget);
    expect(
      tester
          .widgetList<TextFormField>(find.byType(TextFormField))
          .map((field) => field.controller!.text),
      ['old name', 'old bio', 'https://example.com'],
    );

    await tester.enterText(find.byType(TextFormField).first, 'changed');
    await tester.tap(find.byTooltip('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Discard unsaved changes?'), findsOneWidget);
  });
}

UserEntity _user() => const UserEntity(
  id: 42,
  name: 'old name',
  account: 'old-account',
  comment: 'old bio',
  webpage: 'https://example.com',
  profileImageUrl: 'https://i.pximg.net/avatar.png',
  backgroundImageUrl: 'https://i.pximg.net/background.png',
  hasDetail: true,
);

ProfileEditOwner _owner() => const ProfileEditOwner(
  accountId: 'account-a',
  credentialRevision: 7,
);

class _FakeRepository implements ProfileEditRepository {
  _FakeRepository({
    required this.capabilities,
    this.outcome,
    this.deferredOutcome,
  });

  final ProfileCapabilities capabilities;
  final ProfileEditOutcome? outcome;
  final Completer<ProfileEditOutcome>? deferredOutcome;
  final requests = <ProfileSubmitRequest>[];

  @override
  Future<ProfileCapabilities> loadCapabilities({
    required String accountId,
    required int userId,
    CancelToken? cancelToken,
  }) async => capabilities;

  @override
  Future<UserEntity> loadDraft({
    required String accountId,
    required int userId,
    CancelToken? cancelToken,
  }) async => _user();

  @override
  Future<ProfileEditOutcome> submit(
    ProfileSubmitRequest request, {
    CancelToken? cancelToken,
  }) {
    requests.add(request);
    final deferred = deferredOutcome;
    if (deferred != null) return deferred.future;
    return Future.value(outcome!);
  }
}

class _MemoryAccountMetadata implements AccountMetadataRepository {
  List<Account> accounts = const [];
  String? currentId;

  @override
  Future<AccountMetadataSnapshot> load() async =>
      AccountMetadataSnapshot(accounts: accounts, currentId: currentId);

  @override
  Future<void> save(List<Account> next, String? nextCurrentId) async {
    accounts = List.of(next);
    currentId = nextCurrentId;
  }
}

class _MemoryCredentials implements CredentialStore {
  final values = <String, Credential>{};

  @override
  Future<Credential?> read(String accountId) async => values[accountId];

  @override
  Future<void> write(String accountId, Credential credential) async {
    values[accountId] = credential;
  }

  @override
  Future<void> delete(String accountId) async {
    values.remove(accountId);
  }
}

class _ImagePlatform implements ReverseImageInputPlatform {
  _ImagePlatform(this.file);

  final File file;
  final deletedPaths = <String>[];

  @override
  Future<String> copyToOwnedFile(ReverseImageInputReference reference) async =>
      file.path;

  @override
  Future<void> deleteOwnedFile(String path) async => deletedPaths.add(path);

  @override
  Future<ReverseImageInputReference?> pickImage() async => null;
}

List<int> _pngHeader(int width, int height) => [
  0x89,
  0x50,
  0x4e,
  0x47,
  0x0d,
  0x0a,
  0x1a,
  0x0a,
  0,
  0,
  0,
  13,
  0x49,
  0x48,
  0x44,
  0x52,
  (width >> 24) & 0xff,
  (width >> 16) & 0xff,
  (width >> 8) & 0xff,
  width & 0xff,
  (height >> 24) & 0xff,
  (height >> 16) & 0xff,
  (height >> 8) & 0xff,
  height & 0xff,
];
