import 'dart:convert';

/// Schema version of [WidgetSnapshot]. Bump when the render model changes so
/// native readers can reject unknown payloads instead of guessing.
const int widgetSnapshotSchemaVersion = 1;

/// Defensive bounds shared by the Dart writer and native reader. The feed
/// loader currently stays below these limits, but the parser must also be
/// safe when an older process or a manually damaged file supplies input.
const int widgetSnapshotMaxItems = 8;
const int widgetSnapshotMaxTextLength = 512;
const int widgetSnapshotMaxAccountKeyLength = 128;

/// Versioned, secret-free render model handed to the Android home widgets.
///
/// The envelope carries only what a widget needs to draw and route a click:
/// illust id, title, author, a controlled image reference (a file name inside
/// the widget snapshot directory) and generation metadata. No URL, token,
/// cookie or credential ever enters this model, so leaking the file cannot
/// leak the account.
class WidgetSnapshotItem {
  const WidgetSnapshotItem({
    required this.illustId,
    required this.title,
    required this.userId,
    required this.userName,
    required this.imageFile,
  });

  final int illustId;
  final String title;
  final int userId;
  final String userName;

  /// File name (not path) inside the snapshot image directory.
  final String imageFile;

  Map<String, Object?> toJson() => <String, Object?>{
    'illustId': illustId,
    'title': title,
    'userId': userId,
    'userName': userName,
    'imageFile': imageFile,
  };

  /// Strict parse: structural violations throw instead of rendering garbage.
  static WidgetSnapshotItem parse(Object? json) {
    if (json is! Map<String, dynamic>) throw const WidgetSnapshotFormatError();
    final illustId = json['illustId'];
    final title = json['title'];
    final userId = json['userId'];
    final userName = json['userName'];
    final imageFile = json['imageFile'];
    if (illustId is! int ||
        title is! String ||
        userId is! int ||
        userName is! String ||
        imageFile is! String) {
      throw const WidgetSnapshotFormatError();
    }
    if (illustId <= 0 ||
        userId <= 0 ||
        title.length > widgetSnapshotMaxTextLength ||
        userName.length > widgetSnapshotMaxTextLength ||
        imageFile.isEmpty ||
        imageFile.contains('/') ||
        imageFile.contains('\\') ||
        imageFile.contains('..')) {
      throw const WidgetSnapshotFormatError();
    }
    return WidgetSnapshotItem(
      illustId: illustId,
      title: title,
      userId: userId,
      userName: userName,
      imageFile: imageFile,
    );
  }
}

class WidgetSnapshot {
  const WidgetSnapshot({
    required this.schemaVersion,
    required this.accountKey,
    required this.accountRevision,
    required this.generatedAtMs,
    required this.items,
  });

  factory WidgetSnapshot.create({
    required String accountKey,
    required int accountRevision,
    required DateTime generatedAt,
    required List<WidgetSnapshotItem> items,
  }) {
    return WidgetSnapshot(
      schemaVersion: widgetSnapshotSchemaVersion,
      accountKey: accountKey,
      accountRevision: accountRevision,
      generatedAtMs: generatedAt.millisecondsSinceEpoch,
      items: List.unmodifiable(items),
    );
  }

  final int schemaVersion;
  final String accountKey;
  final int accountRevision;
  final int generatedAtMs;
  final List<WidgetSnapshotItem> items;

  Duration age(DateTime now) =>
      now.difference(DateTime.fromMillisecondsSinceEpoch(generatedAtMs));

  /// Unknown schema versions cannot be rendered safely; the reader treats
  /// them like a corrupt file and falls back to the open-app state.
  bool get renderable =>
      schemaVersion == widgetSnapshotSchemaVersion && items.isNotEmpty;

  String encode() => jsonEncode(<String, Object?>{
    'schemaVersion': schemaVersion,
    'accountKey': accountKey,
    'accountRevision': accountRevision,
    'generatedAtMs': generatedAtMs,
    'items': <Object?>[for (final item in items) item.toJson()],
  });

  /// Strict parse of the whole envelope; every failure mode (wrong version,
  /// missing fields, malformed items) throws [WidgetSnapshotFormatError].
  static WidgetSnapshot parse(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      throw const WidgetSnapshotFormatError();
    }
    if (decoded is! Map<String, dynamic>) {
      throw const WidgetSnapshotFormatError();
    }
    final schemaVersion = decoded['schemaVersion'];
    final accountKey = decoded['accountKey'];
    final accountRevision = decoded['accountRevision'];
    final generatedAtMs = decoded['generatedAtMs'];
    final items = decoded['items'];
    if (schemaVersion is! int ||
        accountKey is! String ||
        accountRevision is! int ||
        generatedAtMs is! int ||
        items is! List<Object?>) {
      throw const WidgetSnapshotFormatError();
    }
    if (accountKey.isEmpty ||
        accountKey.length > widgetSnapshotMaxAccountKeyLength ||
        accountRevision < 0 ||
        items.length > widgetSnapshotMaxItems) {
      throw const WidgetSnapshotFormatError();
    }
    return WidgetSnapshot(
      schemaVersion: schemaVersion,
      accountKey: accountKey,
      accountRevision: accountRevision,
      generatedAtMs: generatedAtMs,
      items: [for (final item in items) WidgetSnapshotItem.parse(item)],
    );
  }
}

/// Raised for any structural, version or bound violation in a snapshot.
class WidgetSnapshotFormatError implements Exception {
  const WidgetSnapshotFormatError();

  @override
  String toString() => 'WidgetSnapshotFormatError';
}
