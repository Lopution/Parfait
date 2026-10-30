import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/auth/account_store.dart';
import 'package:parfait/core/auth/credential.dart';
import 'package:parfait/core/network/pixiv_http_client.dart';
import 'package:parfait/core/profile/profile_edit_controller.dart';
import 'package:parfait/core/profile/profile_edit_models.dart';
import 'package:parfait/core/profile/profile_edit_store_bridge.dart';
import 'package:parfait/core/profile/profile_image.dart';
import 'package:parfait/core/reverse_image/image_input.dart';
import 'package:parfait/core/reverse_image/reverse_image_platform.dart';
import 'package:parfait/core/network/api_error.dart';
import 'package:parfait/core/user/user_entity.dart';
import 'package:parfait/core/user/user_repository.dart';
import 'package:parfait/core/user/user_store.dart';
import 'package:parfait/features/profile/profile_edit_page.dart';

import 'helpers/fake_account.dart';
import 'helpers/localized_app.dart';
import 'helpers/prompt_host.dart';
import 'helpers/image_headers.dart';
import 'helpers/reverse_image_world.dart' show FakeReverseImagePlatform;
import 'helpers/view_size.dart';

ProfileCapabilities _appApi([
  Iterable<ProfileField> fields = ProfileField.values,
]) => ProfileCapabilities(
  editableFields: fields,
  channel: ProfileEditChannel.appApi,
);

ProfileEditSession _session(
  ProfileEditRepository repository, {
  ProfileEditOwner Function() readOwner = _owner,
  Future<void> Function(UserEntity user)? onConfirmed,
}) => ProfileEditSession(
  repository: repository,
  owner: _owner(),
  readOwner: readOwner,
  initialUser: _user(),
  onConfirmed: onConfirmed ?? (_) async {},
);

/// A container whose profile editor runs the real controller.
ProviderContainer _editorContainer() {
  final container = ProviderContainer.test(
    overrides: [
      profileEditControllerProvider.overrideWith2(
        (arguments) => ProfileEditController(arguments),
      ),
    ],
  );
  return container;
}

/// [session]'s controller after its first load.
Future<ProfileEditController> _loaded(
  ProfileEditSession session, [
  ProviderContainer? container,
]) async {
  final controller = (container ?? _editorContainer()).read(
    profileEditControllerProvider(session).notifier,
  );
  await controller.load();
  return controller;
}

