import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_localizations/flutter_localizations.dart'
    show GlobalWidgetsLocalizations;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';

Future<T> _load<T>(Locale locale, LocalizationsDelegate<T> delegate) async {
  expect(delegate.isSupported(locale), isTrue, reason: '$locale');
  return delegate.load(locale);
}

LocalizationsDelegate<T> _ours<T>() =>
    appLocalizationsDelegates.whereType<LocalizationsDelegate<T>>().single;

void main() {
  // The app's supported locales get exactly what Flutter's delegates give
  // them: the same translation class and the same formats.
  test('the app\'s locales match Flutter\'s own delegates', () async {
    final date = DateTime(2026, 10, 4, 9, 5);
    for (final locale in const [
      Locale('zh', 'CN'),
      Locale('en', 'US'),
      Locale('ja', 'JP'),
      Locale('ru', 'RU'),
    ]) {
      final material = await _load(locale, _ours<MaterialLocalizations>());
      final flutterMaterial = await _load(
        locale,
        GlobalMaterialLocalizations.delegate,
      );
      expect(material.runtimeType, flutterMaterial.runtimeType);
      for (final format in <String Function(MaterialLocalizations)>[
        (l) => l.formatYear(date),
        (l) => l.formatCompactDate(date),
        (l) => l.formatShortDate(date),
        (l) => l.formatMediumDate(date),
        (l) => l.formatFullDate(date),
        (l) => l.formatMonthYear(date),
        (l) => l.formatShortMonthDay(date),
        (l) => l.formatDecimal(12345),
        (l) => l.formatMinute(const TimeOfDay(hour: 9, minute: 5)),
      ]) {
        expect(format(material), format(flutterMaterial));
      }

      final cupertino = await _load(locale, _ours<CupertinoLocalizations>());
      final flutterCupertino = await _load(
        locale,
        GlobalCupertinoLocalizations.delegate,
      );
      expect(cupertino.runtimeType, flutterCupertino.runtimeType);
      for (final format in <String Function(CupertinoLocalizations)>[
        (l) => l.datePickerYear(2026),
        (l) => l.datePickerDayOfMonth(4, 7),
        (l) => l.datePickerMediumDate(date),
        (l) => l.datePickerHour(9),
        (l) => l.datePickerMinute(5),
        (l) => l.timerPickerSecond(5),
      ]) {
        expect(format(cupertino), format(flutterCupertino));
      }

      final widgets = await _load(locale, _ours<WidgetsLocalizations>());
      final flutterWidgets = await _load(
        locale,
        GlobalWidgetsLocalizations.delegate,
      );
      expect(widgets.runtimeType, flutterWidgets.runtimeType);
    }
  });
}
