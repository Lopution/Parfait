import 'dart:convert';

import '../history/history_models.dart';
import '../mute/mute_models.dart';

/// How imported data is combined with the current account's state.
enum BackupImportStrategy {
  /// Server mute tags/users are added (the server list has no safe
  /// delete-all), local work mutes union, and history upserts keeping the
  /// newer `last_viewed_at`. Settings overwrite as a single object.
  merge,

  /// Settings overwrite, local work mutes are replaced by the imported set
  /// (server mute tags/users are still only added), and history is cleared
  /// for the current account before reinserting.
  overwrite,
}

/// Public, user-presentable import failure: the file is not a usable
/// `pixivfunc.backup.v1` payload.
class BackupImportException implements Exception {
  const BackupImportException(this.code, this.publicMessage, {this.cause});

  final BackupImportErrorCode code;
  final String publicMessage;
  final Object? cause;

  @override
  String toString() => 'BackupImportException(${code.name})';
}

enum BackupImportErrorCode {
  notJson,
  unknownSchema,
  malformedField,

  /// Apply-time failure: mutes and history are account-scoped, so an
  /// import with no signed-in account has no boundary to land in.
  accountRequired,
}

/// Versioned backup document covering settings, the effective mute set and
/// the local browsing history of one account.
///
/// `settings` stays a raw `AppSettings.toJson()` map: per-field validation
/// lives in `AppSettings.fromJson`, so a damaged setting degrades to the
/// current value instead of rejecting the whole file. Credentials never
/// enter this document — `AppSettings.toJson` carries `SecretSettingRef`
/// ids only.
class BackupEnvelope {
  const BackupEnvelope({
    required this.exportedAt,
    this.accountId,
    required this.settings,
    this.muteTags = const {},
    this.muteUsers = const [],
    this.muteWorkIds = const {},
    this.history = const [],
  });

  static const schema = 'pixivfunc.backup.v1';
  static const mimeType = 'application/json';

  /// Largest accepted document. History rows are bounded display records;
  /// anything past this is not a plausible export.
  static const maxEncodedLength = 64 * 1024 * 1024;

  final DateTime exportedAt;

  /// The account that produced the file. Informational only — imported
  /// mutes and history always land inside the *current* account boundary.
  final String? accountId;

  final Map<String, dynamic> settings;
  final Set<String> muteTags;
  final List<MutedUser> muteUsers;
  final Set<int> muteWorkIds;
  final List<HistoryRecord> history;

  static String fileName(DateTime now) {
    String two(int value) => value.toString().padLeft(2, '0');
    return 'pixiv-func-backup-'
        '${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}.json';
  }

  Map<String, Object?> toJson() => {
    'schema': schema,
    'exportedAt': exportedAt.toUtc().toIso8601String(),
    if (accountId != null) 'accountId': accountId,
    'settings': settings,
    'mutes': {
      'tags': muteTags.toList()..sort(),
      'users': [
        for (final user in muteUsers)
          {
            'userId': user.userId,
            'name': user.name,
            if (user.account != null) 'account': user.account,
          },
      ]..sort((a, b) => (a['userId'] as int).compareTo(b['userId'] as int)),
      'workIds': muteWorkIds.toList()..sort(),
    },
    'history': [for (final record in history) record.toColumns()],
  };

