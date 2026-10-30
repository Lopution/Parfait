import 'package:flutter_test/flutter_test.dart';

import '../helpers/route_smoke.dart';

void main() {
  test('every page of the router has a smoke entry', () {
    final templates = smokeRouterTemplates();
    final common = {
      for (final template in templates)
        if (template.startsWith('/me/')) template.substring('/me/'.length),
    };
    final pages = {for (final t in templates) smokePageOf(t, common)};
    final entries = {for (final group in smokePages.values) ...group.keys};
    expect(pages.difference(entries), isEmpty);
    expect(entries.difference(pages), isEmpty);
  });

  smokeMatrix(SmokeGroup.entry);
}
