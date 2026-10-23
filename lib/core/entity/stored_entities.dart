import 'package:flutter/foundation.dart';

/// The entities of [ids] a store map holds, in order. Equal while each is
/// the same instance, so a list that selects them from a store does not
/// rebuild when the store merges other entities.
@immutable
class StoredEntities<T extends Object> {
  StoredEntities(Map<int, T> store, Iterable<int> ids)
    : items = List.unmodifiable([for (final id in ids) ?store[id]]);

  final List<T> items;

  @override
  bool operator ==(Object other) {
    if (other is! StoredEntities<T> || other.items.length != items.length) {
      return false;
    }
    for (var i = 0; i < items.length; i++) {
      if (!identical(other.items[i], items[i])) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(items.map(identityHashCode));
}
