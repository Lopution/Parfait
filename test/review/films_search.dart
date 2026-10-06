import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'review_support.dart';

/// The search input modal and the keyboard.
void main() {
  testFilm(
    'search/input-ime',
    location: '/search',
    notes:
        'Search home → input modal: the field takes focus and the keyboard '
        'slides up; typing shows suggestions; submitting opens results as '
        'the keyboard slides down. The layout follows the inset on every '
        'frame with no overlap or jump.',
    script: (film, router) async {
      final tester = film.tester;
      await film.tap(find.text('搜索'));
      await film.keyboard(show: true);
      await tester.enterText(find.byType(TextField).last, 'cat');
      await film.frames(20);
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await film.keyboard(show: false);
      await film.untilSettled();
    },
  );
}
