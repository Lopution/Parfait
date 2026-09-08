import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'preference_keys.dart';
import 'shared_preferences.dart';

/// Blocked tag list (beta56 BlockTagService semantics), persisted in
/// SharedPreferences under `blocked_tags`. Global (not account-scoped),
/// matching the original.
class BlockedTags extends Notifier<Set<String>> {
  static const _key = PreferenceKeys.blockedTags;

  @override
  Set<String> build() {
    _restore();
    return {};
  }

  Future<void> _restore() async {
    try {
      final prefs = await ref.read(sharedPreferencesProvider).getStringList(_key);
      if (prefs != null && state.isEmpty) {
        state = Set.of(prefs);
      }
    } on Object {
      // A blocked-tag read failure must never break discovery feeds that
      // watch this provider; the list simply stays empty for this session.
    }
  }

  bool isBlocked(String tag) => state.contains(tag);

  /// Returns the new blocked state after toggling.
  Future<bool> toggle(String tag) async {
    final next = Set.of(state);
    final blocked = !next.remove(tag);
    if (blocked) next.add(tag);
    state = next;
    await ref.read(sharedPreferencesProvider).setStringList(_key, next.toList());
    return blocked;
  }
}

final blockedTagsProvider =
    NotifierProvider<BlockedTags, Set<String>>(BlockedTags.new);
