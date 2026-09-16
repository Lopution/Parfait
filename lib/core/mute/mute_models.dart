/// Mute domain models. Three kinds: tag and user mute sync with the
/// server's `/v1/mute` list (shared with the official client), while
/// single-work mute has no official endpoint and stays local per account.
library;

enum MuteKind { tag, user, work }

/// Identity of one muted entry. [value] is the tag name for
/// [MuteKind.tag] and the numeric id for user/work.
class MuteKey {
  const MuteKey(this.kind, this.value);

  final MuteKind kind;
  final String value;

  factory MuteKey.tag(String tag) => MuteKey(MuteKind.tag, tag);
  factory MuteKey.user(int userId) => MuteKey(MuteKind.user, '$userId');
  factory MuteKey.work(int illustId) => MuteKey(MuteKind.work, '$illustId');

  @override
  bool operator ==(Object other) =>
      other is MuteKey && other.kind == kind && other.value == value;

  @override
  int get hashCode => Object.hash(kind, value);
}

/// Server-side muted user payload from `/v1/mute/list`.
class MutedUser {
  const MutedUser({
    required this.userId,
    required this.name,
    this.account,
    this.profileImageUrl,
  });

  final int userId;
  final String name;
  final String? account;
  final String? profileImageUrl;

  factory MutedUser.fromJson(Map<String, dynamic> json) => MutedUser(
    userId: (json['user_id'] as num).toInt(),
    name: json['user_name'] as String? ?? '',
    account: json['user_account'] as String?,
    profileImageUrl:
        (json['user_profile_image_urls'] as Map?)?['medium'] as String?,
  );
}

/// Effective mute snapshot for one account. `pending` tracks keys with an
/// in-flight edit so the UI can dim them and re-entry is suppressed.
class MuteState {
  const MuteState({
    this.tags = const {},
    this.users = const {},
    this.workIds = const {},
    this.pending = const {},
    this.legacyTagsPending = const {},
    this.serverSynced = false,
  });

  final Set<String> tags;
  final Map<int, MutedUser> users;
  final Set<int> workIds;
  final Set<MuteKey> pending;

  /// Legacy `blocked_tags` entries not yet confirmed pushed to the server.
  /// They mute effectively either way; the flag only tracks migration.
  final Set<String> legacyTagsPending;

  /// Whether `/v1/mute/list` has been applied for the current account.
  final bool serverSynced;

  bool isTagMuted(String tag) => tags.contains(tag);
  bool isUserMuted(int userId) => users.containsKey(userId);
  bool isWorkMuted(int illustId) => workIds.contains(illustId);

  MuteState copyWith({
    Set<String>? tags,
    Map<int, MutedUser>? users,
    Set<int>? workIds,
    Set<MuteKey>? pending,
    Set<String>? legacyTagsPending,
    bool? serverSynced,
  }) {
    return MuteState(
      tags: tags ?? this.tags,
      users: users ?? this.users,
      workIds: workIds ?? this.workIds,
      pending: pending ?? this.pending,
      legacyTagsPending: legacyTagsPending ?? this.legacyTagsPending,
      serverSynced: serverSynced ?? this.serverSynced,
    );
  }
}
