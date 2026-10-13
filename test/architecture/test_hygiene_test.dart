// The test rules that a scan can hold: file size (TEST-05), no skipped
// cases (TEST-04), socket tests tagged (TEST-07), one definition per test
// double (TEST-10) and no real sleeps (TEST-11).
// Asserted on test/ (repo-relative paths); fixtures are data, not code.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _maxFileLines = 1500;
const _self = 'test/architecture/test_hygiene_test.dart';

/// Class names that announce a test double. A private copy counts as the
/// same name: `_FakeX` in a test file duplicates `FakeX` in a helper.
final _doubleClass = RegExp(
  r'^(?:abstract |base |final |sealed |interface )*class _?('
  r'(?:Fake|Stub|Recording|Scripted|Failing|Spy|Counting|Mock|Throwing|'
  r'Unused|Switchable|Memory|InMemory|Static|Blocking|Controlled|Manual|'
  r'Capturing)[A-Z]\w*)',
  multiLine: true,
);
final _skip = RegExp(r'(?<![\w.])skip:|@Skip\(');
final _sleep = RegExp(r'(?<![\w.])sleep\(');
final _socket = RegExp(
  r'\b(?:HttpServer|(?:Raw)?(?:Secure)?ServerSocket|RawDatagramSocket)'
  r'\.bind|\b(?:Raw)?(?:Secure)?Socket\.(?:connect|startConnect)\(',
);
final _socketTag = RegExp(r"^@Tags\(\[[^\]]*'socket'", multiLine: true);

Map<String, String> _sources() => {
  for (final entity in Directory('test').listSync(recursive: true))
    if (entity is File &&
        entity.path.endsWith('.dart') &&
        !entity.path.startsWith('test/fixtures/') &&
        entity.path != _self)
      entity.path: entity.readAsStringSync(),
};

void main() {
  final sources = _sources();

  test('test files stay under $_maxFileLines lines', () {
    final long = [
      for (final MapEntry(key: path, value: source) in sources.entries)
        if ('\n'.allMatches(source).length case final lines
            when lines > _maxFileLines)
          '$path ($lines lines)',
    ];
    expect(
      long,
      isEmpty,
      reason:
          'TEST-05 split these by feature, with shared fakes in '
          'test/helpers/',
    );
  });

  test('each test double is defined once', () {
    final definitions = <String, List<String>>{};
    for (final MapEntry(key: path, value: source) in sources.entries) {
      for (final match in _doubleClass.allMatches(source)) {
        (definitions[match.group(1)!] ??= []).add(path);
      }
    }
    expect(
      {
        for (final MapEntry(key: name, value: paths) in definitions.entries)
          if (paths.length > 1) name: paths,
      },
      isEmpty,
      reason:
          'TEST-10 keep one copy in test/helpers/ and import it, or name a '
          'double that behaves differently after how it differs',
    );
  });

  test('no skipped cases', () {
    expect(
      [
        for (final MapEntry(key: path, value: source) in sources.entries)
          if (_skip.hasMatch(source)) path,
      ],
      isEmpty,
      reason: 'TEST-04 fix or delete the case instead of skipping it',
    );
  });

  test('socket tests carry the socket tag', () {
    final untagged = [
      for (final MapEntry(key: path, value: source) in sources.entries)
        if (_socket.hasMatch(source) &&
            !(path.endsWith('_test.dart') && _socketTag.hasMatch(source)))
          path,
    ];
    expect(
      untagged,
      isEmpty,
      reason:
          'TEST-07 open real sockets in the test file and tag it '
          "@Tags(['socket']) above `library;`",
    );
  });

  test('no real sleeps', () {
    expect(
      [
        for (final MapEntry(key: path, value: source) in sources.entries)
          if (_sleep.hasMatch(source)) path,
      ],
      isEmpty,
      reason:
          'TEST-11 sleep blocks the isolate; advance fake time with '
          'fakeAsync or tester.pump(duration)',
    );
  });
}
