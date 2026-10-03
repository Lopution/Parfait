// Every UI animation length goes through MotionTokens.resolve so the
// animation speed and the reduced-motion gate apply (design §7).
//
// Heuristic scan over lib/app and lib/features: the duration tokens are
// read from motion_tokens.dart (`static const <name> = Duration(`), then
// each file is stripped of comments and of the argument spans of
// `resolve(` / `_resolve(` / `resolveWith(` calls. Any token reference
// left over reads a raw length. Those are pinned per file below with a
// reason; a new one must either go through resolve or be added here.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _tokensFile = 'lib/app/motion/motion_tokens.dart';

final _comment = RegExp(r'//[^\n]*|/\*.*?\*/', dotAll: true);
final _durationToken = RegExp(r'static const (\w+) = Duration\(');
final _resolveCall = RegExp(
  r'(?<![\w.])(?:MotionTokens\.)?_?resolve(?:With)?\(',
);

/// Raw token reads that are intentional, per file.
const _census = <String, int>{
  // FuncPage constructor defaults; `_page` always passes the resolved
  // duration.
  'lib/app/navigation/func_page.dart': 2,
  // The fadeDuration parameter default and the feed-card value; both are
  // resolved where CachedNetworkImage receives them.
  'lib/app/pixiv_image.dart': 2,
  // Skeleton shimmer: a loop period, not a transition.
  'lib/app/widgets/skeleton/func_skeleton.dart': 1,
  // Wheel scrolling is scroll physics for mouse input; scaling it changes
  // how scrolling feels, not how fast an animation plays.
  'lib/app/widgets/smooth_wheel_scroll.dart': 1,
};

/// Removes the argument span of every resolve call, so tokens passed to
/// it no longer match.
String _stripResolveArguments(String src) {
  final out = StringBuffer();
  var cursor = 0;
  for (final m in _resolveCall.allMatches(src)) {
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

void main() {
  test('duration tokens are read through MotionTokens.resolve', () {
    final tokens = _durationToken
        .allMatches(File(_tokensFile).readAsStringSync())
        .map((m) => m[1]!)
        .toList();
    expect(tokens, isNotEmpty, reason: 'token scan found nothing');
    final raw = RegExp('MotionTokens\\.(?:${tokens.join('|')})(?!\\w)');

    final counts = <String, int>{};
    for (final root in ['lib/app', 'lib/features']) {
      for (final entity in Directory(
        root,
      ).listSync(recursive: true).whereType<File>()) {
        final file = entity.path;
        if (!file.endsWith('.dart') || file == _tokensFile) continue;
        final src = _stripResolveArguments(
          entity.readAsStringSync().replaceAll(_comment, ''),
        );
        final n = raw.allMatches(src).length;
        if (n > 0) counts[file] = n;
      }
    }
    expect(
      counts,
      _census,
      reason:
          'a duration token is read without MotionTokens.resolve — wrap it, '
          'or pin the file in the census with a reason',
    );
  });
}
