import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/core/debug/trace_marks.dart';

import 'helpers/localized_app.dart';
import 'helpers/pixiv_router.dart';

void main() {
  late List<String> marks;
  setUp(() {
    marks = [];
    TraceMarks.sink = marks.add;
  });
  tearDown(TraceMarks.debugReset);

  testWidgets('a tap and a fling are marked down and up, the fling fast', (
    tester,
  ) async {
    TraceMarks.trackPointers();
    await tester.pumpWidget(const SizedBox.expand());
    await tester.tapAt(const Offset(100, 100));
    await tester.flingFrom(const Offset(100, 400), const Offset(0, -300), 3000);

    expect(marks.where((mark) => mark == 'down'), hasLength(2));
    final ups = [
      for (final mark in marks)
        if (RegExp(r'^up (\d+)dp (\d+)dp/s$').firstMatch(mark) case final up?)
          (distance: int.parse(up[1]!), speed: int.parse(up[2]!)),
    ];
    expect(ups, hasLength(2));
    expect(ups.first.distance, 0);
    expect(ups.last.distance, 300);
    expect(ups.last.speed, greaterThan(ups.first.speed + 2000));
  });

  testWidgets('a route change marks the page and the scene it plays', (
    tester,
  ) async {
    final router = pixivRouter('/recommended');
    await tester.pumpWidget(ProviderScope(child: localizedRouterApp(router)));
    await tester.pump(const Duration(milliseconds: 100));
    router.go('/ranking');
    await tester.pump(const Duration(milliseconds: 100));
    expect(marks, contains('enter branch switch'));

    // A pushed page never reaches the router's uri; it is marked all the same.
    unawaited(router.push('/ranking/history'));
    await tester.pumpAndSettle();
    router.pop();
    await tester.pumpAndSettle();
    expect(
      marks.where((mark) => mark.startsWith('page ')),
      containsAllInOrder([
        'page /ranking',
        'page /ranking/history',
        'page /ranking',
      ]),
    );
  });
}
