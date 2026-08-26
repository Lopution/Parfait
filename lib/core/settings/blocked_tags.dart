import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Blocked tag list (beta56 BlockTagService semantics), persisted in
/// SharedPreferences under `blocked_tags`. Global (not account-scoped),
/// matching the original.
class BlockedTags extends Notifier<Set<String>> {
  static const _key = 'blocked_tags';

  @override
  Set<String> build() {
    _restore();
    return {};
  }

  Future<void> _restore() async {
    final prefs = await SharedPreferencesAsync().getStringList(_key);
    if (prefs != null && state.isEmpty) {
      state = Set.of(prefs);
    }
  }

  bool isBlocked(String tag) => state.contains(tag);

  /// Returns the new blocked state after toggling.
  Future<bool> toggle(String tag) async {
    final next = Set.of(state);
    final blocked = !next.remove(tag);
    if (blocked) next.add(tag);
    state = next;
    await SharedPreferencesAsync().setStringList(_key, next.toList());
    return blocked;
  }
}

final blockedTagsProvider =
    NotifierProvider<BlockedTags, Set<String>>(BlockedTags.new);
