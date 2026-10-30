import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parfait/core/bookmark/bookmark_actions.dart';
import 'package:parfait/core/bookmark/bookmark_models.dart';
import 'package:parfait/core/bookmark/bookmark_store.dart';

import 'helpers/api_responses.dart';
import 'helpers/bookmark_world.dart';

const _key = BookmarkKey(BookmarkEntityType.illust, 1);

/// The real actions, store and repository over the bookmark endpoints.
Future<(ProviderContainer, BookmarkApi)> _world() async {
  final repository = BookmarkApi();
  return (await bookmarkWorld(repository), repository);
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
    repository.detailFailure = failing(500);

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
    repository.detailFailure = failing(500);
    final actions = container.read(bookmarkActionsProvider);

    await actions.toggle(_key);
    expect(repository.deletes, [1]);
    expect(container.read(bookmarkStoreProvider)[_key]!.bookmarked, isFalse);

    await actions.toggle(_key);
    expect(repository.adds.single.$2, 'public');
  });
}
