import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/settings/local_block_filter.dart';

import 'helpers/illust_fixtures.dart';

void main() {
  group('C9 local block predicate (pure)', () {
    test('R18 switch hides x_restrict == 1', () {
      final entity = parseIllust(illustJson(1, xRestrict: 1));
      expect(isLocallyBlocked(entity, blockR18: true, blockAI: false), isTrue);
      expect(
        isLocallyBlocked(entity, blockR18: false, blockAI: false),
        isFalse,
      );
    });

    test('AI switch hides illust_ai_type == 2', () {
      final entity = parseIllust(illustJson(2, aiType: 2));
      expect(isLocallyBlocked(entity, blockR18: false, blockAI: true), isTrue);
    });

    test('tags are not this predicate\'s domain (mute owns them)', () {
      final entity = parseIllust(illustJson(3));
      expect(
        isLocallyBlocked(entity, blockR18: false, blockAI: false),
        isFalse,
        reason:
            'fixture carries an `original` tag; tag blocking moved to '
            'MuteStore/muteHitFor',
      );
    });

    test('all switches off never hides', () {
      final entity = parseIllust(illustJson(4, xRestrict: 1, aiType: 2));
      expect(
        isLocallyBlocked(entity, blockR18: false, blockAI: false),
        isFalse,
      );
    });
  });
}
