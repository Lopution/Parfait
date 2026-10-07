import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logging/crash_log.dart';
import '../settings/preference_keys.dart';
import '../settings/shared_preferences.dart';

/// Recent search keywords, newest first, kept on the device.
final searchHistoryProvider =
    NotifierProvider<SearchHistoryNotifier, List<String>>(
      SearchHistoryNotifier.new,
    );

class SearchHistoryNotifier extends Notifier<List<String>> {
  /// Enough to cover a session's worth of searches without the list
  /// turning into a log.
  static const maxEntries = 20;

  late Future<void> _ready;
  Future<void> _writeTail = Future<void>.value();

  @override
  List<String> build() {
    _ready = _load();
    return const [];
  }

  Future<void> _load() async {
    final stored = await ref
        .read(sharedPreferencesProvider)
        .getStringList(PreferenceKeys.searchHistory);
    if (stored == null) return;
    state = _normalized(stored);
  }

  /// Moves [keyword] to the front; a blank keyword is not recorded.
  Future<void> record(String keyword) async {
    final entry = keyword.trim();
    if (entry.isEmpty) return;
    await _ready;
    _write([entry, ...state.where((e) => e != entry)]);
  }

  /// Removes [keyword] and returns where it was, for [restore]; null when
  /// it was not there.
  Future<int?> remove(String keyword) async {
    await _ready;
    final index = state.indexOf(keyword);
    if (index < 0) return null;
    _write([...state]..removeAt(index));
    return index;
  }

  /// Puts back a [keyword] [remove] took out at [index], unless it was
  /// searched again since.
  Future<void> restore(String keyword, int index) async {
    await _ready;
    if (state.contains(keyword)) return;
    _write([...state]..insert(index.clamp(0, state.length), keyword));
  }

  Future<void> clear() async {
    await _ready;
    _write(const []);
  }

  void _write(List<String> entries) {
    final next = _normalized(entries);
    state = next;
    final preferences = ref.read(sharedPreferencesProvider);
    // Serialized: a fast record-then-remove must land in that order.
    // A failed write is logged; the list on screen stays as edited.
    _writeTail = _writeTail
        .then(
          (_) => preferences.setStringList(PreferenceKeys.searchHistory, next),
        )
        .catchError(CrashLog.record);
  }

  static List<String> _normalized(List<String> entries) {
    final seen = <String>{};
    return List.unmodifiable(
      [
        for (final entry in entries)
          if (entry.trim().isNotEmpty && seen.add(entry)) entry,
      ].take(maxEntries),
    );
  }
}
