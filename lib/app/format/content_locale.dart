import 'package:flutter/widgets.dart';

/// The text locale for user content (titles, names, tags, captions).
///
/// Skia resolves a character missing from the primary font by asking the
/// fallback fonts that match the text locale first, and only then every
/// fallback family in `fonts.xml` order. Kana under a zh locale misses the
/// zh fonts — some OEM zh fonts carry no kana at all — and falls through to
/// that full scan, probing the cmap of ~100 rarely used script fonts on the
/// UI thread. Tagging the paragraph with its script's language lands the
/// lookup on the right fallback font at once, and renders Japanese kanji
/// with Japanese glyphs.
///
/// Returns null when the inherited UI locale already resolves the text.
Locale? contentLocale(BuildContext context, String text) =>
    contentScriptLocale(text, Localizations.maybeLocaleOf(context));

/// [contentLocale] without a [BuildContext]: kana → ja, hangul → ko, other
/// Han text → ja unless [uiLocale] is already a CJK language.
Locale? contentScriptLocale(String text, Locale? uiLocale) {
  var han = false;
  for (final rune in text.runes) {
    if (_isKana(rune)) return _japanese;
    if (_isHangul(rune)) return _korean;
    han = han || _isHan(rune);
  }
  if (!han) return null;
  final ui = uiLocale?.languageCode;
  return ui == 'zh' || ui == 'ja' || ui == 'ko' ? null : _japanese;
}

const _japanese = Locale('ja');
const _korean = Locale('ko');

bool _isKana(int c) =>
    (c >= 0x3040 && c <= 0x30FF) || // hiragana, katakana
    (c >= 0x31F0 && c <= 0x31FF) || // katakana phonetic extensions
    (c >= 0xFF66 && c <= 0xFF9F); // halfwidth katakana

bool _isHangul(int c) =>
    (c >= 0xAC00 && c <= 0xD7AF) || // syllables
    (c >= 0x1100 && c <= 0x11FF) || // jamo
    (c >= 0x3130 && c <= 0x318F); // compatibility jamo

bool _isHan(int c) =>
    (c >= 0x4E00 && c <= 0x9FFF) || // unified ideographs
    (c >= 0x3400 && c <= 0x4DBF) || // extension A
    (c >= 0xF900 && c <= 0xFAFF); // compatibility ideographs
