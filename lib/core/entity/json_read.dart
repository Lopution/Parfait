/// Shared JSON field readers (C5c single owner).
///
/// Two families:
/// - `read*` are lenient: a wrong type or an empty value collapses to null
///   (feed payloads legitimately omit optional fields).
/// - `require*` throw [FormatException]: the field is part of the wire
///   contract, and its absence is a parser bug.
///
/// Containers normalize to `Map<String, Object?>`; `jsonDecode` output
/// (`Map<String, dynamic>`) satisfies that type at runtime.
library;

String? readOptionalString(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

/// Lenient `next_url` read shared by paginated feed repositories.
String? readNextUrl(Object? value) => readOptionalString(value);

/// Strict `next_url` read: the field must be a string or absent.
String? requireNextUrl(Object? value) {
  if (value == null) return null;
  if (value is String && value.isNotEmpty) return value;
  throw const FormatException('next_url must be a string or null');
}

/// Positive integer, accepting numeric strings; null when unparsable.
int? readPositiveInt(Object? value) {
  final parsed = value is int ? value : int.tryParse('$value');
  return parsed == null || parsed <= 0 ? null : parsed;
}

int requireParsedPositiveInt(Object? value, String field) {
  final parsed = value is int ? value : int.tryParse('$value');
  if (parsed != null && parsed > 0) return parsed;
  throw FormatException('$field must be a positive integer');
}

int requirePositiveInt(Object? value, String field) {
  if (value is int && value > 0) return value;
  throw FormatException('$field must be a positive integer');
}

int requireNonNegativeInt(Object? value, String field) {
  if (value is int && value >= 0) return value;
  throw FormatException('$field must be a non-negative integer');
}

/// Lenient counter read: unparsable or negative values collapse to zero.
int readNonNegativeIntOrZero(Object? value) {
  final parsed = value is int ? value : int.tryParse('$value');
  return parsed == null || parsed < 0 ? 0 : parsed;
}

Map<String, Object?> readMap(Object? value) =>
    value is Map<String, Object?> ? value : const <String, Object?>{};

String? readFirstString(Map<String, Object?>? values, List<String> keys) {
  if (values == null) return null;
  for (final key in keys) {
    final value = readOptionalString(values[key]);
    if (value != null) return value;
  }
  return null;
}

/// First non-blank value, trimmed (search keyword payloads).
String? readFirstTrimmedString(Map<String, Object?> values, List<String> keys) {
  for (final key in keys) {
    final item = values[key];
    if (item is String && item.trim().isNotEmpty) return item.trim();
  }
  return null;
}

String requireString(Object? value, String field) {
  if (value is! String || value.isEmpty) {
    throw FormatException('$field must be a non-empty string');
  }
  return value;
}
