// UI convention & single-owner static scans over lib/ (and conflict-marker
// check over lib/, test/, .trellis/spec/):
//   - Feedback channels, overlays, haptics, clipboard, log(), system UI,
//     Hero tag family, hard-coded ms duration census (FB-02/04/10/12/14,
//     ERR-06, SYS-01, TRANS-07/09, MOTION-01)
//   - Icon style & IconButton tooltips (THEME-16, THEME-17)
//   - MotionTokens.resolve / MotionTokens.spring census (MOTION-01, MOTION-03)
//   - Spacing & corner-radius token scan (THEME-12)
//   - Settings ListTile census & retired SettingsSection (SET-01, SET-03)
//   - No segmented buttons (NAV-17)
//   - Page top bars go through AppTopBar (NAV-18)

import 'package:flutter_test/flutter_test.dart';

import '_source_cache.dart';

// ── Feedback channels & single-owner guards ─────────────────────────────────

const _promptHostCallSites = <String>{
  'lib/app/widgets/prompt_host.dart',
  'lib/app/widgets/app_snack_bar.dart',
  'lib/app/app.dart',
  'lib/app/widgets/undo_snack_bar.dart',
};

const _hapticsOwnerDir = 'lib/app/haptics/';

final _selectionControlOwners = <RegExp, Set<String>>{
  RegExp(r'(?<![A-Za-z])(?:ChoiceChip|FilterChip)\('): {
    'lib/app/widgets/app_choice_chip.dart',
  },
  RegExp(r'(?<![A-Za-z])(?:Slider|FSlider)(?:\.adaptive)?\('): {
    'lib/app/widgets/app_slider.dart',
  },
  RegExp(r'(?<![A-Za-z])(?:Switch|SwitchListTile|FSwitch)(?:\.adaptive)?\('): {
    'lib/app/widgets/settings/settings_control.dart',
    'lib/app/widgets/replica_switch_tile.dart',
  },
  RegExp(r'(?<![A-Za-z])(?:RadioListTile|Radio)\s*[<(]'): {
    'lib/app/widgets/settings/settings_choice_tile.dart',
  },
};

const _silentNavigationFiles = <String>{
  'lib/app/widgets/app_tab_bar.dart',
  'lib/app/widgets/func_bottom_nav.dart',
  'lib/app/widgets/tab_swipe_switcher.dart',
};

const _clipboardOwner = 'lib/app/clipboard.dart';
const _logOwner = 'lib/core/log.dart';
const _overlaysOwner = 'lib/app/motion/app_overlays.dart';
const _systemUiOwner = 'lib/app/system_ui.dart';
const _overlayAllowList = <String, Set<String>>{};

const _heroFiles = <String>{
  'lib/app/widgets/feed/illust_card.dart',
  'lib/app/widgets/user_preview_row.dart',
  'lib/features/illust/detail/widgets/page_image.dart',
  'lib/features/illust/detail/ugoira_viewer.dart',
  'lib/features/illust/viewer/image_viewer_page.dart',
  'lib/features/settings/me_recent_history.dart',
};

const _durationCensus = <String, int>{
  'lib/app/motion/motion_tokens.dart': 21,
  'lib/app/motion/page_transitions.dart': 1,
  'lib/app/widgets/prompt_host.dart': 1,
  'lib/app/window/desktop_window.dart': 2,
  'lib/app/navigation/keyboard_back.dart': 1,
  'lib/app/haptics/app_haptics.dart': 3,
  'lib/app/widgets/smooth_wheel_scroll.dart': 2,
  'lib/app/widgets/image_load_progress.dart': 1,
  'lib/app/widgets/feed/feed_states.dart': 1,
  'lib/app/widgets/comment_composer.dart': 1,
  'lib/features/illust/detail/illust_detail_pager_page.dart': 1,
  'lib/features/illust/detail/ugoira_viewer.dart': 1,
  'lib/features/settings/pages/frame_probe_page.dart': 1,
};

// ── Icon style & tooltips ───────────────────────────────────────────────────

final _icon = RegExp(r'(?<![\w.])Icons\.([a-z0-9_]+)');
final _appIcon = RegExp(r'(?<![\w.])AppIcons\.([a-zA-Z0-9_]+)');
final _rawLucide = RegExp(r'(?<![\w.])FLucideIcons\.([a-zA-Z0-9_]+)');
final _iconButton = RegExp(
  r'(?<![\w.])IconButton(?:\.(?:filled|filledTonal|outlined))?\(',
);

