import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logging/crash_log.dart';
import '../settings/preference_keys.dart';
import '../settings/shared_preferences.dart';

/// Recent search keywords, newest first (with pinned queries kept at the front),
/// stored on the device.
final searchHistoryProvider =
    NotifierProvider<SearchHistoryNotifier, List<String>>(
      SearchHistoryNotifier.new,
    );

/// Pinned subset of [searchHistoryProvider], rebuilt whenever history or pins
/// change.
final searchHistoryPinnedProvider = Provider<Set<String>>((ref) {
  ref.watch(searchHistoryProvider);
  return ref.read(searchHistoryProvider.notifier).pinned;
});

class SearchHistoryNotifier extends Notifier<List<String>> {
  /// Enough to cover a session's worth of searches without the list
  /// turning into a log.
  static const maxEntries = 20;

  late Future<void> _ready;
  Future<void> _writeTail = Future<void>.value();
  List<String> _pinned = const [];

  /// Currently pinned keywords in pin order.
  Set<String> get pinned => Set<String>.unmodifiable(_pinned);

  bool isPinned(String keyword) => _pinned.contains(keyword);

  @override
  List<String> build() {
    _ready = _load();
    return const [];
  }

  Future<void> _load() async {
    final prefs = ref.read(sharedPreferencesProvider);
    final stored = await prefs.getStringList(PreferenceKeys.searchHistory);
    final storedPinned = await prefs.getStringList(
      PreferenceKeys.searchHistoryPinned,
    );
    _pinned = _normalized(storedPinned ?? const []);
    if (stored == null && _pinned.isEmpty) return;
    state = _ordered(stored ?? const [], _pinned);
  }

  /// Moves [keyword] to the front of its section; a blank keyword is ignored.
  Future<void> record(String keyword) async {
    final entry = keyword.trim();
    if (entry.isEmpty) return;
    await _ready;
    if (_pinned.contains(entry)) {
      _pinned = _normalized([entry, ..._pinned.where((e) => e != entry)]);
      _write([entry, ...state.where((e) => e != entry)], writePinned: true);
      return;
    }
    _write([entry, ...state.where((e) => e != entry)]);
  }

  /// Toggles whether [keyword] is pinned. Pinned entries stay at the front and
  /// survive [clear].
  Future<void> togglePin(String keyword) async {
    final entry = keyword.trim();
    if (entry.isEmpty) return;
    await _ready;
    if (_pinned.contains(entry)) {
      _pinned = [
        for (final item in _pinned)
          if (item != entry) item,
      ];
    } else {
      _pinned = _normalized([entry, ..._pinned]);
    }
    final nextEntries = state.contains(entry) ? state : [entry, ...state];
    _write(nextEntries, writePinned: true);
  }

  /// Removes [keyword] and returns where it was, for [restore]; null when
  /// it was not there.
  Future<int?> remove(String keyword) async {
    await _ready;
    final index = state.indexOf(keyword);
    if (index < 0) return null;
    final wasPinned = _pinned.contains(keyword);
    if (wasPinned) {
      _pinned = [
        for (final item in _pinned)
          if (item != keyword) item,
      ];
    }
    _write([...state]..removeAt(index), writePinned: wasPinned);
    return index;
  }

  /// Puts back a [keyword] [remove] took out at [index], unless it was
  /// searched again since.
  Future<void> restore(String keyword, int index) async {
    await _ready;
    if (state.contains(keyword)) return;
    _write([...state]..insert(index.clamp(0, state.length), keyword));
  }

  /// Clears unpinned search history while keeping pinned queries intact.
  Future<void> clear() async {
    await _ready;
    _write(_pinned);
  }

  void _write(List<String> entries, {bool writePinned = false}) {
    final next = _ordered(entries, _pinned);
    final pinnedSnapshot = List<String>.unmodifiable(_pinned);
    state = next;
    final preferences = ref.read(sharedPreferencesProvider);
    // Serialized: a fast record-then-remove must land in that order.
    // A failed write is logged; the list on screen stays as edited.
    _writeTail = _writeTail
        .then((_) async {
          await preferences.setStringList(PreferenceKeys.searchHistory, next);
          if (writePinned) {
            await preferences.setStringList(
              PreferenceKeys.searchHistoryPinned,
              pinnedSnapshot,
            );
          }
        })
        .catchError(CrashLog.record);
  }

  static List<String> _ordered(List<String> entries, List<String> pinned) {
    final pinnedSet = pinned.toSet();
    return _normalized([
      ...pinned,
      for (final entry in entries)
        if (!pinnedSet.contains(entry)) entry,
    ]);
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
