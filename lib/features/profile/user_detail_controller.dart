import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/account_store.dart';
import '../../core/network/api_error.dart';
import '../../core/user/user_entity.dart';
import '../../core/user/user_repository.dart';
import '../../core/user/user_store.dart';

sealed class UserDetailState {
  const UserDetailState();
}

class UserDetailLoading extends UserDetailState {
  const UserDetailLoading();
}

class UserDetailReady extends UserDetailState {
  const UserDetailReady(this.user);

  final UserEntity user;
}

class UserDetailNotFound extends UserDetailState {
  const UserDetailNotFound();
}

class UserDetailBlocked extends UserDetailState {
  const UserDetailBlocked(this.user);

  final UserEntity user;
}

class UserDetailError extends UserDetailState {
  const UserDetailError(this.error, {this.snapshot});

  final ApiError error;
  final UserEntity? snapshot;
}

/// Loads one user into the canonical [UserStore] and exposes explicit
/// not-found/blocked/error states to the profile UI.
class UserDetailController extends AsyncNotifier<UserDetailState> {
  UserDetailController(this.userId);

  final int userId;

  @override
  Future<UserDetailState> build() => _load();

  Future<void> reload() async {
    state = const AsyncLoading<UserDetailState>();
    state = await AsyncValue.guard(_load);
  }

  Future<UserDetailState> _load() async {
    // The detail request writes into UserStore. Reading the snapshot avoids a
    // self-invalidating dependency loop while the account watch still resets
    // this controller when the active account changes.
    ref.watch(accountStoreProvider.select((async) => async.value?.current?.id));
    final entities = ref.read(userStoreProvider);
    final snapshot = entities[userId];
    if (snapshot != null && !snapshot.visible) {
      return UserDetailBlocked(snapshot);
    }
    try {
      final store = ref.read(userStoreProvider.notifier);
      final followRevision = store.followRevisionNow();
      final fresh = await ref.read(userRepositoryProvider).fetchDetail(userId);
      store.mergeAll([fresh], followSnapshotRevision: followRevision);
      final merged = store.get(userId) ?? fresh;
      return merged.visible
          ? UserDetailReady(merged)
          : UserDetailBlocked(merged);
    } on ApiHttpError catch (error) {
      if (error.statusCode == 404 || error.statusCode == 400) {
        return const UserDetailNotFound();
      }
      return UserDetailError(error, snapshot: snapshot);
    } on ApiError catch (error) {
      return UserDetailError(error, snapshot: snapshot);
    }
  }
}

final userDetailControllerProvider =
    AsyncNotifierProvider.family<UserDetailController, UserDetailState, int>(
      UserDetailController.new,
    );