const _appFilledStates = <String, Set<String>>{
  'lib/app/widgets/bookmark_switch_button.dart': {'heartFilled'},
  'lib/app/widgets/card_actions/illust_card_actions.dart': {
    'eyeOffFilled',
    'userOffFilled',
    'watchLaterFilled',
  },
  'lib/app/widgets/func_bottom_nav.dart': {
    'homeFilled',
    'newWorksFilled',
    'rankingFilled',
    'searchFilled',
    'userFilled',
  },
  'lib/app/widgets/shell_rail.dart': {'heartFilled', 'settingsFilled'},
  'lib/app/widgets/tag_chips.dart': {'banFilled'},
  'lib/features/illust/viewer/image_viewer_page.dart': {'infoFilled'},
  'lib/features/settings/me_dashboard_page.dart': {
    'heartFilled',
    'watchLaterFilled',
  },
  'lib/features/settings/settings_page.dart': {'infoFilled'},
  'lib/features/novel/novel_markers_page.dart': {'watchLaterFilled'},
  'lib/features/novel/novel_reader_stage_widgets.dart': {'watchLaterFilled'},
  'lib/features/profile/profile_header_delegate.dart': {'userOffFilled'},
  'lib/features/profile/profile_wide_header.dart': {'userOffFilled'},
  'lib/features/settings/pages/download_task_presentation.dart': {'banFilled'},
};

const _untitledButtons = <String, int>{
  'lib/app/widgets/bookmark_switch_button.dart': 1,
};

// ── Motion token census ─────────────────────────────────────────────────────

const _tokensFile = 'lib/app/motion/motion_tokens.dart';
final _durationToken = RegExp(r'static const (\w+) = Duration\(');
final _resolveCall = RegExp(
  r'(?<![\w.])(?:MotionTokens\.)?_?resolve(?:With)?\(',
);
final _springCall = RegExp(r'(?<![\w.])(?:MotionTokens\.)?spring(?:Curve)?\(');

const _rawMotionTokenCensus = <String, int>{
  'lib/app/navigation/func_page.dart': 2,
  'lib/app/widgets/skeleton/func_skeleton.dart': 1,
  'lib/app/widgets/settings/settings_anchor.dart': 1,
};

// ── Spacing & radius tokens ─────────────────────────────────────────────────

final _spacingCall = RegExp(
  r'(?<!\w)(?:EdgeInsets\.(?:all|symmetric|only|fromLTRB)|(?:Border)?Radius\.circular)\(',
);
final _numberLiteral = RegExp(r'(?<![\w.])(\d+\.?\d*)(?![\w.])');
const _spacingAllowList = <String, int>{};

// ── Settings rows, segmented buttons, top bar ───────────────────────────────

const _listTileAllowList = <String, int>{
  'lib/features/settings/network_settings_page.dart': 2,
  'lib/features/settings/pages/muted_items_page.dart': 3,
  'lib/features/settings/pages/download_destination_page.dart': 1,
  'lib/features/settings/pages/account_settings_page.dart': 1,
};

final _segmented = RegExp(
  r'(?<![A-Za-z])(?:SegmentedButton|AppSegmentedButton|AppSegment|'
  r'AppTypeSwitch|SliverAppTypeSwitch|ProfileWorkTypeSwitch|'
  r'segmentedButtonTheme)(?![A-Za-z])',
);

const _topBarOwner = 'lib/app/widgets/app_top_bar.dart';
final _rawBar = RegExp(r'(?<![A-Za-z_])(?:Sliver)?AppBar\(');

// ── Helpers ─────────────────────────────────────────────────────────────────

Map<String, Set<String>> _matches(
  Map<String, String> sources,
  List<String> roots,
  RegExp pattern,
) {
  final hits = <String, Set<String>>{};
  for (final MapEntry(key: file, value: src) in ArchSourceCache.under(
    sources,
    roots,
  )) {
    for (final match in pattern.allMatches(src)) {
      hits
          .putIfAbsent(file, () => {})
          .add(match.groupCount >= 1 ? match.group(1)! : match.group(0)!);
    }
  }
  return hits;
}

