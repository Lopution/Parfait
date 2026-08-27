import 'package:flutter/foundation.dart';

/// The three beta56 New scopes. The scope is part of the feed key so an empty
/// or unavailable personal source can never fall back to Everyone.
enum NewFeedScope { following, everyone, myPixiv }

/// New supports two independently paged content sources.
enum NewFeedType { illust, novel }

@immutable
class NewFeedKey {
  const NewFeedKey({required this.scope, required this.type});

  final NewFeedScope scope;
  final NewFeedType type;

  String get scopeLabelKey => switch (scope) {
    NewFeedScope.following => 'newFollowing',
    NewFeedScope.everyone => 'newEveryone',
    NewFeedScope.myPixiv => 'newMyPixiv',
  };

  String get typeLabelKey => switch (type) {
    NewFeedType.illust => 'newIllust',
    NewFeedType.novel => 'newNovel',
  };

  @override
  bool operator ==(Object other) =>
      other is NewFeedKey && other.scope == scope && other.type == type;

  @override
  int get hashCode => Object.hash(scope, type);

  @override
  String toString() => 'NewFeedKey($scope, $type)';
}
