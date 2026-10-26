import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../settings/preference_keys.dart';

import 'account.dart';

/// Raised when persisted account metadata cannot be trusted.
class AccountDataException implements Exception {
  AccountDataException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() =>
      'AccountDataException($message${cause == null ? '' : ', cause: $cause'})';
}

/// Result of loading persisted metadata.
class AccountMetadataSnapshot {
  const AccountMetadataSnapshot({required this.accounts, this.currentId});

  final List<Account> accounts;
  final String? currentId;
}

/// Plain (non-secret) account metadata persistence.
abstract class AccountMetadataRepository {
  Future<AccountMetadataSnapshot> load();
  Future<void> save(List<Account> accounts, String? currentId);
}

/// SharedPreferences-backed implementation with versioned keys.
///
/// Only [Account] metadata (never credentials) passes through here.
class PreferencesAccountMetadataRepository
    implements AccountMetadataRepository {
  PreferencesAccountMetadataRepository({
    required SharedPreferencesAsync preferences,
  }) : _preferences = preferences;

  static const int schemaVersion = 1;
  static const String _accountsKey = PreferenceKeys.accounts;
  static const String _currentKey = PreferenceKeys.accountsCurrent;

  final SharedPreferencesAsync _preferences;

  @override
  Future<AccountMetadataSnapshot> load() async {
    final rawList = await _preferences.getStringList(_accountsKey);
    final currentId = await _preferences.getString(_currentKey);
    if (rawList == null) {
      if (currentId != null) {
        throw AccountDataException('current account set without account list');
      }
      return const AccountMetadataSnapshot(accounts: []);
    }
    final accounts = <Account>[];
    for (final raw in rawList) {
      try {
        final json = jsonDecode(raw);
        if (json is! Map<String, dynamic>) {
          throw const FormatException('account entry is not an object');
        }
        accounts.add(Account.fromJson(json));
      } on FormatException catch (error) {
        throw AccountDataException('corrupt account metadata entry', error);
      } catch (error) {
        throw AccountDataException('corrupt account metadata entry', error);
      }
    }
    if (currentId != null &&
        !accounts.any((account) => account.id == currentId)) {
      throw AccountDataException('current account missing from list');
    }
    return AccountMetadataSnapshot(accounts: accounts, currentId: currentId);
  }

  /// Two keys, two writes, in an order where a failure or a death between
  /// them leaves loadable metadata with a current id from before or after:
  /// the current id first while the stored list holds it (a switch, a
  /// removal); the list first while the new list keeps the stored current
  /// id (an added account); otherwise cleared first and set last.
  @override
  Future<void> save(List<Account> accounts, String? currentId) async {
    if (currentId != null &&
        !accounts.any((account) => account.id == currentId)) {
      throw AccountDataException('cannot save current id outside account list');
    }
    final list = accounts
        .map((account) => jsonEncode(account.toJson()))
        .toList();
    final storedCurrent = await _preferences.getString(_currentKey);
    if (currentId == null || (await _storedIds()).contains(currentId)) {
      await _writeCurrent(currentId);
      await _preferences.setStringList(_accountsKey, list);
    } else if (storedCurrent == null ||
        accounts.any((account) => account.id == storedCurrent)) {
      await _preferences.setStringList(_accountsKey, list);
      await _writeCurrent(currentId);
    } else {
      await _preferences.remove(_currentKey);
      await _preferences.setStringList(_accountsKey, list);
      await _writeCurrent(currentId);
    }
  }

  Future<void> _writeCurrent(String? currentId) => currentId == null
      ? _preferences.remove(_currentKey)
      : _preferences.setString(_currentKey, currentId);

  /// The ids in the stored list; none when it is missing or unreadable.
  Future<Set<String>> _storedIds() async {
    final ids = <String>{};
    for (final raw
        in await _preferences.getStringList(_accountsKey) ?? const <String>[]) {
      try {
        if (jsonDecode(raw) case {'id': final String id}) ids.add(id);
      } on FormatException {
        // An unreadable entry holds no id this save could keep current.
      }
    }
    return ids;
  }
}