bool _usesDeveloperLog(String source) {
  final imports = RegExp(r"import 'dart:developer'([^;]*);");
  for (final import in imports.allMatches(source)) {
    final clause = import.group(1)!;
    final shown = RegExp(r'\bshow\b(.*)').firstMatch(clause)?.group(1);
    if (shown != null) {
      if (RegExp(r'\blog\b').hasMatch(shown)) return true;
      continue;
    }
    if (RegExp(r'\bhide\b.*\blog\b').hasMatch(clause)) continue;
    final prefix = RegExp(r'\bas\s+(\w+)').firstMatch(clause)?.group(1);
    final call = prefix == null ? 'log' : '$prefix\\.log';
    if (RegExp('(?<![\\w.])$call\\(').hasMatch(source)) return true;
  }
  return false;
}

String _topLevelArguments(String src, int start) {
  final out = StringBuffer();
  var depth = 0;
  for (var i = start; i < src.length; i++) {
    final char = src[i];
    if (')]}'.contains(char)) {
      if (depth == 0) break;
      depth--;
    } else if ('([{'.contains(char)) {
      depth++;
    } else if (depth == 0) {
      out.write(char);
    }
  }
  return out.toString();
}

String _stripArguments(String src, RegExp call) {
  final out = StringBuffer();
  var cursor = 0;
  for (final m in call.allMatches(src)) {
    if (m.start < cursor) continue;
    out.write(src.substring(cursor, m.end));
    var depth = 1;
    var i = m.end;
    while (i < src.length && depth > 0) {
      if (src[i] == '(') depth++;
      if (src[i] == ')') depth--;
      i++;
    }
    out.write(')');
    cursor = i;
  }
  out.write(src.substring(cursor));
  return out.toString();
}

Map<String, int> _rawMotionReads(
  Map<String, String> noComments,
  RegExp token,
  RegExp call,
) {
  final counts = <String, int>{};
  for (final MapEntry(key: file, value: rawSrc) in ArchSourceCache.under(
    noComments,
    ['lib/app', 'lib/features'],
  )) {
    if (file == _tokensFile) continue;
    final src = _stripArguments(rawSrc, call);
    final n = token.allMatches(src).length;
    if (n > 0) counts[file] = n;
  }
  return counts;
}

bool _violatesSpacing(String src, int openParen) {
  var depth = 1;
  var i = openParen;
  while (i < src.length && depth > 0) {
    final c = src[i];
    if (c == '(') depth++;
    if (c == ')') depth--;
    i++;
  }
  final args = src.substring(openParen, i - 1);
  return _numberLiteral.allMatches(args).any((m) => double.parse(m[0]!) != 0);
}