/// A container signed in to account 42, as the page finds it in production.
Future<ProviderContainer> _signedInContainer([
  List<Override> overrides = const [],
]) async {
  await seedAccounts([
    const Account(id: '42', userId: 42, name: 'tester'),
  ], currentId: '42');
  final container = ProviderContainer.test(
    overrides: [
      ...accountProviderOverrides(
        credentialStore: FakeCredentialStore(
          values: const {'42': Credential(accessToken: 'a', refreshToken: 'r')},
        ),
      ),
      ...overrides,
    ],
  );
  return container;
}

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

  test('confirmed response commits only after the ownership check', () async {
    final changed = _user().copyWith(name: 'confirmed name');
    final repository = _FakeRepository(
      _appApi({ProfileField.displayName}),
      outcome: ProfileEditConfirmed(changed),
    );
    UserEntity? committed;
    final session = _session(
      repository,
      onConfirmed: (user) async => committed = user,
    );
    final controller = await _loaded(session);

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
      _appApi({ProfileField.displayName}),
      deferredOutcome: response,
    );
    var active = _owner();
    var committed = 0;
    final session = _session(
      repository,
      readOwner: () => active,
      onConfirmed: (_) async => committed++,
    );
    final controller = await _loaded(session);

    controller.updateText(ProfileField.displayName, 'account A');
    final submit = controller.submit();
    active = const ProfileEditOwner(accountId: 'account-b');
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
        ProfileCapabilities(
          editableFields: {ProfileField.displayName},
          channel: ProfileEditChannel.appApi,
          requiresCurrentPassword: true,
        ),
        outcome: ProfileEditConfirmed(_user().copyWith(name: 'saved')),
      );
      final session = _session(repository);
      final controller = await _loaded(session);

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
      final repository = _FakeRepository(_appApi({ProfileField.displayName}));
      final session = _session(repository);
      final controller = await _loaded(session);

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
    final repository = _FakeRepository(_appApi({ProfileField.avatar}));
    final session = _session(repository);
    final controller = await _loaded(session);

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
      final credentials = FakeCredentialStore();
      final container = ProviderContainer.test(
        overrides: [credentialStoreProvider.overrideWithValue(credentials)],
      );
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

      // A switch landing during the save keeps A's profile out of B's
      // store; A's card still takes it.
      await accountStore.upsertAccount(
        const Account(id: 'account-b', userId: 7, name: 'b'),
        const Credential(accessToken: 'b', refreshToken: 'b'),
      );
      await accountStore.switchAccount('account-a');
      final commit = ProfileEditStoreCommitter(
        accountStore: accountStore,
        userStore: userStore,
      ).commit(_user().copyWith(name: 'late name'));
      await accountStore.switchAccount('account-b');
      container.read(userStoreProvider);
      await commit;
      expect(container.read(userStoreProvider), isEmpty);
      final cards = container.read(accountStoreProvider).requireValue.accounts;
      expect(cards.first.name, 'late name');
    },
  );

  test(
    'profile image preparation validates metadata and cleans up once',
    () async {
      final directory = await Directory.systemTemp.createTemp('profile-image-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/avatar.png')
        ..writeAsBytesSync(pngHeader(320, 240));
      final platform = FakeReverseImagePlatform(file);

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
    final repository = _FakeRepository(_appApi());
    final session = _session(repository);
    final container = _editorContainer();
    await _loaded(session, container);

    await tester.pumpWidget(
      localizedApp(
        container: container,
        locale: const Locale('en', 'US'),
        home: ProfileEditPage(userId: 42, session: session),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Display name'), findsOneWidget);
    expect(find.text('Bio'), findsOneWidget);
    expect(find.text('Web page'), findsOneWidget);
    expect(
      tester
          .widgetList<TextFormField>(find.byType(TextFormField))
          .map((field) => field.controller!.text),
      ['old name', 'old bio', 'https://example.com'],
    );

    // The image cards are taller than the old list tiles — the background
    // field can sit below the lazy list's viewport, so scroll it in.
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(find.text('Avatar'), findsOneWidget);
    expect(find.text('Background image'), findsOneWidget);

    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    final saveButton = find.text('Save profile');
    expect(saveButton, findsOneWidget);
    final saveButtonRect = tester.getRect(saveButton);
    final scaffoldRect = tester.getRect(find.byType(Scaffold));
    expect(saveButtonRect.top, greaterThanOrEqualTo(scaffoldRect.top));
    expect(saveButtonRect.bottom, lessThanOrEqualTo(scaffoldRect.bottom));

    // Scroll back to the top so a text field is built before dirtying it.
    await tester.drag(find.byType(ListView), const Offset(0, 900));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, 'changed');
    // The leading control is a back affordance, not a "cancel" action.
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    expect(find.text('Discard unsaved changes?'), findsOneWidget);

    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Discard unsaved changes?'), findsOneWidget);
  });

  group('images are tapped to change them', () {
    late _CountingImagePlatform platform;

    Future<void> pumpEditor(
      WidgetTester tester,
      ProfileCapabilities capabilities,
    ) async {
      setViewSize(tester, const Size(800, 1600));
      platform = _CountingImagePlatform();
      final session = _session(_FakeRepository(capabilities));
      final container = _editorContainer();
      await _loaded(session, container);
      await tester.pumpWidget(
        localizedApp(
          container: container,
          locale: const Locale('en', 'US'),
          builder: promptHostBuilder,
          home: ProfileEditPage(
            userId: 42,
            session: session,
            imagePlatform: platform,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    final avatar = find.byKey(const ValueKey('profile-edit-avatar-preview'));
    final background = find.byKey(
      const ValueKey('profile-edit-background-preview'),
    );

    testWidgets('tapping the avatar or the background picks an image', (
      tester,
    ) async {
      await pumpEditor(
        tester,
        ProfileCapabilities(
          editableFields: ProfileField.values,
          channel: ProfileEditChannel.appApi,
        ),
      );
      // No separate button any more; each image wears an edit badge.
      expect(find.text('Choose image'), findsNothing);
      expect(find.byType(OutlinedButton), findsNothing);
      expect(find.byIcon(Icons.edit_outlined), findsNWidgets(2));

      await tester.tap(avatar);
      await tester.pumpAndSettle();
      expect(platform.picks, 1);
      await tester.tap(background);
      await tester.pumpAndSettle();
      expect(platform.picks, 2);

      expect(
        tester.getSemantics(find.bySemanticsLabel('Change avatar')),
        isSemantics(label: 'Change avatar', isButton: true, hasTapAction: true),
      );
      expect(
        tester.getSemantics(find.bySemanticsLabel('Change background')),
        isSemantics(
          label: 'Change background',
          isButton: true,
          hasTapAction: true,
        ),
      );
      // Both targets are well past 48dp.
      final avatarSize = tester.getSize(avatar);
      expect(avatarSize.shortestSide, greaterThanOrEqualTo(48));
      expect(tester.getSize(background).height, greaterThanOrEqualTo(48));
    });

    testWidgets('save waits for a picked image to be read', (tester) async {
      await pumpEditor(tester, _appApi({ProfileField.avatar}));
      bool saveEnabled() => tester
          .widget<ButtonStyleButton>(
            find.ancestor(
              of: find.text('Save profile'),
              matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
            ),
          )
          .enabled;
      expect(saveEnabled(), isTrue);

      platform.copy = Completer<String>();
      await tester.tap(avatar);
      await tester.pump();
      expect(saveEnabled(), isFalse);

      platform.copy!.completeError(const FileSystemException('gone'));
      await tester.pump();
      expect(saveEnabled(), isTrue);
    });
  });

  test('an image picked mid-submit is released, not sent later', () async {
    final outcome = Completer<ProfileEditOutcome>();
    final repository = _FakeRepository(
      _appApi({ProfileField.displayName, ProfileField.avatar}),
      deferredOutcome: outcome,
    );
    final controller = await _loaded(_session(repository));
    controller.updateText(ProfileField.displayName, 'saved');
    final submit = controller.submit();
    var released = 0;
    await controller.selectImage(
      ProfileField.avatar,
      ProfileImageSelection(
        path: '/private/avatar.png',
        mimeType: 'image/png',
        sizeBytes: 128,
        width: 10,
        height: 10,
        cleanup: () async => released++,
      ),
    );

    expect(controller.state.status, ProfileEditStatus.submitting);
    expect(released, 1);
    outcome.complete(ProfileEditConfirmed(_user()));
    await submit;
  });

  testWidgets('production init keeps the auto-dispose controller alive', (
    tester,
  ) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: await _signedInContainer(),
        // No session: the page resolves the account asynchronously and
        // builds the editing session itself, exactly like production.
        child: localizedApp(
          locale: const Locale('en', 'US'),
          home: ProfileEditPage(
            userId: 42,
            initialUser: _user(),
            repository: _FakeRepository(_appApi()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Regression for the stuck spinner: the imperative load() used to create
    // the auto-dispose notifier with zero listeners, so it was collected
    // mid-load and the rebuild's watch spawned a fresh notifier nobody
    // load()ed — the page never left the loading state.
    expect(find.text('Display name'), findsOneWidget);
    expect(find.byType(TextFormField), findsWidgets);
  });

  testWidgets('a failed load offers a retry that loads the form', (
    tester,
  ) async {
    final users = _FlakyUserRepository(_user());
    await tester.pumpWidget(
      localizedApp(
        container: await _signedInContainer([
          userRepositoryProvider.overrideWithValue(users),
        ]),
        locale: const Locale('en', 'US'),
        home: ProfileEditPage(
          userId: 42,
          repository: _FakeRepository(_appApi()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Failed to load profile'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(users.calls, 2);
    expect(find.text('Display name'), findsOneWidget);
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

ProfileEditOwner _owner() => const ProfileEditOwner(accountId: 'account-a');

class _FakeRepository implements ProfileEditRepository {
  _FakeRepository(
    this.capabilities, {
    ProfileEditOutcome? outcome,
    this.deferredOutcome,
  }) : outcome = outcome ?? ProfileEditConfirmed(_user());

  final ProfileCapabilities capabilities;
  final ProfileEditOutcome outcome;
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
    return Future.value(outcome);
  }
}

/// Picker boundary that counts requests and returns nothing, or with
/// [copy] set, a picked image whose copy waits on it.
class _CountingImagePlatform implements ReverseImageInputPlatform {
  int picks = 0;
  Completer<String>? copy;

  @override
  Future<ReverseImageInputReference?> pickImage() async {
    picks++;
    if (copy == null) return null;
    return const ReverseImageInputReference(
      contentUri: 'content://picker/1',
      mimeType: 'image/png',
      sizeBytes: 128,
      hasReadUriPermission: true,
      source: ReverseImageInputSource.picker,
    );
  }

  @override
  Future<String> copyToOwnedFile(ReverseImageInputReference reference) =>
      copy?.future ?? (throw UnimplementedError());

  @override
  Future<void> deleteOwnedFile(String path) => throw UnimplementedError();
}

/// Fails the first detail fetch like a dropped connection, then answers.
class _FlakyUserRepository implements UserRepository {
  _FlakyUserRepository(this.user);

  final UserEntity user;
  var calls = 0;

  @override
  Future<UserEntity> fetchDetail(int userId, {CancelToken? cancelToken}) async {
    calls++;
    if (calls == 1) throw const ApiNetworkError('connection reset');
    return user;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
