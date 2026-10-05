import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:parfait/app/format/app_format.dart';
import 'package:parfait/l10n/app_localizations.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';

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
      MaterialApp(
        locale: locale,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: appLocalizationsDelegates,
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

  final value = DateTime.utc(2026, 10, 4, 15, 30);

  group('date', () {
    testWidgets('formats per locale', (tester) async {
      expect(
        await probe(
          tester,
          const Locale('zh'),
          (c) => AppFormat.date(c, value),
        ),
        '2026年10月4日',
      );
      expect(
        await probe(
          tester,
          const Locale('en'),
          (c) => AppFormat.date(c, value),
        ),
        'Oct 4, 2026',
      );
      expect(
        await probe(
          tester,
          const Locale('ja'),
          (c) => AppFormat.date(c, value),
        ),
        '2026年10月4日',
      );
      // ICU's ru yMMMd joins with a no-break space; pin the pieces instead
      // of the exact separator.
      final ru = await probe(
        tester,
        const Locale('ru'),
        (c) => AppFormat.date(c, value),
      );
      expect(ru, contains('окт'));
      expect(ru, contains('2026'));
      expect(ru, startsWith('4'));
    });

    testWidgets('withTime appends the clock in the locale pattern', (
      tester,
    ) async {
      for (final locale in const [
        Locale('zh'),
        Locale('en'),
        Locale('ja'),
        Locale('ru'),
      ]) {
        final text = await probe(
          tester,
          locale,
          (c) => AppFormat.date(c, value, withTime: true),
        );
        // The local hour:minute appears in some order per locale.
        expect(text, contains(RegExp(r'1[0-9]:[0-9]{2}|[0-9]{2}:[0-9]{2}')));
      }
    });
  });

  group('relative', () {
    final now = DateTime(2026, 10, 4, 12, 0, 0);

    String Function(BuildContext) at(Duration ago) =>
        (c) => AppFormat.relative(c, now.subtract(ago), now: now);

    testWidgets('the minute boundary', (tester) async {
      expect(await probe(tester, const Locale('zh'), at(Duration.zero)), '刚刚');
      expect(
        await probe(
          tester,
          const Locale('zh'),
          at(const Duration(seconds: 59)),
        ),
        '刚刚',
      );
      // Clock skew counts as "just now" too.
      expect(
        await probe(
          tester,
          const Locale('zh'),
          at(const Duration(seconds: -30)),
        ),
        '刚刚',
      );
      expect(
        await probe(
          tester,
          const Locale('zh'),
          at(const Duration(seconds: 60)),
        ),
        '1 分钟前',
      );
    });

    testWidgets('hour and day boundaries', (tester) async {
      expect(
        await probe(
          tester,
          const Locale('zh'),
          at(const Duration(minutes: 59)),
        ),
        '59 分钟前',
      );
      expect(
        await probe(
          tester,
          const Locale('zh'),
          at(const Duration(minutes: 60)),
        ),
        '1 小时前',
      );
      expect(
        await probe(tester, const Locale('zh'), at(const Duration(hours: 23))),
        '23 小时前',
      );
      expect(
        await probe(tester, const Locale('zh'), at(const Duration(hours: 24))),
        '1 天前',
      );
      expect(
        await probe(tester, const Locale('zh'), at(const Duration(days: 6))),
        '6 天前',
      );
    });

    testWidgets('seven days and older fall back to the absolute date', (
      tester,
    ) async {
      final weekAgo = now.subtract(const Duration(days: 7));
      expect(
        await probe(tester, const Locale('zh'), at(const Duration(days: 7))),
        await probe(
          tester,
          const Locale('zh'),
          (c) => AppFormat.date(c, weekAgo),
        ),
      );
    });

    testWidgets('all four locales produce the same buckets', (tester) async {
      for (final locale in const [
        Locale('zh'),
        Locale('en'),
        Locale('ja'),
        Locale('ru'),
      ]) {
        final justNow = await probe(tester, locale, at(Duration.zero));
        final minutes = await probe(
          tester,
          locale,
          at(const Duration(minutes: 3)),
        );
        final hours = await probe(tester, locale, at(const Duration(hours: 5)));
        final days = await probe(tester, locale, at(const Duration(days: 2)));
        expect(justNow, isNot(contains('3')));
        expect(minutes, contains('3'));
        expect(hours, contains('5'));
        expect(days, contains('2'));
      }
    });

    testWidgets('ru picks the right plural form', (tester) async {
      expect(
        await probe(tester, const Locale('ru'), at(const Duration(minutes: 1))),
        '1 минуту назад',
      );
      expect(
        await probe(tester, const Locale('ru'), at(const Duration(minutes: 3))),
        '3 минуты назад',
      );
      expect(
        await probe(tester, const Locale('ru'), at(const Duration(minutes: 5))),
        '5 минут назад',
      );
    });
  });

  group('count', () {
    testWidgets('keeps small numbers verbatim', (tester) async {
      expect(
        await probe(tester, const Locale('zh'), (c) => AppFormat.count(c, 999)),
        '999',
      );
    });

    testWidgets('compacts per locale', (tester) async {
      expect(
        await probe(
          tester,
          const Locale('zh'),
          (c) => AppFormat.count(c, 12345),
        ),
        '1.2万',
      );
      expect(
        await probe(
          tester,
          const Locale('en'),
          (c) => AppFormat.count(c, 12345),
        ),
        '12K',
      );
      expect(
        await probe(
          tester,
          const Locale('en'),
          (c) => AppFormat.count(c, 1234567),
        ),
        '1.2M',
      );
      // ru compact uses тыс./млн abbreviations; exact glyphs come from ICU.
      final ru = await probe(
        tester,
        const Locale('ru'),
        (c) => AppFormat.count(c, 12345),
      );
      expect(ru, isNot('12345'));
    });
  });
}
