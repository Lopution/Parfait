import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/theme/replica_theme.dart';
import 'package:parfait/app/widgets/fit_label.dart';
import 'package:parfait/l10n/app_localizations.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';

import 'layout_fonts.dart';

/// Screen and font size each matrix cell runs at.
enum LayoutProfile {
  /// A typical 1080×2340 phone at the default font size.
  regular(Size(360, 780), 1.0),

  /// 320dp wide (a 720p screen, or a larger "display size") with a larger
  /// font: the tightest layout the app supports.
  compact(Size(320, 568), 1.3);

  const LayoutProfile(this.size, this.textScale);

  final Size size;
  final double textScale;
}

/// Registers [name] once per supported locale × [LayoutProfile], named
/// `name [ru/compact]`. Runs only under `test/locale_layout/`, where the
/// real fonts are loaded.
void localeLayoutMatrix(
  String name,
  Future<void> Function(
    WidgetTester tester,
    Locale locale,
    LayoutProfile profile,
  )
  body,
) {
  for (final locale in AppLocalizations.supportedLocales) {
    for (final profile in LayoutProfile.values) {
      testWidgets('$name [${locale.toLanguageTag()}/${profile.name}]', (
        tester,
      ) async {
        tester.view
          ..physicalSize = profile.size
          ..devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = profile.textScale;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await body(tester, locale, profile);
      });
    }
  }
}

/// The app theme with the harness fallback fonts, in [locale]. Providers
/// come from [container] when the test drives state through it, otherwise
/// from a fresh scope with [overrides].
Widget localeLayoutApp({
  required Locale locale,
  required Widget home,
  List<Override> overrides = const [],
  ProviderContainer? container,
}) {
  final app = MaterialApp(
    theme: replicaTheme(
      Brightness.light,
      fontFamilyFallback: layoutFontFallback,
    ),
    locale: locale,
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: appLocalizationsDelegates,
    home: home,
  );
  return container == null
      ? ProviderScope(overrides: overrides, child: app)
      : UncontrolledProviderScope(container: container, child: app);
}

