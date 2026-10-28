import 'package:flutter_test/flutter_test.dart';
import 'package:parfait/core/novel/novel_entity.dart';
import 'package:parfait/core/settings/local_block_filter.dart';

import 'helpers/illust_fixtures.dart';

void main() {
  test('C9 local block: R-18 (and R-18G) and AI switches, illusts and '
      'novels alike', () {
    // Tags are not this predicate's domain: the fixture's `original` tag
    // never blocks (MuteStore/muteHitFor owns tags).
    for (final (xRestrict, ai, blockR18, blockAI, blocked) in [
      (1, 0, true, false, true),
      (2, 0, true, false, true),
      (1, 0, false, false, false),
      (0, 2, false, true, true),
      (0, 1, false, true, false),
      (1, 2, false, false, false),
      (0, 0, true, true, false),
    ]) {
      final illust = parseIllust(
        illustJson(1, xRestrict: xRestrict, aiType: ai),
      );
      final novel = NovelEntity.fromJson({
        ...novelJson(1),
        'x_restrict': xRestrict,
        'novel_ai_type': ai,
      });
      final reason = 'x_restrict $xRestrict, ai $ai, $blockR18/$blockAI';
      expect(
        isLocallyBlocked(illust, blockR18: blockR18, blockAI: blockAI),
        blocked,
        reason: reason,
      );
      expect(
        isNovelLocallyBlocked(novel, blockR18: blockR18, blockAI: blockAI),
        blocked,
        reason: reason,
      );
    }
  });
}
