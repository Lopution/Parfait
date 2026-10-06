// Page top bars go through AppTopBar: it owns the scrolled-under edge line,
// and a raw AppBar would show neither the line nor a tint, leaving that
// page without any scroll edge. Asserted on lib/ (repo-relative paths).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _owner = 'lib/app/widgets/app_top_bar.dart';

final _rawBar = RegExp(r'(?<![A-Za-z_])(?:Sliver)?AppBar\(');

void main() {
  test('page top bars are AppTopBar', () {
    final hits = {
      for (final entity in Directory('lib').listSync(recursive: true))
        if (entity is File &&
            entity.path.endsWith('.dart') &&
            entity.path != _owner &&
            _rawBar.hasMatch(entity.readAsStringSync()))
          entity.path,
    };
    expect(hits, isEmpty, reason: 'use AppTopBar instead of AppBar');
  });
}
