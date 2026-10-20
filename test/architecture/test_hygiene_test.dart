// The test rules that a scan can hold: file size (TEST-05), no skipped
// cases (TEST-04), socket tests tagged (TEST-07), one definition per test
// double, by name and by body (TEST-10) and no real sleeps (TEST-11).
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

/// A top-level class; dart format closes it with `}` at column 0.
final _topClass = RegExp(
  r'^(?:abstract |base |final |sealed |interface )*class (\w+)[^{;]*\{',
  multiLine: true,
);
final _widgetClass = RegExp(
  r'extends (?:State<|StatelessWidget|StatefulWidget|ConsumerWidget|'
  r'ConsumerStatefulWidget|ConsumerState<)',
);

/// Two classes whose lines overlap this much are one double written twice.
const _sameBody = 0.8;
const _minBodyLines = 10;
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

/// Each non-widget top-level class's significant lines, with its own name
/// masked so a renamed copy still matches.
Iterable<({String path, String name, List<String> lines})> _classBodies(
  Map<String, String> sources,
) sync* {
  for (final MapEntry(key: path, value: source) in sources.entries) {
    for (final match in _topClass.allMatches(source)) {
      if (_widgetClass.hasMatch(match[0]!)) continue;
      final name = match[1]!;
      final end = source.indexOf('\n}', match.start);
      final lines = [
        for (final line in source.substring(match.start, end).split('\n'))
          if (line.trim().replaceAll(name, 'X') case final text
              when text.length > 3 && !text.startsWith('//'))
            text,
      ];
      if (lines.length >= _minBodyLines) {
        yield (path: path, name: name, lines: lines);
      }
    }
  }
}

/// The share of the shorter body's lines that the other body also has.
double _overlap(List<String> a, List<String> b) {
  final counts = <String, int>{};
  for (final line in a) {
    counts[line] = (counts[line] ?? 0) + 1;
  }
  var common = 0;
  for (final line in b) {
    if ((counts[line] ?? 0) > 0) {
      counts[line] = counts[line]! - 1;
      common++;
    }
  }
  return common / (a.length < b.length ? a.length : b.length);
}

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

  test('no test double is copied into a second file', () {
    final bodies = _classBodies(sources).toList();
    final copies = [
      for (final (i, a) in bodies.indexed)
        for (final b in bodies.skip(i + 1))
          if (a.path != b.path && _overlap(a.lines, b.lines) >= _sameBody)
            '${a.path} ${a.name} ~ ${b.path} ${b.name}',
    ];
    expect(
      copies,
      isEmpty,
      reason:
          'TEST-10 share one double from test/helpers/ (a parameter covers '
          'a small difference) instead of a near-copy',
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
