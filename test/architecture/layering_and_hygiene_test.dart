// Layering & test-hygiene static scans:
//   - lib/ import graph & compile-graph decoupling rules R1–R8 (ARCH-01, ARCH-02)
//   - test/ hygiene guards (TEST-04, TEST-05, TEST-07, TEST-09, TEST-10, TEST-11):
//     * file size <= 1500 lines
//     * unique test doubles (by name & body), no app repository doubles
//     * no skipped cases, socket tests tagged, preferences via helpers
//     * no real sleeps, no fixed-round non-zero Future.delayed polling loops
//     * no roadmap-phase test filenames
//     * no raw isolate-backed databaseFactoryFfi in widget tests

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '_source_cache.dart';

// ── Layering rules (ARCH-01 / ARCH-02) ──────────────────────────────────────

const _package = 'parfait';

const _appFeatureFacades = <String>{
  'lib/app/navigation/routes.dart',
  'lib/app/navigation/me_workspace_facade.dart',
};

const _routesAllowedImporters = <String>{
  'lib/app/app.dart',
  'lib/app/external_intent_bridge.dart',
};

const _meWorkspaceAllowedImporters = <String>{
  'lib/features/settings/me_dashboard_page.dart',
};

const _commandBarAllowedImporters = <String>{'lib/app/app.dart'};