void main() {
  final libRaw = ArchSourceCache.libRaw();
  final libNoComments = ArchSourceCache.libNoComments();

  test('prompts have exactly one host', () {
    final material = _matches(
      libRaw,
      ['lib'],
      RegExp(
        r'(?<![A-Za-z])(SnackBar\(|SnackBarAction\(|showSnackBar\(|'
        r'ScaffoldMessenger)',
      ),
    );
    expect(
      material,
      isEmpty,
      reason:
          'FB-04 material SnackBar path in lib — use showAppSnackBar:\n'
          '${material.entries.map((e) => '${e.key}: ${e.value.join(', ')}').join('\n')}',
    );

    final direct = _matches(libRaw, [
      'lib',
    ], RegExp(r'PromptHost\.of\(|PromptHostState')).keys.toSet();
    expect(
      direct.difference(_promptHostCallSites),
      isEmpty,
      reason:
          'FB-04 unapproved direct prompt host access — '
          'prefer showAppSnackBar(context, ...)',
    );
  });

  test('haptics have exactly one owner', () {
    final files = _matches(
      libRaw,
      ['lib'],
      RegExp(
        r"(?<![A-Za-z0-9_])HapticFeedback\.|FHapticFeedback\.(?!none\b)|MethodChannel\('parfait/haptics'\)",
      ),
    ).keys.where((f) => !f.startsWith(_hapticsOwnerDir));
    expect(
      files,
      isEmpty,
      reason:
          'FB-10 raw haptics outside $_hapticsOwnerDir — '
          'use an AppHaptics role',
    );
  });

  test('selection controls live only in their haptic wrappers', () {
    final violations = <String>[];
    _selectionControlOwners.forEach((pattern, owners) {
      final files = _matches(libRaw, ['lib'], pattern).keys.toSet();
      for (final file in files.difference(owners)) {
        violations.add('$file: ${pattern.pattern}');
      }
    });
    expect(
      violations,
      isEmpty,
      reason:
          'FB-12 raw selection controls outside their wrappers (use '
          'AppChoiceChip / AppSlider / SettingsControl / '
          'SettingsChoiceTile):\n${violations.join('\n')}',
    );
  });

  test('navigation chrome stays silent', () {
    final noisy = [
      for (final file in _silentNavigationFiles)
        if ((libRaw[file] ?? '').contains('AppHaptics')) file,
    ];
    expect(
      noisy,
      isEmpty,
      reason: 'FB-10 navigation must not play haptics — remove AppHaptics',
    );
  });

  test('UI clipboard writes go through copyToClipboard', () {
    final files = _matches(libRaw, [
      'lib/app',
      'lib/features',
    ], RegExp(r'Clipboard\.setData')).keys.toSet();
    expect(
      files.difference({_clipboardOwner}),
      isEmpty,
      reason:
          'FB-14 Clipboard.setData outside $_clipboardOwner — '
          'use copyToClipboard',
    );
  });

  test('diagnostics go through log()', () {
    final files = _matches(libRaw, [
      'lib',
    ], RegExp(r'(?<![\w.])(?:print|debugPrint)\(')).keys.toSet();
    expect(
      files.difference({_logOwner}),
      isEmpty,
      reason:
          'ERR-06 print/debugPrint outside $_logOwner — call log() from '
          'lib/core/log.dart',
    );
    final developer = [
      for (final MapEntry(key: file, value: src) in libRaw.entries)
        if (_usesDeveloperLog(src)) file,
    ];
    expect(
      developer,
      isEmpty,
      reason: 'ERR-06 dart:developer log — call log() from lib/core/log.dart',
    );
  });

  test('app modal overlays funnel through app_overlays.dart', () {
    final hits = _matches(
      libRaw,
      ['lib'],
      RegExp(
        '(?<![A-Za-z])'
        '(showDialog|showModalBottomSheet|showCupertinoDialog|'
        'showCupertinoModalPopup|showGeneralDialog|showMenu|'
        'showLicensePage|showDatePicker|showTimePicker|showSearch|'
        'ModalSheetRoute|ModalSheetPage|CupertinoModalSheetRoute)'
        r'\s*[<(]',
      ),
    );
    final violations = <String>[];
    hits.forEach((file, symbols) {
      if (file == _overlaysOwner) return;
      final allowed = _overlayAllowList[file] ?? const <String>{};
      final extra = symbols.difference(allowed);
      if (extra.isNotEmpty) violations.add('$file: ${extra.join(', ')}');
    });
    expect(
      violations,
      isEmpty,
      reason:
          'FB-02 raw overlay entries outside $_overlaysOwner — use '
          'showAppDialog / showAppBottomSheet / AppMenuButton:\n'
          '${violations.join('\n')}',
    );
  });

  test('system UI has exactly one owner', () {
    final hits = _matches(
      libRaw,
      ['lib'],
      RegExp(
        r'SystemChrome\.|SystemUiOverlayStyle\(|'
        r'AnnotatedRegion\s*<SystemUiOverlayStyle>',
      ),
    );
    expect(
      hits.keys.toSet().difference({_systemUiOwner}),
      isEmpty,
      reason:
          'SYS-01 raw system UI calls outside $_systemUiOwner: '
          '${hits.keys.toSet().difference({_systemUiOwner}).join(', ')} — '
          'use funcSystemBarsStyle / FuncSystemBars / setSystemUiMode',
    );
  });

  test('Hero uses only the shared illustHeroTag family', () {
    final files = _matches(libRaw, [
      'lib',
    ], RegExp(r'(?<![A-Za-z])Hero\(')).keys.toSet();
    expect(
      files,
      _heroFiles,
      reason:
          'TRANS-07 Hero callsites must stay in the shared illustHeroTag '
          'family — tag new Heroes with illustHeroTag or update the census',
    );
    final plain = RegExp(
      r'Hero\(\s*tag: [^,]+,\s*curve: MotionTokens\.spatialCurve,',
    );
    final turning = RegExp(
      r'Hero\(\s*tag: [^,]+,\s*curve: (\w+),\s*reverseCurve: \1,',
    );
    for (final file in files) {
      final src = libRaw[file]!;
      final turns = turning.allMatches(src).length;
      expect(
        plain.allMatches(src).length + turns,
        RegExp(r'(?<![A-Za-z])Hero\(').allMatches(src).length,
        reason: 'TRANS-09 every artwork Hero flies on the spatial curve: $file',
      );
      if (turns > 0) {
        expect(src, contains(' = illustHeroCurve(context);'), reason: file);
      }
    }
  });

  test('motion durations live only in MotionTokens (pinned census)', () {
    final counts = <String, int>{};
    for (final MapEntry(key: file, value: src) in ArchSourceCache.under(
      libRaw,
      ['lib/app', 'lib/features'],
    )) {
      final n = RegExp(r'Duration\(milliseconds').allMatches(src).length;
      if (n > 0) counts[file] = n;
    }
    expect(
      counts,
      _durationCensus,
      reason:
          'MOTION-01 hard-coded ms durations outside the census — route '
          'animation durations through MotionTokens or pin the non-motion '
          'use here',
    );
  });

  test('no merge-conflict markers in lib/, test/ or .trellis/spec/', () {
    final marker = RegExp(r'^(<{7}|>{7})', multiLine: true);
    final violations = <String>[
      for (final MapEntry(key: path, value: src) in {
        ...libRaw,
        ...ArchSourceCache.testRaw(),
        ...ArchSourceCache.specRaw(),
      }.entries)
        if (marker.hasMatch(src)) path,
    ];
    expect(violations, isEmpty, reason: violations.join('\n'));
  });

  test('a filled icon with an outlined twin marks a state', () {
    final iconSources = {
      for (final MapEntry(key: file, value: src) in libNoComments.entries)
        if (file != 'lib/app/icons/app_icons.dart' &&
            file != 'lib/app/icons/ui_icons.dart')
          file: src,
    };
    final rawIcons = <String, Set<String>>{};
    iconSources.forEach((file, src) {
      for (final match in _icon.allMatches(src)) {
        (rawIcons[file] ??= {}).add('Icons.${match[1]}');
      }
      for (final match in _rawLucide.allMatches(src)) {
        (rawIcons[file] ??= {}).add('FLucideIcons.${match[1]}');
      }
    });
    expect(
      rawIcons,
      isEmpty,
      reason:
          'THEME-16 app UI uses AppIcons or UiIcons (no raw Material Icons.* '
          'or unbridged FLucideIcons.* outside lib/app/icons/)',
    );

    final usedApp = {
      for (final src in iconSources.values)
        for (final match in _appIcon.allMatches(src)) match[1]!,
    };
    final filledApp = <String, Set<String>>{};
    iconSources.forEach((file, src) {
      for (final match in _appIcon.allMatches(src)) {
        final name = match[1]!;
        if (name.endsWith('Filled') &&
            usedApp.contains(name.substring(0, name.length - 6))) {
          (filledApp[file] ??= {}).add(name);
        }
      }
    });
    expect(
      filledApp,
      _appFilledStates,
      reason:
          'THEME-16 a custom AppIcon uses the outlined twin at rest — '
          'the *Filled twin marks a state or selected destination',
    );
  });

  test('every icon button has a tooltip', () {
    final untitled = <String, int>{};
    libNoComments.forEach((file, src) {
      if (file == 'lib/app/icons/app_icons.dart' ||
          file == 'lib/app/icons/ui_icons.dart') {
        return;
      }
      for (final match in _iconButton.allMatches(src)) {
        if (!_topLevelArguments(src, match.end).contains('tooltip:')) {
          untitled[file] = (untitled[file] ?? 0) + 1;
        }
      }
    });
    expect(
      untitled,
      _untitledButtons,
      reason:
          'THEME-17 an icon button names its action in a localized '
          'tooltip; pin one that labels itself through Semantics',
    );
  });

  test('duration tokens are read through MotionTokens.resolve', () {
    final tokens = _durationToken
        .allMatches(libRaw[_tokensFile]!)
        .map((m) => m[1]!)
        .toList();
    expect(tokens, isNotEmpty, reason: 'token scan found nothing');
    final raw = RegExp('MotionTokens\\.(?:${tokens.join('|')})(?!\\w)');

    final counts = _rawMotionReads(libNoComments, raw, _resolveCall);
    expect(
      counts,
      _rawMotionTokenCensus,
      reason:
          'MOTION-01 a duration token is read without MotionTokens.resolve '
          '— wrap it, or pin the file in the census with a reason',
    );
  });

  test('spring tokens are read through MotionTokens.spring', () {
    expect(
      _rawMotionReads(libNoComments, RegExp(r'MotionSpring\.\w+'), _springCall),
      isEmpty,
      reason:
          'MOTION-03 a MotionSpring is read directly — go through '
          'MotionTokens.spring or springCurve so the speed and the motion gate '
          'apply',
    );
  });

  test('spacing and radius literals use FuncSpacing/FuncShape', () {
    final violations = <String>[];
    for (final MapEntry(key: file, value: src) in ArchSourceCache.under(
      libNoComments,
      ['lib/app', 'lib/features'],
    )) {
      if (file.startsWith('lib/app/theme/')) continue;
      var hits = 0;
      for (final m in _spacingCall.allMatches(src)) {
        if (_violatesSpacing(src, m.end)) {
          hits++;
          final line = src.substring(0, m.start).split('\n').length;
          violations.add('  $file:$line');
        }
      }
      final allowed = _spacingAllowList[file] ?? 0;
      if (hits <= allowed) {
        violations.removeRange(violations.length - hits, violations.length);
      } else if (allowed > 0) {
        violations.add('  $file: $hits sites exceed allow-list $allowed');
      }
    }
    expect(
      violations,
      isEmpty,
      reason:
          'THEME-12 spacing/radius literals must resolve to '
          'FuncSpacing/FuncShape; file-specific exceptions go in '
          '_spacingAllowList with a reason:\n${violations.join('\n')}',
    );
  });

  test('hand-written ListTile rows match the design whitelist', () {
    final counts = <String, int>{};
    for (final MapEntry(key: file, value: src) in ArchSourceCache.under(
      libRaw,
      ['lib/features/settings'],
    )) {
      final n = RegExp(r'ListTile\(').allMatches(src).length;
      if (n > 0) counts[file] = n;
    }
    expect(
      counts,
      _listTileAllowList,
      reason:
          'SET-03 hand-written ListTile( outside the whitelist — use the shared '
          'settings row components, or pin the new row here with a reason',
    );
  });

  test('SettingsSection is gone from lib/', () {
    final hits = [
      for (final MapEntry(key: file, value: src) in libRaw.entries)
        if (src.contains('SettingsSection')) file,
    ];
    expect(
      hits,
      isEmpty,
      reason: 'SET-01 SettingsSection was removed — use SettingsGroup',
    );
  });

  test('no segmented buttons', () {
    final hits = {
      for (final MapEntry(key: file, value: src) in libRaw.entries)
        if (_segmented.hasMatch(src)) file,
    };
    expect(
      hits,
      isEmpty,
      reason:
          'NAV-17 segmented button in lib — use tabs, SettingsMenuTile, a '
          'switch or buttons instead',
    );
  });

  test('page top bars are AppTopBar', () {
    final hits = {
      for (final MapEntry(key: file, value: src) in libRaw.entries)
        if (file != _topBarOwner && _rawBar.hasMatch(src)) file,
    };
    expect(
      hits,
      isEmpty,
      reason: 'NAV-18 raw AppBar in a page — use AppTopBar instead',
    );
  });

  test('spinners go through AppSpinner', () {
    const owner = 'lib/app/widgets/app_spinner.dart';
    final pattern = RegExp(r'(?<![A-Za-z_])CircularProgressIndicator\(');
    final hits = [
      for (final MapEntry(key: file, value: src) in libNoComments.entries)
        if (file != owner && pattern.hasMatch(src)) file,
    ];
    expect(
      hits,
      isEmpty,
      reason:
          'Use AppSpinner instead of raw CircularProgressIndicator:\n'
          '${hits.join('\n')}',
    );
  });

  test('feature code never imports package:forui directly', () {
    final pattern = RegExp(r'''import\s+['"]package:forui/''');
    final hits = [
      for (final MapEntry(key: file, value: src) in ArchSourceCache.under(
        libNoComments,
        ['lib/features'],
      ))
        if (pattern.hasMatch(src)) file,
    ];
    expect(
      hits,
      isEmpty,
      reason:
          'Wrap Forui primitives under lib/app/widgets/ instead of importing '
          'package:forui/ in features:\n${hits.join('\n')}',
    );
  });

  test(
    'build() never constructs FutureBuilder(future: PackageInfo.fromPlatform())',
    () {
      final pattern = RegExp(
        r'FutureBuilder[\s\S]{0,200}PackageInfo\.fromPlatform\s*\(',
      );
      final hits = [
        for (final MapEntry(key: file, value: src) in libNoComments.entries)
          if (pattern.hasMatch(src)) file,
      ];
      expect(
        hits,
        isEmpty,
        reason:
            'Use packageInfoProvider in widget builds instead of constructing '
            'FutureBuilder(future: PackageInfo.fromPlatform()):\n'
            '${hits.join('\n')}',
      );
    },
  );
}
