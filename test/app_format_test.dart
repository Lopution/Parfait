import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:parfait/app/format/app_format.dart';
import 'helpers/localized_app.dart';

void main() {
  /// Pumps a probe that resolves [read] inside the localized app, then
  /// returns what it produced.
  Future<String> probe(
    WidgetTester tester,
    Locale locale,
    String Function(BuildContext context) read,
  ) async {
    String? result;
    await tester.pumpWidget(
      localizedApp(
        locale: locale,
        home: Builder(
          builder: (context) {
            result = read(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    return result!;
  }

  /// Checks each row: in [locale], what [read] produces matches.
  Future<void> expectRows(
    WidgetTester tester,
    List<(String, String Function(BuildContext), Object)> rows,
  ) async {
    for (final (locale, read, matcher) in rows) {
      expect(
        await probe(tester, Locale(locale), read),
        matcher,
        reason: locale,
      );
    }
  }

  const locales = ['zh', 'en', 'ja', 'ru'];
  final value = DateTime.utc(2026, 10, 4, 15, 30);
  String date(BuildContext c) => AppFormat.date(c, value);

  group('date', () {
    testWidgets('formats per locale', (tester) async {
      await expectRows(tester, [
        ('zh', date, '2026年10月4日'),
        ('en', date, 'Oct 4, 2026'),
        ('ja', date, '2026年10月4日'),
        // ICU's ru yMMMd joins with a no-break space; pin the pieces
        // instead of the exact separator.
        ('ru', date, allOf(contains('окт'), contains('2026'), startsWith('4'))),
      ]);
    });

    testWidgets('withTime appends the clock in the locale pattern', (
      tester,
    ) async {
      // The local hour:minute appears in some order per locale.
      await expectRows(tester, [
        for (final locale in locales)
          (
            locale,
            (c) => AppFormat.date(c, value, withTime: true),
            contains(RegExp(r'1[0-9]:[0-9]{2}|[0-9]{2}:[0-9]{2}')),
          ),
      ]);
    });
  });

  group('relative', () {
    final now = DateTime(2026, 10, 4, 12, 0, 0);

    String Function(BuildContext) at(Duration ago) =>
        (c) => AppFormat.relative(c, now.subtract(ago), now: now);

    testWidgets('minute, hour and day boundaries', (tester) async {
      await expectRows(tester, [
        ('zh', at(Duration.zero), '刚刚'),
        ('zh', at(const Duration(seconds: 59)), '刚刚'),
        // Clock skew counts as "just now" too.
        ('zh', at(const Duration(seconds: -30)), '刚刚'),
        ('zh', at(const Duration(seconds: 60)), '1 分钟前'),
        ('zh', at(const Duration(minutes: 59)), '59 分钟前'),
        ('zh', at(const Duration(minutes: 60)), '1 小时前'),
        ('zh', at(const Duration(hours: 23)), '23 小时前'),
        ('zh', at(const Duration(hours: 24)), '1 天前'),
        ('zh', at(const Duration(days: 6)), '6 天前'),
        // Seven days and older fall back to the absolute date.
        ('zh', at(const Duration(days: 7)), '2026年9月27日'),
        ('ru', at(const Duration(minutes: 1)), '1 минуту назад'),
        ('ru', at(const Duration(minutes: 3)), '3 минуты назад'),
        ('ru', at(const Duration(minutes: 5)), '5 минут назад'),
      ]);
    });

    testWidgets('all four locales produce the same buckets', (tester) async {
      await expectRows(tester, [
        for (final locale in locales) ...[
          (locale, at(Duration.zero), isNot(contains('3'))),
          (locale, at(const Duration(minutes: 3)), contains('3')),
          (locale, at(const Duration(hours: 5)), contains('5')),
          (locale, at(const Duration(days: 2)), contains('2')),
        ],
      ]);
    });
  });

  testWidgets('count keeps small numbers and compacts per locale', (
    tester,
  ) async {
    String Function(BuildContext) count(int n) =>
        (c) => AppFormat.count(c, n);
    await expectRows(tester, [
      ('zh', count(999), '999'),
      ('zh', count(12345), '1.2万'),
      ('en', count(12345), '12K'),
      ('en', count(1234567), '1.2M'),
      // ru compact uses тыс./млн abbreviations; exact glyphs come from ICU.
      ('ru', count(12345), isNot('12345')),
    ]);
  });
}
