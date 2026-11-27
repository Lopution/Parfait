import 'dart:collection';

import 'dev_redaction.dart';

class DevLogEntry {
  const DevLogEntry({
    required this.seq,
    required this.timestampIso,
    required this.level,
    required this.source,
    required this.message,
  });

  final int seq;
  final String timestampIso;
  final String level;
  final String source;
  final String message;

  Map<String, Object?> toJson() => {
    'seq': seq,
    'timestamp': timestampIso,
    'level': level,
    'source': source,
    'message': message,
  };
}

/// Bounded in-memory telemetry ring buffer for `main_dev.dart`.
/// All messages pass through [redactDevText] before entering the buffer.
class DevTelemetry {
  DevTelemetry._();

  static final DevTelemetry instance = DevTelemetry._();

  static const int maxEntries = 300;

  final ListQueue<DevLogEntry> _entries = ListQueue<DevLogEntry>(maxEntries);
  int _nextSeq = 1;
  int _errorCount = 0;

  int get latestSeq => _nextSeq - 1;

  int get errorCount => _errorCount;

  List<DevLogEntry> recentErrors({int limit = 20}) {
    final errors = <DevLogEntry>[];
    for (final entry in _entries) {
      if (entry.level == 'error') errors.add(entry);
    }
    if (errors.length <= limit) return errors;
    return errors.sublist(errors.length - limit);
  }

  void record(
    String message, {
    String level = 'info',
    String source = 'app',
    DateTime? timestamp,
  }) {
    final sanitized = redactDevText(message);
    if (level == 'error') _errorCount += 1;
    final entry = DevLogEntry(
      seq: _nextSeq++,
      timestampIso: (timestamp ?? DateTime.now().toUtc()).toIso8601String(),
      level: level,
      source: source,
      message: sanitized,
    );
    if (_entries.length >= maxEntries) {
      _entries.removeFirst();
    }
    _entries.addLast(entry);
  }

  List<DevLogEntry> since(int afterSeq, {int limit = 100}) {
    final result = <DevLogEntry>[];
    for (final entry in _entries) {
      if (entry.seq > afterSeq) {
        result.add(entry);
        if (result.length >= limit) break;
      }
    }
    return result;
  }

  void clear() {
    _entries.clear();
    _errorCount = 0;
  }
}