final _importOrExportRegExp = RegExp(
  r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''',
  multiLine: true,
);
final _exportRegExp = RegExp(
  r'''^\s*export\s+['"]([^'"]+)['"]''',
  multiLine: true,
);
final _partRegExp = RegExp(r'''^\s*part\s+['"]([^'"]+)['"]''', multiLine: true);

const _allowListedEdges = <String>{};
const _allowListedDataFiles = <String>{};
const _allowListedWidgetFiles = <String>{};

// ── File / library size & platform-probe ratchets ───────────────────────────

const _maxLibFileLines = 800;
const _maxLibLogicalLibraryLines = 1200;
const _grandfatheredSlackLines = 20;

bool _isGeneratedLibFile(String path) =>
    path.startsWith('lib/l10n/app_localizations') ||
    path == 'lib/l10n/lookup.dart' ||
    path == 'lib/app/icons/app_icons.dart' ||
    path.endsWith('.g.dart') ||
    path.endsWith('.freezed.dart') ||
    path.contains('/rust_generated/');

int _lineCount(String src) {
  if (src.isEmpty) return 0;
  final breaks = '\n'.allMatches(src).length;
  return src.endsWith('\n') ? breaks : breaks + 1;
}

/// Legacy `lib/` files above [_maxLibFileLines] pinned at their current size
/// plus 20-line slack. New files must stay `<= 800` lines; entries must be
/// removed as files are modularized below 800 lines.
const _grandfatheredFileLineCaps = <String, int>{
  'lib/app/motion/app_overlays.dart': 1288,
  'lib/app/motion/hero_transition.dart': 1293,
  'lib/app/navigation/func_page.dart': 1454,
  'lib/app/navigation/route_branches.dart': 998,
  'lib/app/pixiv_image.dart': 1281,
  'lib/app/widgets/bookmark_switch_button.dart': 915,
  'lib/app/widgets/comment_composer.dart': 872,
  'lib/app/widgets/feed/feed_selection.dart': 820,
  'lib/app/widgets/feed/illust_card.dart': 896,
  'lib/app/widgets/func_bottom_nav.dart': 836,
  'lib/app/widgets/home_branch_stack.dart': 888,
  'lib/app/widgets/ranking_category_sheet.dart': 909,
  'lib/app/widgets/shell_rail.dart': 849,
  'lib/core/download/download_manager.dart': 1823,
  'lib/core/network/compat/network_policy.dart': 886,
  'lib/core/network/compat/network_policy_ladder.dart': 1179,
  'lib/core/network/compat/secure_resolver.dart': 831,
  'lib/core/novel/novel_entity.dart': 1905,
  'lib/core/paging/paged_feed_controller.dart': 911,
  'lib/core/search/search_models.dart': 969,
  'lib/core/settings/app_settings.dart': 1070,
  'lib/features/illust/detail/illust_detail_pager_page.dart': 1040,
  'lib/features/illust/detail/ugoira_viewer.dart': 1002,
  'lib/features/illust/detail/widgets/page_image.dart': 1062,
  'lib/features/illust/viewer/image_viewer_page.dart': 1549,
  'lib/features/novel/novel_layout.dart': 1756,
  'lib/features/novel/novel_reader.dart': 1224,
  'lib/features/novel/novel_reader_stage.dart': 1149,
  'lib/features/profile/profile_header_delegate.dart': 1188,
  'lib/features/profile/user_page.dart': 1087,
  'lib/features/search/search_filter_sheet.dart': 934,
  'lib/features/search/search_page.dart': 824,
  'lib/features/search/search_result_page.dart': 869,
  'lib/features/settings/network_settings_page.dart': 886,
  'lib/features/settings/settings_page.dart': 981,
};

/// Legacy `part`-based logical libraries above [_maxLibLogicalLibraryLines]
/// pinned at their summed line count plus 20-line slack.
const _grandfatheredLibraryLineCaps = <String, int>{
  'lib/app/motion/hero_transition.dart': 2198,
  'lib/app/navigation/routes.dart': 1372,
  'lib/core/download/download_manager.dart': 2042,
  'lib/core/network/compat/network_policy.dart': 2427,
  'lib/features/illust/viewer/image_viewer_page.dart': 2276,
  'lib/features/novel/novel_reader.dart': 1881,
  'lib/features/novel/novel_reader_stage.dart': 1809,
  'lib/features/profile/user_page.dart': 1297,
  'lib/features/settings/pages/download_tasks_page.dart': 1280,
};

final _partOfRegExp = RegExp(r'^\s*part\s+of\b', multiLine: true);
final _platformProbe = RegExp(
  r'\b(?:Platform\.is[A-Z]\w*|defaultTargetPlatform)\b',
);
final _importDirective = RegExp(r'^\s*import\s+[^;]+;', multiLine: true);

const _platformProbeAllowedDirs = <String>[
  'lib/core/platform/',
  'lib/app/window/',
  'lib/app/layout/',
  'lib/app/haptics/',
];

/// Shrinking allow-list of files outside platform-adapter directories that
/// legitimately read `Platform.is*` or `defaultTargetPlatform`.
const _platformProbeAllowList = <String>{
  'lib/app/dev_shell/dev_shell.dart',
  'lib/app/motion/app_overlays.dart',
  'lib/app/scroll_behavior.dart',
  'lib/app/widgets/app_top_bar.dart',
  'lib/app/widgets/display_actions.dart',
  'lib/core/sqlite/sqlite_database.dart',
  'lib/features/settings/pages/motion_settings_page.dart',
  'lib/features/settings/settings_catalog.dart',
};

// ── Test hygiene rules ──────────────────────────────────────────────────────

const _maxFileLines = 1500;
const _self = 'test/architecture/layering_and_hygiene_test.dart';

final _doubleClass = RegExp(
  r'^(?:abstract |base |final |sealed |interface )*class _?('
  r'(?:Fake|Stub|Recording|Scripted|Failing|Spy|Counting|Mock|Throwing|'
  r'Unused|Switchable|Memory|InMemory|Static|Blocking|Controlled|Manual|'
  r'Capturing)[A-Z]\w*)',
  multiLine: true,
);

final _repositoryDouble = RegExp(
  r'^(?:abstract |base |final |sealed |interface )*class (\w+)[^{;]*'
  r'\b(?:extends|implements|with)\b[^{;]*?\b(\w*Repository)\b',
  multiLine: true,
);

final _topClass = RegExp(
  r'^(?:abstract |base |final |sealed |interface )*class (\w+)[^{;]*\{',
  multiLine: true,
);
final _widgetClass = RegExp(
  r'extends (?:State<|StatelessWidget|StatefulWidget|ConsumerWidget|'
  r'ConsumerStatefulWidget|ConsumerState<)',
);

const _sameBody = 0.8;
const _minBodyLines = 10;
final _skip = RegExp(r'(?<![\w.])skip:|@Skip\(');
final _sleep = RegExp(r'(?<![\w.])sleep\(');

final _ownPreferences = RegExp(
  r'SharedPreferencesAsyncPlatform\.instance\s*=(?!=)|'
  r'\binstallMemoryPreferences(?:\(\s*\)|(?!\())',
);
const _preferencesHelper = 'test/helpers/test_preferences.dart';
final _socket = RegExp(
  r'\b(?:HttpServer|(?:Raw)?(?:Secure)?ServerSocket|RawDatagramSocket)'
  r'\.bind|\b(?:Raw)?(?:Secure)?Socket\.(?:connect|startConnect)\(',
);
final _socketTag = RegExp(r"^@Tags\(\[[^\]]*'socket'", multiLine: true);

/// Roadmap/audit phase filenames that bundle unrelated features and drift out
/// of module ownership.
final _phaseTestName = RegExp(
  r'(?:^|/)(?:.*(?:phase\d+|matrix_gate|p0_p1)|.*_audit)_test\.dart$',
  caseSensitive: false,
);

/// A `for`/`while` loop body containing a non-zero `Future.delayed(Duration(...))`.
/// Zero-delay yields (`Duration.zero`) drain microtasks and are fine.
final _fixedDelayLoop = RegExp(
  r'\b(?:for|while)\s*\([^)]*\)\s*\{[^{}]{0,400}'
  r'Future(?:<[^>]+>)?\.delayed\(\s*(?:const\s+)?Duration\(',
  dotAll: true,
);

/// Files permitted to loop over non-zero `Future.delayed`: the shared
/// condition-driven `pumpIoUntil` waiter, the review harness's image-decode
/// / streaming chunk pacing, and the real-socket image worker isolate test
/// releasing held loopback responses.
const _delayedLoopAllowList = <String>{
  'test/helpers/waits.dart',
  'test/image_worker_host_test.dart',
  'test/review/review_support.dart',
  'test/review/review_world.dart',
};

/// Raw isolate-backed `databaseFactoryFfi` (not `databaseFactoryFfiNoIsolate`).
final _rawFfiDb = RegExp(r'\bdatabaseFactoryFfi\b');

/// Widget-containing test files explicitly verifying on-disk SQLite
/// persistence/backup behavior across isolates.
const _widgetFfiDbAllowList = <String>{
  'test/backup_test.dart',
  'test/watch_later_store_test.dart',
};

// ── Helpers ─────────────────────────────────────────────────────────────────

const _packagePrefix = 'package:$_package/';

String? _resolveUri(String fromFile, String uri) {
  if (uri.startsWith(_packagePrefix)) {
    final cand = 'lib/${uri.substring(_packagePrefix.length)}';
    return File(cand).existsSync() ? cand : null;
  }
  if (uri.startsWith('package:') || uri.startsWith('dart:')) return null;
  final base = fromFile.substring(0, fromFile.lastIndexOf('/'));
  final resolved = Uri.parse('$base/$uri').normalizePath().toString();
  return File(resolved).existsSync() ? resolved : null;
}

String _layerOf(String path) {
  if (!path.startsWith('lib/')) return 'other';
  final parts = path.split('/');
  if (parts[1] == 'core' || parts[1] == 'features' || parts[1] == 'app') {
    return parts[1];
  }
  return 'lib-root';
}

String _featureOf(String path) {
  final parts = path.split('/');
  if (parts.length >= 3 && parts[0] == 'lib' && parts[1] == 'features') {
    return parts[2];
  }
  return '';
}

Iterable<({String path, String name, List<String> lines})> _classBodies(
  Map<String, String> sources,
) sync* {
  for (final MapEntry(key: path, value: source) in sources.entries) {
    for (final match in _topClass.allMatches(source)) {
      if (_widgetClass.hasMatch(match[0]!)) continue;
      final name = match[1]!;
      final end = source.indexOf('\n}', match.start);
      if (end < 0) continue;
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
  final libSources = ArchSourceCache.libRaw();
  final libNoComments = ArchSourceCache.libNoComments();
  final testSources = {
    for (final MapEntry(key: path, value: src)
        in ArchSourceCache.testRaw().entries)
      if (path != _self) path: src,
  };

  test(
    'lib import graph respects layering rules (allow-list must shrink to empty)',
    () {
      final edges = <String>{};
      final exportEdges = <String>{};
      final dataLayerFiles = <String>{};
      final widgetFiles = <String>{};

      final sharedWidgetPattern = RegExp(
        r'^\s*class\s+_(?:\w*)(?:Tail|Error|Empty|Card|Status|Placeholder)\b',
        multiLine: true,
      );

      for (final MapEntry(key: f, value: src) in libSources.entries) {
        for (final m in _importOrExportRegExp.allMatches(src)) {
          final to = _resolveUri(f, m.group(1)!);
          if (to != null && to.startsWith('lib/')) edges.add('$f -> $to');
        }
        for (final m in _exportRegExp.allMatches(src)) {
          final to = _resolveUri(f, m.group(1)!);
          if (to != null && to.startsWith('lib/')) {
            exportEdges.add('$f -> $to');
          }
        }
        for (final m in _partRegExp.allMatches(src)) {
          final to = _resolveUri(f, m.group(1)!);
          if (to != null && to.startsWith('lib/')) edges.add('$f -> $to');
        }
        if (f.startsWith('lib/features/')) {
          if (RegExp(
            r'(?:repository|_controller|_models)\.dart$',
          ).hasMatch(f)) {
            dataLayerFiles.add(f);
          }
          if (sharedWidgetPattern.hasMatch(src)) {
            widgetFiles.add(f);
          }
        }
      }

      final violations = <String>{};
      final compileCouplingViolations = <String>{};
      for (final e in edges) {
        final parts = e.split(' -> ');
        final from = parts[0];
        final to = parts[1];
        final fromLayer = _layerOf(from);
        final toLayer = _layerOf(to);
        if (fromLayer == 'core' &&
            (toLayer == 'features' || toLayer == 'app')) {
          violations.add(e);
        } else if (fromLayer == 'features' && toLayer == 'features') {
          if (_featureOf(from) != _featureOf(to)) violations.add(e);
        } else if (fromLayer == 'app' && toLayer == 'features') {
          if (!_appFeatureFacades.contains(from)) violations.add(e);
        }

        if (to == 'lib/app/navigation/routes.dart' &&
            !_routesAllowedImporters.contains(from)) {
          compileCouplingViolations.add('R6 $e');
        }
        if (to == 'lib/app/navigation/me_workspace_facade.dart' &&
            !_meWorkspaceAllowedImporters.contains(from)) {
          compileCouplingViolations.add('R3-scope $e');
        }
        if (to == 'lib/app/window/desktop_command_bar.dart' &&
            !_commandBarAllowedImporters.contains(from)) {
          compileCouplingViolations.add('R8 $e');
        }
      }

      for (final e in exportEdges) {
        final parts = e.split(' -> ');
        if (parts[0] == 'lib/app/navigation/routes.dart' &&
            _layerOf(parts[1]) == 'features') {
          compileCouplingViolations.add('R7 $e');
        }
      }

      final unlisted = violations.difference(_allowListedEdges);
      final unlistedData = dataLayerFiles.difference(_allowListedDataFiles);
      final unlistedWidgets = widgetFiles.difference(_allowListedWidgetFiles);

      expect(
        unlisted,
        isEmpty,
        reason:
            'ARCH-01 layering violations — navigate through '
            'lib/app/navigation/route_facade.dart, keep core free of '
            'app/features:\n${unlisted.join('\n')}',
      );
      expect(
        compileCouplingViolations,
        isEmpty,
        reason:
            'ARCH-01 compile-graph decoupling violations (R6/R7/R8) — import '
            'narrow facade/scope libraries instead of routes.dart or '
            'desktop_command_bar.dart:\n'
            '${compileCouplingViolations.join('\n')}',
      );
      expect(
        unlistedData,
        isEmpty,
        reason:
            'ARCH-02 data-layer files under features/ — move them to '
            'lib/core/<domain>/:\n${unlistedData.join('\n')}',
      );
      expect(
        unlistedWidgets,
        isEmpty,
        reason:
            'ARCH-02 shared-component widgets in features/ — use or extend '
            'the lib/app/widgets/ component:\n${unlistedWidgets.join('\n')}',
      );
    },
  );

  test('test files stay under $_maxFileLines lines', () {
    final long = [
      for (final MapEntry(key: path, value: source) in testSources.entries)
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
    for (final MapEntry(key: path, value: source) in testSources.entries) {
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
    final bodies = _classBodies(testSources).toList();
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

  test('no test double stands in for an app repository', () {
    expect(
      [
        for (final MapEntry(key: path, value: source) in testSources.entries)
          for (final match in _repositoryDouble.allMatches(source))
            '$path ${match[1]} (${match[2]})',
      ],
      isEmpty,
      reason:
          'TEST-10 run the app\'s repository over a fake boundary: PixivApi '
          'routes for the App API, in-memory preferences or databases for '
          'stored data',
    );
  });

  test('no skipped cases', () {
    expect(
      [
        for (final MapEntry(key: path, value: source) in testSources.entries)
          if (_skip.hasMatch(source)) path,
      ],
      isEmpty,
      reason: 'TEST-04 fix or delete the case instead of skipping it',
    );
  });

  test('socket tests carry the socket tag', () {
    final untagged = [
      for (final MapEntry(key: path, value: source) in testSources.entries)
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

  test('no file sets empty preferences of its own', () {
    expect(
      [
        for (final MapEntry(key: path, value: source) in testSources.entries)
          if (path != _preferencesHelper &&
              !path.endsWith('/flutter_test_config.dart') &&
              _ownPreferences.hasMatch(source))
            path,
      ],
      isEmpty,
      reason:
          'TEST-09 install values with installMemoryPreferences(data), a '
          'failing or gated platform with installPreferencesForTest',
    );
  });

  test('no real sleeps', () {
    expect(
      [
        for (final MapEntry(key: path, value: source) in testSources.entries)
          if (_sleep.hasMatch(source)) path,
      ],
      isEmpty,
      reason:
          'TEST-11 sleep blocks the isolate; advance fake time with '
          'fakeAsync or tester.pump(duration)',
    );
  });

  test('no roadmap-phase test filenames', () {
    final bad = [
      for (final path in testSources.keys)
        if (_phaseTestName.hasMatch(path)) path,
    ];
    expect(
      bad,
      isEmpty,
      reason:
          'TEST-05 name test files after the module or feature they verify, '
          'not roadmap phases or audit passes',
    );
  });

  test('no fixed-round Future.delayed polling loops', () {
    final bad = [
      for (final MapEntry(key: path, value: source) in testSources.entries)
        if (!_delayedLoopAllowList.contains(path) &&
            _fixedDelayLoop.hasMatch(source))
          path,
    ];
    expect(
      bad,
      isEmpty,
      reason:
          'TEST-11 wait on a condition with pumpIoUntil or yield with '
          'Duration.zero instead of looping fixed Future.delayed durations',
    );
  });

  test('no raw databaseFactoryFfi in widget tests', () {
    final bad = [
      for (final MapEntry(key: path, value: source) in testSources.entries)
        if (path != 'test/flutter_test_config.dart' &&
            !_widgetFfiDbAllowList.contains(path) &&
            source.contains('testWidgets(') &&
            _rawFfiDb.hasMatch(source))
          path,
    ];
    expect(
      bad,
      isEmpty,
      reason:
          'TEST-07 widget tests must use default in-memory no-isolate SQLite '
          '(databaseFactoryFfiNoIsolate); keep on-disk isolate FFI databases '
          'in dedicated persistence unit tests',
    );
  });

  test('lib file and logical-library size ratchet (800L / 1200L)', () {
    final counts = <String, int>{
      for (final MapEntry(key: path, value: src) in libSources.entries)
        if (!_isGeneratedLibFile(path)) path: _lineCount(src),
    };
    final fileViolations = <String>[];
    for (final MapEntry(key: path, value: lines) in counts.entries) {
      final cap = _grandfatheredFileLineCaps[path] ?? _maxLibFileLines;
      if (lines > cap) {
        fileViolations.add('  $path: $lines lines (cap $cap)');
      }
    }
    final staleFileCaps = <String>[
      for (final MapEntry(key: path, value: cap)
          in _grandfatheredFileLineCaps.entries)
        if ((counts[path] ?? 0) <= _maxLibFileLines)
          '  $path (${counts[path] ?? 0} lines <= $_maxLibFileLines; remove entry)'
        else if (counts[path]! + _grandfatheredSlackLines < cap)
          '  $path (${counts[path]} lines; lower cap from $cap to ${counts[path]! + _grandfatheredSlackLines})',
    ];

    final libraryTotals = <String, int>{};
    for (final MapEntry(key: path, value: src) in libSources.entries) {
      if (_isGeneratedLibFile(path) || _partOfRegExp.hasMatch(src)) continue;
      final parts = _partRegExp.allMatches(src).toList();
      if (parts.isEmpty) continue;
      var total = counts[path] ?? 0;
      for (final m in parts) {
        final target = _resolveUri(path, m.group(1)!);
        if (target != null && counts.containsKey(target)) {
          total += counts[target]!;
        }
      }
      libraryTotals[path] = total;
    }
    final libViolations = <String>[];
    for (final MapEntry(key: path, value: total) in libraryTotals.entries) {
      final cap =
          _grandfatheredLibraryLineCaps[path] ?? _maxLibLogicalLibraryLines;
      if (total > cap) {
        libViolations.add('  $path (+ parts): $total lines (cap $cap)');
      }
    }
    final staleLibCaps = <String>[
      for (final MapEntry(key: path, value: cap)
          in _grandfatheredLibraryLineCaps.entries)
        if ((libraryTotals[path] ?? 0) <= _maxLibLogicalLibraryLines)
          '  $path (${libraryTotals[path] ?? 0} lines <= $_maxLibLogicalLibraryLines; remove entry)'
        else if (libraryTotals[path]! + _grandfatheredSlackLines < cap)
          '  $path (${libraryTotals[path]} lines; lower cap from $cap to ${libraryTotals[path]! + _grandfatheredSlackLines})',
    ];

    expect(
      fileViolations,
      isEmpty,
      reason:
          'lib/ files must stay <= $_maxLibFileLines lines (extract real '
          'modules, not part files):\n${fileViolations.join('\n')}',
    );
    expect(
      staleFileCaps,
      isEmpty,
      reason:
          'Remove shrunk/deleted files from _grandfatheredFileLineCaps so the '
          'ratchet tightens:\n${staleFileCaps.join('\n')}',
    );
    expect(
      libViolations,
      isEmpty,
      reason:
          'Logical part libraries must stay <= $_maxLibLogicalLibraryLines '
          'lines:\n${libViolations.join('\n')}',
    );
    expect(
      staleLibCaps,
      isEmpty,
      reason:
          'Remove shrunk/unsplit libraries from _grandfatheredLibraryLineCaps '
          'so the ratchet tightens:\n${staleLibCaps.join('\n')}',
    );
  });

  test('platform probes stay inside platform adapter directories', () {
    final hits = <String>{};
    for (final MapEntry(key: path, value: src) in libNoComments.entries) {
      if (_isGeneratedLibFile(path)) continue;
      if (_platformProbeAllowedDirs.any(path.startsWith)) continue;
      final body = src.replaceAll(_importDirective, '');
      if (_platformProbe.hasMatch(body)) hits.add(path);
    }
    final unapproved = hits.difference(_platformProbeAllowList);
    final stale = _platformProbeAllowList.difference(hits);
    expect(
      unapproved,
      isEmpty,
      reason:
          'Use PlatformCaps / Theme.of(context).platform instead of raw '
          'Platform.is* or defaultTargetPlatform outside adapter dirs:\n'
          '${unapproved.join('\n')}',
    );
    expect(
      stale,
      isEmpty,
      reason:
          'Remove cleaned files from _platformProbeAllowList so the ratchet '
          'tightens:\n${stale.join('\n')}',
    );
  });
}