/// Lets entrances and fades finish. Not `pumpAndSettle`: skeleton shimmer
/// loops forever.
Future<void> settleLayout(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// UI text — a paragraph equal to one of [locale]'s l10n messages — must
/// be whole: not cut by `maxLines`, not squeezed shorter than its lines,
/// a single line not wider than its box, and not shrunk below
/// [LabelFit.minScale] by a transform such as `FittedBox`. The one
/// exception is a [FitLabel] in the compact profile, which ellipsizes past
/// its floor with a tooltip. User content (titles, names, tags) may
/// ellipsize and is not checked. Layout errors (overflow) fail too.
void expectLocaleLayoutIntact(
  WidgetTester tester, {
  required Locale locale,
  required LayoutProfile profile,
}) {
  final exception = tester.takeException();
  expect(
    exception,
    isNull,
    reason: '[${locale.toLanguageTag()}/${profile.name}] layout error',
  );
  final messages = LocaleMessages.of(locale);
  final problems = <String>[];
  for (final element in find.byType(RichText).evaluate()) {
    final paragraph = element.renderObject! as RenderParagraph;
    final text = paragraph.text.toPlainText(includeSemanticsLabels: false);
    final key = messages.keyOf(text);
    if (key == null) continue;
    if (profile == LayoutProfile.compact && _inside<FitLabel>(element)) {
      continue;
    }
    // A text field's floating label shrinks to 0.75 by the Material spec.
    final defect = paragraphDefect(
      paragraph,
      checkScale: !_inside<InputDecorator>(element),
    );
    if (defect == null) continue;
    problems.add(
      '"$text" ($key): $defect\n    in ${_ancestry(element).join(' < ')}',
    );
  }
  expect(
    problems,
    isEmpty,
    reason:
        '[${locale.toLanguageTag()}/${profile.name}] UI text is not '
        'whole:\n  ${problems.join('\n  ')}',
  );
}

/// [expectLocaleLayoutIntact] down the whole page: lazy lists only build
/// what is on screen, so the page's main vertical scrollable (the first in
/// tree order) is stepped by most of a viewport until its end, checking at
/// every stop.
Future<void> expectPageLayoutIntact(
  WidgetTester tester, {
  required Locale locale,
  required LayoutProfile profile,
}) async {
  expectLocaleLayoutIntact(tester, locale: locale, profile: profile);
  final scrollables = find.byWidgetPredicate(
    (widget) =>
        widget is Scrollable && widget.axisDirection == AxisDirection.down,
  );
  if (scrollables.evaluate().isEmpty) return;
  final position = tester.state<ScrollableState>(scrollables.first).position;
  while (position.pixels < position.maxScrollExtent) {
    position.jumpTo(
      math.min(
        position.pixels + position.viewportDimension * 0.8,
        position.maxScrollExtent,
      ),
    );
    await settleLayout(tester);
    expectLocaleLayoutIntact(tester, locale: locale, profile: profile);
  }
}

/// What is wrong with a laid-out UI text paragraph, or null.
String? paragraphDefect(RenderParagraph paragraph, {bool checkScale = true}) {
  const slack = 0.5;
  if (paragraph.didExceedMaxLines) return 'cut by maxLines';
  final size = paragraph.size;
  if (paragraph.getMaxIntrinsicHeight(size.width) > size.height + slack) {
    return 'clipped: needs '
        '${paragraph.getMaxIntrinsicHeight(size.width).toStringAsFixed(1)}'
        'px of height, has ${size.height.toStringAsFixed(1)}px';
  }
  final singleLine = paragraph.maxLines == 1 || !paragraph.softWrap;
  if (singleLine &&
      paragraph.getMaxIntrinsicWidth(double.infinity) > size.width + slack) {
    return 'wider than its box: needs '
        '${paragraph.getMaxIntrinsicWidth(double.infinity).toStringAsFixed(1)}'
        'px, has ${size.width.toStringAsFixed(1)}px';
  }
  if (!checkScale) return null;
  final scale = _scaleToRoot(paragraph);
  if (scale < LabelFit.minScale - 1e-3) {
    return 'shrunk to ${scale.toStringAsFixed(2)} by a transform';
  }
  return null;
}

/// Horizontal scale of [paragraph] in screen space.
double _scaleToRoot(RenderObject paragraph) {
  final matrix = paragraph.getTransformTo(null);
  final dx =
      MatrixUtils.transformPoint(matrix, const Offset(1, 0)) -
      MatrixUtils.transformPoint(matrix, Offset.zero);
  return math.sqrt(dx.dx * dx.dx + dx.dy * dx.dy);
}

bool _inside<T extends Widget>(Element element) {
  var found = false;
  element.visitAncestorElements((ancestor) {
    found = ancestor.widget is T;
    return !found;
  });
  return found;
}

/// The nearest ancestor widget types, for locating a failure.
List<String> _ancestry(Element element) {
  final types = <String>[];
  element.visitAncestorElements((ancestor) {
    final type = ancestor.widget.runtimeType.toString();
    if (!type.startsWith('_')) types.add(type);
    return types.length < 4;
  });
  return types;
}

/// A locale's l10n messages, read from its ARB file, matched against
/// paragraph text: plain messages by equality, messages with `{name}`
/// placeholders by pattern.
class LocaleMessages {
  LocaleMessages._(this._exact, this._patterns);

  static final _cache = <String, LocaleMessages>{};
  static final _letter = RegExp(r'\p{L}', unicode: true);

  static LocaleMessages of(Locale locale) =>
      _cache[locale.languageCode] ??= _load(locale.languageCode);

  static LocaleMessages _load(String language) {
    final file = File('lib/l10n/app_$language.arb');
    final arb = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    final exact = <String, String>{};
    final patterns = <(RegExp, String)>[];
    final placeholder = RegExp(r'\{\w+\}');
    for (final MapEntry(:key, :value) in arb.entries) {
      if (key.startsWith('@') || value is! String) continue;
      if (!value.contains(placeholder)) {
        exact[value] = key;
        continue;
      }
      // A message that is placeholders plus punctuation ("{action}:
      // {reason}") would claim any user text with that punctuation.
      if (!value.replaceAll(placeholder, '').contains(_letter)) continue;
      final pattern = value
          .split(placeholder)
          .map(RegExp.escape)
          .join('(?:.|\\n)+?');
      patterns.add((RegExp('^$pattern\$'), key));
    }
    return LocaleMessages._(exact, patterns);
  }

  final Map<String, String> _exact;
  final List<(RegExp, String)> _patterns;

  /// The key whose message [text] is, or null for other text.
  String? keyOf(String text) {
    if (text.isEmpty) return null;
    final exact = _exact[text];
    if (exact != null) return exact;
    for (final (pattern, key) in _patterns) {
      if (pattern.hasMatch(text)) return key;
    }
    return null;
  }
}
