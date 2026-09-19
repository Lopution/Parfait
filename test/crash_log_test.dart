import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/logging/crash_log.dart';

void main() {
  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('crashlog_test');
    file = File('${dir.path}/crash.log');
    CrashLog.useFile(file);
  });

  tearDown(() {
    CrashLog.useFile(null);
    dir.deleteSync(recursive: true);
  });

  test('record appends timestamped entries with error and stack', () async {
    CrashLog.record(StateError('boom'), StackTrace.current);
    CrashLog.record('plain message');
    await CrashLog.pending;

    final content = file.readAsStringSync();
    expect(content, contains('Bad state'));
    expect(content, contains('boom'));
    expect(content, contains('plain message'));
    expect(content.split('===').length - 1, greaterThanOrEqualTo(2));
  });

  test('record without an installed file is a no-op', () {
    CrashLog.useFile(null);
    expect(() => CrashLog.record(Error()), returnsNormally);
  });

  test(
    'oversize file is rotated down to the newest half before append',
    () async {
      file.writeAsBytesSync(List.filled(CrashLog.maxBytes + 100, 0x61));
      CrashLog.record('after-rotation');
      await CrashLog.pending;

      final bytes = file.readAsBytesSync();
      expect(bytes.length, lessThan(CrashLog.maxBytes));
      expect(String.fromCharCodes(bytes), contains('after-rotation'));
    },
  );
}
