import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_store.dart';
import '../settings/preference_keys.dart';
import '../settings/shared_preferences.dart';
import 'mute_models.dart';
import 'mute_repository.dart';

/// Effective mute set for the current account: server-authoritative
/// tags/users plus local-only work mutes.
///
/// Hydration order (build → `_hydrate`):
/// 1. Local state first — persisted work mutes and the legacy `blocked_tags`
///    pref apply immediately, so a cold start still mutes before the
///    network answers.
/// 2. `/v1/mute/list` merges server tags/users.
/// 3. Legacy tags missing from the server set are pushed once through
///    `mute/edit(add_tags)`; the pref is cleared only after every push
///    succeeds. Failures leave them in `legacyTagsPending` — still
///    effective locally — and the next hydrate retries.
///
/// Boundary semantics follow BookmarkStore (account switch rebuilds state,
/// writes require a usable boundary) without the full MutationLedger:
/// mute edits are idempotent set operations with no cancel token, so a
/// per-key pending flag + optimistic rollback is the whole protocol.
class MuteStore extends Notifier<MuteState> {
  /// Resolves when the current hydration pass finishes (success or
  /// failure). Mutations await it so an in-flight hydrate never
  /// overwrites an optimistic update.
  Future<void> _hydrated = Future<void>.value();

  @override
  MuteState build() {
    final accountId = ref.watch(
      accountStoreProvider.select((async) => async.value?.usableCurrent?.id),
    );
    if (accountId == null) return const MuteState();
    _hydrated = _hydrate(accountId);
    return const MuteState();
  }

  String _worksKey(String accountId) => 'muted_works_$accountId';

  String _requireAccountId() {
    final account = ref.read(accountStoreProvider).value?.usableCurrent;
    if (account == null) {
      throw StateError('mute write without an authenticated account');
    }
    return account.id;
  }

  /// True while [accountId] is still the store's account — a switch mid-
  /// hydrate must not let stale writes land in the new account's state.
  bool _stillCurrent(String accountId) {
    return ref.read(accountStoreProvider).value?.usableCurrent?.id == accountId;
  }

  Future<void> _hydrate(String accountId) async {
    final prefs = ref.read(sharedPreferencesProvider);
    final worksRaw = await prefs.getString('muted_works_$accountId');
    final works = worksRaw == null
        ? <int>{}
        : {for (final id in jsonDecode(worksRaw) as List) (id as num).toInt()};
    final legacyTags = {
      ...?await prefs.getStringList(PreferenceKeys.blockedTags),
    };
    if (!_stillCurrent(accountId)) return;
    state = state.copyWith(
      workIds: works,
      tags: {...state.tags, ...legacyTags},
      legacyTagsPending: legacyTags,
    );

    MuteListResult remote;
    try {
      remote = await ref.read(muteRepositoryProvider).fetchList();
    } on Object {
      // Offline or server failure: local mutes stay effective and the
      // next build retries the sync.
      return;
    }
    if (!_stillCurrent(accountId)) return;
    state = state.copyWith(
      tags: {...state.tags, ...remote.tags},
      users: remote.users,
      serverSynced: true,
    );

    final missing = state.legacyTagsPending.difference(remote.tags);
    if (missing.isEmpty) {
      if (legacyTags.isNotEmpty) {
        await prefs.remove(PreferenceKeys.blockedTags);
        if (_stillCurrent(accountId)) {
          state = state.copyWith(legacyTagsPending: const {});
        }
      }
      return;
    }
    final failed = <String>{};
    for (final tag in missing) {
      try {
        await ref.read(muteRepositoryProvider).edit(addTag: tag);
      } on Object {
        failed.add(tag);
      }
    }
    if (failed.isEmpty) {
      await prefs.remove(PreferenceKeys.blockedTags);
    }
    if (_stillCurrent(accountId)) {
      state = state.copyWith(legacyTagsPending: failed);
    }
  }

  /// Local-only work mute. Optimistic; persisted per account. The account
  /// id is captured up front so an account switch mid-write cannot persist
  /// the old account's list under the new account's key.
  Future<void> toggleWork(int illustId) async {
    await _hydrated;
    final accountId = _requireAccountId();
    final key = MuteKey.work(illustId);
    if (state.pending.contains(key)) return;
    state = state.copyWith(pending: {...state.pending, key});
    try {
      final next = {...state.workIds};
      if (!next.remove(illustId)) next.add(illustId);
      state = state.copyWith(workIds: next);
      await _persistWorks(accountId, next);
    } finally {
      if (_stillCurrent(accountId)) {
        state = state.copyWith(pending: {...state.pending}..remove(key));
      }
    }
  }

  Future<void> toggleTag(String tag) async {
    final muted = state.isTagMuted(tag);
    await _serverToggle(
      key: MuteKey.tag(tag),
      apply: () => muted
          ? state.copyWith(tags: {...state.tags}..remove(tag))
          : state.copyWith(tags: {...state.tags, tag}),
      revert: () => muted
          ? state.copyWith(tags: {...state.tags, tag})
          : state.copyWith(tags: {...state.tags}..remove(tag)),
      edit: (repo) =>
          muted ? repo.edit(deleteTag: tag) : repo.edit(addTag: tag),
    );
  }

  Future<void> toggleUser(MutedUser user) async {
    final muted = state.isUserMuted(user.userId);
    await _serverToggle(
      key: MuteKey.user(user.userId),
      apply: () => muted
          ? state.copyWith(users: {...state.users}..remove(user.userId))
          : state.copyWith(users: {...state.users, user.userId: user}),
      revert: () => muted
          ? state.copyWith(users: {...state.users, user.userId: user})
          : state.copyWith(users: {...state.users}..remove(user.userId)),
      edit: (repo) => muted
          ? repo.edit(deleteUserId: user.userId)
          : repo.edit(addUserId: user.userId),
    );
  }

  /// Optimistic set toggle with rollback on failure. The error propagates
  /// so callers (card sheet, management page) can surface it.
  Future<void> _serverToggle({
    required MuteKey key,
    required MuteState Function() apply,
    required MuteState Function() revert,
    required Future<void> Function(MuteRepository repo) edit,
  }) async {
    await _hydrated;
    if (state.pending.contains(key)) return;
    state = state.copyWith(pending: {...state.pending, key});
    state = apply();
    try {
      _requireAccountId();
      await edit(ref.read(muteRepositoryProvider));
    } on Object {
      state = revert();
      rethrow;
    } finally {
      state = state.copyWith(pending: {...state.pending}..remove(key));
    }
  }

  Future<void> _persistWorks(String accountId, Set<int> workIds) async {
    await ref
        .read(sharedPreferencesProvider)
        .setString(_worksKey(accountId), jsonEncode(workIds.toList()));
  }
}

final muteStoreProvider = NotifierProvider<MuteStore, MuteState>(MuteStore.new);
