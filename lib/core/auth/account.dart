/// Non-secret account metadata.
///
/// This object must never contain tokens, cookies or other credentials; it is
/// safe to persist in plain preferences and to serialize for diagnostics.
enum AccountAuthState {
  /// Credentials are present and believed valid.
  authenticated,

  /// Secure storage could not provide usable credentials; the account needs a
  /// fresh login before it can drive authenticated requests.
  reauthRequired,
}

class Account {
  const Account({
    required this.id,
    required this.userId,
    required this.name,
    this.mailAddress,
    this.profileImageUrl,
    this.isPremium = false,
    this.authState = AccountAuthState.authenticated,
  });

  /// Stable account identifier (the Pixiv user id as string).
  final String id;
  final int userId;
  final String name;
  final String? mailAddress;
  final String? profileImageUrl;

  /// Pixiv Premium flag from the OAuth `user.is_premium` field. Imported or
  /// pre-migration accounts default to false until their next login or token
  /// refresh repopulates it.
  final bool isPremium;
  final AccountAuthState authState;

  Account copyWith({
    String? id,
    int? userId,
    String? name,
    String? mailAddress,
    String? profileImageUrl,
    bool? isPremium,
    AccountAuthState? authState,
  }) {
    return Account(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      name: name ?? this.name,
      mailAddress: mailAddress ?? this.mailAddress,
      profileImageUrl: profileImageUrl ?? this.profileImageUrl,
      isPremium: isPremium ?? this.isPremium,
      authState: authState ?? this.authState,
    );
  }

  factory Account.fromJson(Map<String, dynamic> json) {
    return Account(
      id: json['id'] as String,
      userId: json['userId'] as int,
      name: json['name'] as String,
      mailAddress: json['mailAddress'] as String?,
      profileImageUrl: json['profileImageUrl'] as String?,
      isPremium: json['isPremium'] == true,
      authState: json['authState'] == 'reauthRequired'
          ? AccountAuthState.reauthRequired
          : AccountAuthState.authenticated,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'userId': userId,
      'name': name,
      if (mailAddress != null) 'mailAddress': mailAddress,
      if (profileImageUrl != null) 'profileImageUrl': profileImageUrl,
      if (isPremium) 'isPremium': true,
      'authState': authState == AccountAuthState.reauthRequired
          ? 'reauthRequired'
          : 'authenticated',
    };
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Account &&
          other.id == id &&
          other.userId == userId &&
          other.name == name &&
          other.mailAddress == mailAddress &&
          other.profileImageUrl == profileImageUrl &&
          other.isPremium == isPremium &&
          other.authState == authState;

  @override
  int get hashCode => Object.hash(id, userId, name, isPremium, authState);
}
