import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parfait/core/auth/account_store.dart';
import 'package:parfait/core/bookmark/bookmark_actions.dart';
import 'package:parfait/core/bookmark/bookmark_models.dart';
import 'package:parfait/core/bookmark/bookmark_repository.dart';
import 'package:parfait/core/bookmark/bookmark_store.dart';
import 'package:parfait/core/network/api_error.dart';

import 'helpers/bookmark_world.dart';
import 'helpers/fake_account.dart';
import 'helpers/test_preferences.dart';

const _key = BookmarkKey(BookmarkEntityType.illust, 1);

/// The real actions and store over a recording repository — the network
/// boundary is the only fake.
Future<(ProviderContainer, RecordingBookmarkRepository)> _world() async {
  installMemoryPreferences();
  final repository = RecordingBookmarkRepository();
  final container = ProviderContainer(
    overrides: [
      accountStoreProvider.overrideWith(StubAccountStore.new),
      bookmarkRepositoryProvider.overrideWithValue(repository),
    ],
  );
  addTearDown(container.dispose);
  await container.read(accountStoreProvider.future);
  return (container, repository);
}

void main() {
  test('an add confirmed here is its own snapshot — no lookup', () async {
    final (container, repository) = await _world();
    final actions = container.read(bookmarkActionsProvider);
    await actions.addWithRestrict(
      _key,
      BookmarkRestrict.private,
      tags: const ['a', 'b'],
    );
    // A lookup would fail and leave nothing to restore.
    repository.detailError = const ApiHttpError(500);

    await actions.toggle(_key);
    await actions.toggle(_key);

    expect(repository.deletes, [1]);
    final (_, restrict, tags) = repository.adds.last;
    expect(restrict, 'private');
    expect(tags, ['a', 'b']);
  });

  test('a remotely observed bookmark is read from the server first', () async {
    final (container, repository) = await _world();
    // Feeds report visibility but never tags.
    container
        .read(bookmarkStoreProvider.notifier)
        .observeRemote(
          _key,
          bookmarked: true,
          restrict: BookmarkRestrict.private,
        );
    repository.detail = const BookmarkDetail(
      isBookmarked: true,
      restrict: BookmarkRestrict.private,
      tags: [
        BookmarkTagFacet(name: 'kept', isRegistered: true),
        // A suggestion the bookmark does not carry.
        BookmarkTagFacet(name: 'suggested', isRegistered: false),
      ],
    );
    final actions = container.read(bookmarkActionsProvider);

    await actions.toggle(_key);
    // Tapping the heart again is the Undo: a private bookmark stays private.
    await actions.toggle(_key);

    expect(repository.deletes, [1]);
    final (_, restrict, tags) = repository.adds.single;
    expect(restrict, 'private');
    expect(tags, ['kept']);
  });

  test('an unreadable original still deletes, and comes back public', () async {
    final (container, repository) = await _world();
    container
        .read(bookmarkStoreProvider.notifier)
        .observeRemote(_key, bookmarked: true);
    repository.detailError = const ApiHttpError(500);
    final actions = container.read(bookmarkActionsProvider);

    await actions.toggle(_key);
    expect(repository.deletes, [1]);
    expect(container.read(bookmarkStoreProvider)[_key]!.bookmarked, isFalse);

    await actions.toggle(_key);
    expect(repository.adds.single.$2, 'public');
  });
}
