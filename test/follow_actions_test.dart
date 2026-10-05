import 'package:flutter_test/flutter_test.dart';
import 'package:parfait/core/network/api_error.dart';
import 'package:parfait/core/user/follow_actions.dart';
import 'package:parfait/core/user/follow_models.dart';
import 'package:parfait/core/user/follow_store.dart';

import 'helpers/profile_world.dart';

void main() {
  test('a known visibility is its own snapshot — no lookup', () async {
    final follows = FakeFollowRepository();
    final container = await makeProfileWorld(follows: follows);
    final actions = container.read(followActionsProvider);
    await actions.addWithRestrict(42, FollowRestrict.private);

    final removed = await actions.toggle(42);

    expect(removed?.restrict, FollowRestrict.private);
    expect(follows.requests, ['add:42:private', 'delete:42']);
  });

  test('an unknown visibility is read before the unfollow', () async {
    final follows = FakeFollowRepository()
      ..remoteRestrict = FollowRestrict.private;
    final container = await makeProfileWorld(follows: follows);
    // A profile payload says "followed" without the visibility.
    container
        .read(followStoreProvider.notifier)
        .observeRemote(42, followed: true);

    final removed = await container.read(followActionsProvider).toggle(42);

    expect(removed?.restrict, FollowRestrict.private);
    expect(follows.requests, ['restrict:42', 'delete:42']);
  });

  test(
    'an unreadable visibility still unfollows, without a snapshot',
    () async {
      final follows = FakeFollowRepository()
        ..restrictFailure = const ApiHttpError(500);
      final container = await makeProfileWorld(follows: follows);
      container
          .read(followStoreProvider.notifier)
          .observeRemote(42, followed: true);

      final removed = await container.read(followActionsProvider).toggle(42);

      expect(removed, isNull);
      expect(follows.requests, ['restrict:42', 'delete:42']);
      expect(container.read(followStoreProvider)[42]!.followed, isFalse);
    },
  );

  test('a failed unfollow returns no snapshot', () async {
    final follows = FakeFollowRepository()..failure = const ApiHttpError(500);
    final container = await makeProfileWorld(follows: follows);
    container
        .read(followStoreProvider.notifier)
        .observeRemote(42, followed: true, restrict: FollowRestrict.public);

    expect(await container.read(followActionsProvider).toggle(42), isNull);
    expect(container.read(followStoreProvider)[42]!.followed, isTrue);
  });
}
