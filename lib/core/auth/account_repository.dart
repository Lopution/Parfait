import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

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
class PreferencesAccountMetadataRepository implements AccountMetadataRepository {
  PreferencesAccountMetadataRepository({SharedPreferencesAsync? preferences})
      : _preferences = preferences ?? SharedPreferencesAsync();

  static const int schemaVersion = 1;
  static const String _accountsKey = 'replica.accounts.v1';
  static const String _currentKey = 'replica.accounts.current.v1';

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

  @override
  Future<void> save(List<Account> accounts, String? currentId) async {
    if (currentId != null &&
        !accounts.any((account) => account.id == currentId)) {
      throw AccountDataException('cannot save current id outside account list');
    }
    await _preferences.setStringList(
      _accountsKey,
      accounts.map((account) => jsonEncode(account.toJson())).toList(),
    );
    if (currentId == null) {
      await _preferences.remove(_currentKey);
    } else {
      await _preferences.setString(_currentKey, currentId);
    }
  }
}
