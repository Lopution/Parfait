import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('iconFont asset registration', () {
    test('assets/icon.ttf is bundled and non-empty', () async {
      final data = await rootBundle.load('assets/icon.ttf');
      expect(data.lengthInBytes, greaterThan(0));
    });

    test(
      'pubspec registers the iconFont family pointing at assets/icon.ttf',
      () {
        final pubspec = File('pubspec.yaml').readAsStringSync();
        expect(pubspec.contains('family: iconFont'), isTrue);
        expect(
          pubspec.contains('asset: assets/icon.ttf'),
          isTrue,
          reason: 'pubspec.yaml must declare assets/icon.ttf under fonts',
        );
      },
    );
  });
}
