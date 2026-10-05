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

/// A locally muted work with what the management list shows for it:
/// title and square thumbnail, captured when it was muted. Entries muted
/// before these were stored carry only the id.
class MutedWork {
  const MutedWork({required this.illustId, this.title, this.thumbnailUrl});

  final int illustId;
  final String? title;
  final String? thumbnailUrl;

  /// Reads one stored entry: the current `{id, title, thumbnailUrl}`
  /// object or a bare id from the old format. Throws [FormatException] on
  /// anything else.
  factory MutedWork.fromJson(Object? raw) {
    final id = switch (raw) {
      num() => raw,
      {'id': final num id} => id,
      _ => throw const FormatException('a muted work is an id or an object'),
    };
    if (id <= 0) throw const FormatException('a muted work id is positive');
    if (raw is! Map) return MutedWork(illustId: id.toInt());
    return MutedWork(
      illustId: id.toInt(),
      title: _optionalString(raw['title']),
      thumbnailUrl: _optionalString(raw['thumbnailUrl']),
    );
  }

  Map<String, Object> toJson() => {
    'id': illustId,
    'title': ?title,
    'thumbnailUrl': ?thumbnailUrl,
  };

  /// This entry with a missing title or thumbnail taken from [other]; what
  /// it already has is kept.
  MutedWork filledFrom(MutedWork other) => MutedWork(
    illustId: illustId,
    title: title ?? other.title,
    thumbnailUrl: thumbnailUrl ?? other.thumbnailUrl,
  );

  @override
  bool operator ==(Object other) =>
      other is MutedWork &&
      other.illustId == illustId &&
      other.title == title &&
      other.thumbnailUrl == thumbnailUrl;

  @override
  int get hashCode => Object.hash(illustId, title, thumbnailUrl);

  static String? _optionalString(Object? raw) => switch (raw) {
    null => null,
    String() => raw,
    _ => throw const FormatException('muted work fields are strings'),
  };
}

/// Effective mute snapshot for one account. `pending` tracks keys with an
/// in-flight edit so the UI can dim them and re-entry is suppressed.
class MuteState {
  const MuteState({
    this.tags = const {},
    this.users = const {},
    this.works = const {},
    this.pending = const {},
    this.legacyTagsPending = const {},
    this.serverSynced = false,
  });

  final Set<String> tags;
  final Map<int, MutedUser> users;
  final Map<int, MutedWork> works;
  final Set<MuteKey> pending;

  /// Legacy `blocked_tags` entries not yet confirmed pushed to the server.
  /// They mute effectively either way; the flag only tracks migration.
  final Set<String> legacyTagsPending;

  /// Whether `/v1/mute/list` has been applied for the current account.
  final bool serverSynced;

  bool isTagMuted(String tag) => tags.contains(tag);
  bool isUserMuted(int userId) => users.containsKey(userId);
  bool isWorkMuted(int illustId) => works.containsKey(illustId);

  MuteState copyWith({
    Set<String>? tags,
    Map<int, MutedUser>? users,
    Map<int, MutedWork>? works,
    Set<MuteKey>? pending,
    Set<String>? legacyTagsPending,
    bool? serverSynced,
  }) {
    return MuteState(
      tags: tags ?? this.tags,
      users: users ?? this.users,
      works: works ?? this.works,
      pending: pending ?? this.pending,
      legacyTagsPending: legacyTagsPending ?? this.legacyTagsPending,
      serverSynced: serverSynced ?? this.serverSynced,
    );
  }
}
