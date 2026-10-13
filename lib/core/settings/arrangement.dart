/// A user's arrangement of a fixed set of items: which are shown, in what
/// order, and which are hidden. Type-agnostic so every user-ordered list
/// (ranking categories, later the bottom bar) shares one persisted shape
/// and one merge rule.
library;

import 'package:flutter/foundation.dart';

/// One persisted entry: an item's stable id and whether it is shown.
typedef ArrangedEntry = ({String id, bool visible});

@immutable
class Arrangement<T> {
  const Arrangement({required this.shown, required this.hidden});

  /// Shown items, in the user's order.
  final List<T> shown;

  /// Hidden items, the most recently hidden first.
  final List<T> hidden;

  /// [saved] laid over [defaults]. An id [lookup] does not know (written by
  /// a newer version) and a repeated id are skipped; an item [saved] does
  /// not mention (added in a later version) is appended with its default
  /// visibility. Null [saved] is the default arrangement.
  static Arrangement<T> resolve<T>(
    Arrangement<T> defaults,
    List<ArrangedEntry>? saved,
    T? Function(String id) lookup,
  ) {
    if (saved == null) return defaults;
    final shown = <T>[];
    final hidden = <T>[];
    final seen = <T>{};
    for (final entry in saved) {
      final item = lookup(entry.id);
      if (item == null || !seen.add(item)) continue;
      (entry.visible ? shown : hidden).add(item);
    }
    for (final item in defaults.shown) {
      if (seen.add(item)) shown.add(item);
    }
    for (final item in defaults.hidden) {
      if (seen.add(item)) hidden.add(item);
    }
    // A newer version may show only items this one does not know; one item
    // always stays shown.
    if (shown.isEmpty && hidden.isNotEmpty) shown.add(hidden.removeAt(0));
    return Arrangement(
      shown: List.unmodifiable(shown),
      hidden: List.unmodifiable(hidden),
    );
  }

  /// Every item in order, shown ones first, for persisting.
  List<ArrangedEntry> toEntries(String Function(T item) idOf) => [
    for (final item in shown) (id: idOf(item), visible: true),
    for (final item in hidden) (id: idOf(item), visible: false),
  ];

  /// At least one item always stays shown.
  bool get canHide => shown.length > 1;

  /// Moves the shown item at [from] to index [to] of the result.
  Arrangement<T> reorder(int from, int to) {
    final next = [...shown];
    next.insert(to, next.removeAt(from));
    return Arrangement(shown: next, hidden: hidden);
  }

  Arrangement<T> moveToFront(T item) => Arrangement(
    shown: [item, ...shown.where((other) => other != item)],
    hidden: hidden.where((other) => other != item).toList(),
  );

  Arrangement<T> hide(T item) {
    if (!shown.contains(item)) return this;
    if (!canHide) throw StateError('the last shown item cannot be hidden');
    return Arrangement(
      shown: shown.where((other) => other != item).toList(),
      hidden: [item, ...hidden],
    );
  }

  /// Shows a hidden item at the end of the shown ones.
  Arrangement<T> show(T item) {
    if (!hidden.contains(item)) return this;
    return Arrangement(
      shown: [...shown, item],
      hidden: hidden.where((other) => other != item).toList(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Arrangement<T> &&
      listEquals(other.shown, shown) &&
      listEquals(other.hidden, hidden);

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(shown), Object.hashAll(hidden));

  /// Tolerant read of a persisted list (spec PREF-01): a malformed entry is
  /// skipped; anything but a list is null, the default arrangement.
  static List<ArrangedEntry>? decodeEntries(Object? json) {
    if (json is! List) return null;
    return List.unmodifiable([
      for (final raw in json)
        if (raw case {'id': final String id, 'visible': final bool visible})
          (id: id, visible: visible),
    ]);
  }

  static List<Map<String, Object>> encodeEntries(List<ArrangedEntry> entries) =>
      [
        for (final entry in entries) {'id': entry.id, 'visible': entry.visible},
      ];
}
