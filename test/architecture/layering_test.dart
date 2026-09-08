// Layering rules for lib/ (see .trellis/spec/frontend/directory-structure.md).
//
// Rules asserted on the import graph:
//   R1  lib/core/** must not import lib/features/** or lib/app/**
//   R2  lib/features/<a>/** must not import lib/features/<b>/** (a != b)
//       except lib/app/navigation/routes.dart (the approved facade)
//   R3  lib/app/** must not import lib/features/** except the facade
//   R4  lib/features/** must not own data-layer files
//       (*repository.dart, *_controller.dart, *_models.dart entity files)
//   R5  lib/features/** must not define shared-component widgets
//       (class _*Tail / _*Error / _*Empty / _*Card / _*Status / _*Placeholder)
//
// Violations found today are allow-listed below; every item must be removed as
// the corresponding refactor lands (child C, .trellis/tasks/09-07-dart-architecture-convergence).
// At the end of child C the allow-list must be empty.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _package = 'pixiv_func';

final _finalRegExp = RegExp(r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''', multiLine: true);
final _partRegExp = RegExp(r'''^\s*part\s+['"]([^'"]+)['"]''', multiLine: true);

/// (from-file, to-file) edges that are known violations, allow-listed until
/// the owning refactor lands. Format: "lib/... -> lib/...".
const _allowListedEdges = <String>{
  // R2: features a != b (C2 facade / C3 components / C4 move: 44 edges)
  'lib/features/illust/detail/related_illusts_section.dart -> lib/features/search/search_text.dart',
  'lib/features/onboarding/startup_gate.dart -> lib/features/home/home_page.dart',
  'lib/features/onboarding/startup_gate.dart -> lib/features/login/login_page.dart',
  'lib/features/search/search_result_page.dart -> lib/features/profile/follow_switch_button.dart',
  'lib/features/settings/settings_page.dart -> lib/features/profile/user_page.dart',

  // R3: app -> features (C2/C4: startup_gate moves to lib/app/)
  'lib/app/app.dart -> lib/features/onboarding/startup_gate.dart',
};

/// R4: data-layer files still under lib/features/ (C4 moves them to lib/core/).
const _allowListedDataFiles = <String>{};

/// R5: files defining shared-component private widgets (C3/C8 replaces them).
const _allowListedWidgetFiles = <String>{
  'lib/features/comments/comments_page.dart',
  'lib/features/onboarding/startup_gate.dart',
  'lib/features/new/new_page.dart',
  'lib/features/settings/settings_page.dart',
  'lib/features/settings/network_probe_page.dart',
  'lib/features/illust/detail/illust_detail_page.dart',
  'lib/features/search/search_page.dart',
  'lib/features/search/search_result_page.dart',
  'lib/features/home/recommended/recommended_home_page.dart',
  'lib/features/home/recommended/recommended_illust_page.dart',
  'lib/features/profile/user_page.dart',
  'lib/features/profile/profile_edit_page.dart',
  'lib/features/ranking/ranking_page.dart',
  'lib/features/history/history_page.dart',
  'lib/features/novel/novel_page.dart',
};

// ---------------------------------------------------------------------------

/// Returns repo-relative paths of all lib/*.dart files.
List<String> _dartFiles(String root) {
  final files = <String>[];
  void walk(Directory dir) {
    for (final e in dir.listSync()) {
      if (e is Directory) {
        walk(e);
      } else if (e is File && e.path.endsWith('.dart')) {
        files.add(e.path.substring(root.length + 1));
      }
    }
  }

  walk(Directory('$root/lib'));
  return files;
}

String? _resolveUri(String fromFile, String uri) {
  if (uri.startsWith('package:$_package/')) {
    final cand = 'lib/${uri.substring(_package.length + 8)}';
    return File(cand).existsSync() ? cand : null;
  }
  if (uri.startsWith('package:') || uri.startsWith('dart:')) return null;
  final base = fromFile.substring(0, fromFile.lastIndexOf('/'));
  final resolved = Uri.parse('$base/$uri').normalizePath().toString();
  return File(resolved).existsSync() ? resolved : null;
}

String _featureOf(String path) {
  final parts = path.split('/');
  if (parts.length >= 3 && parts[0] == 'lib' && parts[1] == 'features') {
    return parts[2];
  }
  return '';
}

void main() {
  test('lib import graph respects layering rules (allow-list must shrink to empty)', () {
    final files = _dartFiles(Directory.current.path);
    final edges = <String>{}; // "from -> to"
    final dataLayerFiles = <String>{};
    final widgetFiles = <String>{};

    final sharedWidgetPattern =
        RegExp(r'^\s*class\s+_(?:\w*)(?:Tail|Error|Empty|Card|Status|Placeholder)\b', multiLine: true);

    for (final f in files) {
      final src = File(f).readAsStringSync();
      for (final m in _finalRegExp.allMatches(src)) {
        final uri = m.group(1)!;
        final to = _resolveUri(f, uri);
        if (to != null && to.startsWith('lib/')) edges.add('$f -> $to');
      }
      for (final m in _partRegExp.allMatches(src)) {
        final uri = m.group(1)!;
        final to = _resolveUri(f, uri);
        if (to != null && to.startsWith('lib/')) edges.add('$f -> $to');
      }
      if (f.startsWith('lib/features/')) {
        if (RegExp(r'(?:repository|_controller|_models)\.dart$').hasMatch(f)) {
          dataLayerFiles.add(f);
        }
        if (sharedWidgetPattern.hasMatch(src)) {
          widgetFiles.add(f);
        }
      }
    }

    final violations = <String>{};
    for (final e in edges) {
      final parts = e.split(' -> ');
      final from = parts[0];
      final to = parts[1];
      final fromLayer = _layerOf(from);
      final toLayer = _layerOf(to);
      if (fromLayer == 'core' && (toLayer == 'features' || toLayer == 'app')) {
        violations.add(e);
      } else if (fromLayer == 'features' && toLayer == 'features') {
        final fa = _featureOf(from);
        final fb = _featureOf(to);
        if (fa != fb && to != 'lib/app/navigation/routes.dart') violations.add(e);
      } else if (fromLayer == 'app' && toLayer == 'features') {
        if (from != 'lib/app/navigation/routes.dart') violations.add(e);
      }
    }

    final unlisted = violations.difference(_allowListedEdges);
    final stale = _allowListedEdges.difference(violations);
    final unlistedData = dataLayerFiles.difference(_allowListedDataFiles);
    final unlistedWidgets = widgetFiles.difference(_allowListedWidgetFiles);

    expect(unlisted, isEmpty,
        reason: 'Layering violations not allow-listed:\n${unlisted.join('\n')}');
    expect(unlistedData, isEmpty,
        reason: 'Data-layer files still under features/ not allow-listed:\n${unlistedData.join('\n')}');
    expect(unlistedWidgets, isEmpty,
        reason: 'Shared-component widgets in features/ not allow-listed:\n${unlistedWidgets.join('\n')}');
    // Print remaining allow-list so the next refactor knows what to remove.
    if (stale.isNotEmpty) {
      // ignore: avoid_print
      print('Allow-list entries that no longer violate (remove them):\n${stale.join('\n')}');
    }
    // ignore: avoid_print
    print(
        'Still allow-listed: ${_allowListedEdges.length} edges, '
        '${_allowListedDataFiles.length} data files, ${_allowListedWidgetFiles.length} widget files.');
  });
}

String _layerOf(String path) {
  if (!path.startsWith('lib/')) return 'other';
  final parts = path.split('/');
  if (parts[1] == 'core' || parts[1] == 'features' || parts[1] == 'app') return parts[1];
  return 'lib-root';
}
