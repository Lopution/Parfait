import '../auth/account_store.dart';
import '../user/user_entity.dart';
import '../user/user_store.dart';

/// Commits authoritative profile metadata in a persistence-first transaction:
/// the account card is durable before the canonical UserStore is refreshed.
/// UserStore.mergeAll is synchronous and cannot partially persist a second
/// copy, so no optimistic UI is exposed between the two operations.
class ProfileEditStoreCommitter {
  const ProfileEditStoreCommitter({
    required this.accountStore,
    required this.userStore,
  });

  final AccountStore accountStore;
  final UserStore userStore;

  Future<void> commit(UserEntity user) async {
    final state = await accountStore.resolveState();
    final account = state.usableCurrent;
    if (account == null || account.userId != user.id) {
      throw const ProfileEditCommitException(
        'current account does not own this profile',
      );
    }
    final updated = account.copyWith(
      name: user.name,
      profileImageUrl: user.profileImageUrl,
    );
    await accountStore.updateAccount(updated);
    userStore.mergeAll([user]);
  }
}

class ProfileEditCommitException implements Exception {
  const ProfileEditCommitException(this.message);

  final String message;

  @override
  String toString() => 'ProfileEditCommitException: $message';
}
