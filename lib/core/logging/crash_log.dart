import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Local crash log (R3 — the pixes/Shaft convention: capture to a file on
/// disk; no remote telemetry SDK).
///
/// [install] hooks [FlutterError.onError] and is paired with
/// `runZonedGuarded(record, ...)` in `main` so framework and zone errors
/// both land in `crash.log` under the app support directory. Writes are
/// serialized through a queue so a burst of errors cannot interleave or
/// drop entries. The file is capped at [maxBytes]: past the cap the
/// newest half is kept so a spammy failure can never grow it unbounded.
/// Console output is preserved via [FlutterError.dumpErrorToConsole] so
/// logcat stays complete.
class CrashLog {
  CrashLog._();

  static const int maxBytes = 256 * 1024;
  static const String fileName = 'crash.log';

  static File? _file;
  static Future<void> _tail = Future<void>.value();

  /// Returns the log file for [directory] (created on first record).
  static File fileFor(Directory directory) =>
      File(p.join(directory.path, 'logs', fileName));

  /// Installs the [FlutterError.onError] hook. Safe to call once at
  /// startup after `WidgetsFlutterBinding.ensureInitialized()`.
  static void install(Directory directory) {
    _file = fileFor(directory);
    FlutterError.onError = (details) {
      record(details.exception, details.stack);
      FlutterError.dumpErrorToConsole(details);
    };
  }

  /// Pending write queue — tests await this to observe a completed write.
  @visibleForTesting
  static Future<void> get pending => _tail;

  /// Points the log at [file] without touching [FlutterError.onError] —
  /// the test seam; production always goes through [install].
  @visibleForTesting
  static void useFile(File? file) => _file = file;

  /// Appends one entry. Also usable as the `runZonedGuarded` onError.
  /// Never throws: a failing logger must not mask the original crash.
  static void record(Object error, [StackTrace? stack]) {
    final file = _file;
    if (file == null) return;
    _tail = _tail.then((_) => _append(file, error, stack)).catchError((_) {});
  }

  static Future<void> _append(
    File file,
    Object error,
    StackTrace? stack,
  ) async {
    await file.parent.create(recursive: true);
    if (await file.exists() && await file.length() > maxBytes) {
      // Rotate: keep the newest half of an oversize log.
      final bytes = await file.readAsBytes();
      await file.writeAsBytes(
        bytes.sublist(bytes.length - maxBytes ~/ 2),
        flush: true,
      );
    }
    final entry = StringBuffer()
      ..writeln('=== ${DateTime.now().toIso8601String()} ===')
      ..writeln(error);
    if (stack != null) entry.writeln(stack);
    await file.writeAsString(
      entry.toString(),
      mode: FileMode.append,
      flush: true,
    );
  }
}
