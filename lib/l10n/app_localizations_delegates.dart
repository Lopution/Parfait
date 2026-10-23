import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_localizations/flutter_localizations.dart'
    show
        WidgetsLocalizationEn,
        WidgetsLocalizationJa,
        WidgetsLocalizationRu,
        WidgetsLocalizationZh;
// Material and Cupertino's own delegates load the date data through it too.
// ignore: implementation_imports
import 'package:flutter_localizations/src/utils/date_localizations.dart';
import 'package:intl/intl.dart' as intl;
import 'package:material_ui/material_ui.dart';

import 'app_localizations.dart';

/// The app's strings, and the framework's in the app's languages only.
///
/// `Global{Material,Cupertino,Widgets}Localizations.delegate` pick a
/// translation through a switch over every language Flutter ships, which
/// keeps all ~80 of them in the build (0.1 MB of the APK). These delegates
/// name the four classes the app's supported locales resolve to: zh_CN,
/// en_US, ja_JP and ru_RU have no regional variant of their own.
const appLocalizationsDelegates = <LocalizationsDelegate<dynamic>>[
  AppLocalizations.delegate,
  _MaterialDelegate(),
  _CupertinoDelegate(),
  _WidgetsDelegate(),
];

typedef _Material =
    GlobalMaterialLocalizations Function({
      required intl.DateFormat fullYearFormat,
      required intl.DateFormat compactDateFormat,
      required intl.DateFormat shortDateFormat,
      required intl.DateFormat mediumDateFormat,
      required intl.DateFormat longDateFormat,
      required intl.DateFormat yearMonthFormat,
      required intl.DateFormat shortMonthDayFormat,
      required intl.NumberFormat decimalFormat,
      required intl.NumberFormat twoDigitZeroPaddedFormat,
    });

typedef _Cupertino =
    GlobalCupertinoLocalizations Function({
      required intl.DateFormat fullYearFormat,
      required intl.DateFormat dayFormat,
      required intl.DateFormat weekdayFormat,
      required intl.DateFormat mediumDateFormat,
      required intl.DateFormat singleDigitHourFormat,
      required intl.DateFormat singleDigitMinuteFormat,
      required intl.DateFormat doubleDigitMinuteFormat,
      required intl.DateFormat singleDigitSecondFormat,
      required intl.NumberFormat decimalFormat,
    });

const _languages = {'zh', 'en', 'ja', 'ru'};

/// The locale the formats use, once the date data is loaded; intl falls
/// back to the language when it has no data for the region.
String _formatLocale(Locale locale) {
  loadDateIntlDataIfNotLoaded();
  return intl.Intl.canonicalizedLocale(locale.toString());
}

class _MaterialDelegate extends LocalizationsDelegate<MaterialLocalizations> {
  const _MaterialDelegate();

  @override
  bool isSupported(Locale locale) => _languages.contains(locale.languageCode);

  @override
  Future<MaterialLocalizations> load(Locale locale) {
    final _Material create = switch (locale.languageCode) {
      'zh' => MaterialLocalizationZh.new,
      'ja' => MaterialLocalizationJa.new,
      'ru' => MaterialLocalizationRu.new,
      _ => MaterialLocalizationEn.new,
    };
    final name = _formatLocale(locale);
    return SynchronousFuture(
      create(
        fullYearFormat: intl.DateFormat.y(name),
        compactDateFormat: intl.DateFormat.yMd(name),
        shortDateFormat: intl.DateFormat.yMMMd(name),
        mediumDateFormat: intl.DateFormat.MMMEd(name),
        longDateFormat: intl.DateFormat.yMMMMEEEEd(name),
        yearMonthFormat: intl.DateFormat.yMMMM(name),
        shortMonthDayFormat: intl.DateFormat.MMMd(name),
        decimalFormat: intl.NumberFormat.decimalPattern(name),
        twoDigitZeroPaddedFormat: intl.NumberFormat('00', name),
      ),
    );
  }

  @override
  bool shouldReload(_MaterialDelegate old) => false;
}

class _CupertinoDelegate extends LocalizationsDelegate<CupertinoLocalizations> {
  const _CupertinoDelegate();

  @override
  bool isSupported(Locale locale) => _languages.contains(locale.languageCode);

  @override
  Future<CupertinoLocalizations> load(Locale locale) {
    final _Cupertino create = switch (locale.languageCode) {
      'zh' => CupertinoLocalizationZh.new,
      'ja' => CupertinoLocalizationJa.new,
      'ru' => CupertinoLocalizationRu.new,
      _ => CupertinoLocalizationEn.new,
    };
    final name = _formatLocale(locale);
    return SynchronousFuture(
      create(
        fullYearFormat: intl.DateFormat.y(name),
        dayFormat: intl.DateFormat.d(name),
        weekdayFormat: intl.DateFormat.E(name),
        mediumDateFormat: intl.DateFormat.MMMEd(name),
        singleDigitHourFormat: intl.DateFormat('HH', name),
        singleDigitMinuteFormat: intl.DateFormat.m(name),
        doubleDigitMinuteFormat: intl.DateFormat('mm', name),
        singleDigitSecondFormat: intl.DateFormat.s(name),
        decimalFormat: intl.NumberFormat.decimalPattern(name),
      ),
    );
  }

  @override
  bool shouldReload(_CupertinoDelegate old) => false;
}

class _WidgetsDelegate extends LocalizationsDelegate<WidgetsLocalizations> {
  const _WidgetsDelegate();

  @override
  bool isSupported(Locale locale) => _languages.contains(locale.languageCode);

  @override
  Future<WidgetsLocalizations> load(Locale locale) =>
      SynchronousFuture(switch (locale.languageCode) {
        'zh' => const WidgetsLocalizationZh(),
        'ja' => const WidgetsLocalizationJa(),
        'ru' => const WidgetsLocalizationRu(),
        _ => const WidgetsLocalizationEn(),
      });

  @override
  bool shouldReload(_WidgetsDelegate old) => false;
}