  /// Parses a file body. Every structural failure maps to one public
  /// [BackupImportException] — the file either is a well-formed v1
  /// document or it is not imported at all.
  factory BackupEnvelope.parse(List<int> bytes) {
    if (bytes.isEmpty || bytes.length > maxEncodedLength) {
      throw const BackupImportException(
        BackupImportErrorCode.notJson,
        'not a pixiv-func backup file',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on Object catch (error) {
      throw BackupImportException(
        BackupImportErrorCode.notJson,
        'file is not valid JSON',
        cause: error,
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw const BackupImportException(
        BackupImportErrorCode.notJson,
        'backup root is not an object',
      );
    }
    if (decoded['schema'] != schema) {
      throw const BackupImportException(
        BackupImportErrorCode.unknownSchema,
        'unsupported backup schema',
      );
    }

    final exportedAtRaw = decoded['exportedAt'];
    final exportedAt = exportedAtRaw is String
        ? DateTime.tryParse(exportedAtRaw)
        : null;
    if (exportedAt == null) {
      throw const BackupImportException(
        BackupImportErrorCode.malformedField,
        'exportedAt is missing or invalid',
      );
    }

    final accountId = decoded['accountId'];
    if (accountId != null && accountId is! String) {
      throw const BackupImportException(
        BackupImportErrorCode.malformedField,
        'accountId must be a string',
      );
    }

    final settings = decoded['settings'];
    if (settings != null && settings is! Map<String, dynamic>) {
      throw const BackupImportException(
        BackupImportErrorCode.malformedField,
        'settings must be an object',
      );
    }

    final mutes = decoded['mutes'];
    if (mutes != null && mutes is! Map<String, dynamic>) {
      throw const BackupImportException(
        BackupImportErrorCode.malformedField,
        'mutes must be an object',
      );
    }
    final mutesMap = mutes as Map<String, dynamic>? ?? const {};

    final historyRaw = decoded['history'];
    if (historyRaw != null && historyRaw is! List) {
      throw const BackupImportException(
        BackupImportErrorCode.malformedField,
        'history must be a list',
      );
    }

    return BackupEnvelope(
      exportedAt: exportedAt,
      accountId: accountId as String?,
      settings: settings as Map<String, dynamic>? ?? const {},
      muteTags: _readTags(mutesMap['tags']),
      muteUsers: _readUsers(mutesMap['users']),
      muteWorkIds: _readWorkIds(mutesMap['workIds']),
      history: _readHistory(historyRaw as List? ?? const []),
    );
  }

  List<int> encode() => utf8.encode(jsonEncode(toJson()));

  static Set<String> _readTags(Object? raw) {
    if (raw == null) return const {};
    if (raw is! List) throw _field('mutes.tags must be a list');
    return {
      for (final tag in raw)
        tag is String
            ? tag
            : throw _field('mutes.tags entries must be strings'),
    };
  }

  static List<MutedUser> _readUsers(Object? raw) {
    if (raw == null) return const [];
    if (raw is! List) throw _field('mutes.users must be a list');
    return [
      for (final entry in raw)
        entry is Map
            ? MutedUser(
                userId: entry['userId'] is num
                    ? (entry['userId'] as num).toInt()
                    : throw _field('mutes.users[].userId must be a number'),
                name: entry['name'] is String
                    ? entry['name'] as String
                    : throw _field('mutes.users[].name must be a string'),
                account: entry['account'] as String?,
              )
            : throw _field('mutes.users entries must be objects'),
    ];
  }

  static Set<int> _readWorkIds(Object? raw) {
    if (raw == null) return const {};
    if (raw is! List) throw _field('mutes.workIds must be a list');
    return {
      for (final id in raw)
        id is num && id > 0
            ? id.toInt()
            : throw _field('mutes.workIds entries must be positive numbers'),
    };
  }

  static List<HistoryRecord> _readHistory(List<Object?> raw) {
    return [
      for (final entry in raw)
        entry is Map<String, dynamic>
            ? _readHistoryRow(entry)
            : throw _field('history entries must be objects'),
    ];
  }

  static HistoryRecord _readHistoryRow(Map<String, dynamic> row) {
    try {
      return HistoryRecord.fromRow(row);
    } on Object catch (error) {
      throw BackupImportException(
        BackupImportErrorCode.malformedField,
        'history entry is malformed',
        cause: error,
      );
    }
  }

  static BackupImportException _field(String message) =>
      BackupImportException(BackupImportErrorCode.malformedField, message);
}
