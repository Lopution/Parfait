import 'package:meta/meta.dart';

/// Which platform owns the preserved partial output behind a [ResumeAnchor].
/// The kind tells a [ResumableDownloadSinkFactory] how to interpret
/// [ResumeAnchor.locator]; unknown kinds fail closed at parse time.
enum ResumeAnchorKind {
  /// MediaStore pending row; locator is the row id.
  mediaStore,

  /// SAF tree document staged as `<name>.part`; locator is the document URI.
  saf,

  /// Desktop filesystem `<name>.part` file; locator is the file path.
  file,
}

/// Opaque durable token for a preserved partial output.
///
/// A [ResumableDownloadSink.detach] hands this back instead of deleting its
/// bytes. The recovery record persists it verbatim; a later attempt passes it
/// to [ResumableDownloadSinkFactory.resumeOwned] to reopen the same output
/// for appending. The manager never interprets the locator — only the owning
/// platform sink does.
@immutable
class ResumeAnchor {
  const ResumeAnchor({
    required this.kind,
    required this.locator,
    required this.storedBytes,
  });

  final ResumeAnchorKind kind;

  /// Platform-owned identity: MediaStore row id, SAF document URI, or a
  /// filesystem path. Never a credential.
  final String locator;

  /// Bytes durably committed at detach time. A resumed sink whose platform
  /// byte count differs is stale and must be discarded.
  final int storedBytes;

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'locator': locator,
    'storedBytes': storedBytes,
  };

  factory ResumeAnchor.fromJson(Map<String, dynamic> json) {
    final kindName = json['kind'];
    final kind = ResumeAnchorKind.values.where(
      (value) => value.name == kindName,
    );
    final locator = json['locator'];
    final storedBytes = json['storedBytes'];
    if (kind.isEmpty || locator is! String || storedBytes is! int) {
      throw const FormatException('invalid resume anchor payload');
    }
    return ResumeAnchor(
      kind: kind.first,
      locator: locator,
      storedBytes: storedBytes,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ResumeAnchor &&
      other.kind == kind &&
      other.locator == locator &&
      other.storedBytes == storedBytes;

  @override
  int get hashCode => Object.hash(kind, locator, storedBytes);
}
