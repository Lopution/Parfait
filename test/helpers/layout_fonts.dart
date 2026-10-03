import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// Fallback families for the locale layout harness, in the order the device
/// reaches them: Cyrillic in Roboto (the AOSP system font), then CJK in a
/// box font with real CJK advances.
const layoutFontFallback = ['Roboto', cjkBoxFamily];

/// Generated CJK stand-in: full-width glyphs advance 1em, half-width forms
/// 0.5em, with Noto Sans CJK's line metrics.
const cjkBoxFamily = 'ParfaitTestCjk';

/// Registers Montserrat (the app font), Roboto and the CJK box font so text
/// measures with real glyph widths instead of FlutterTest's 1em squares.
/// Fails loudly when a font is missing: a silent fallback to the test font
/// would let every width check pass.
Future<void> loadLayoutFonts() async {
  final montserrat = FontLoader('Montserrat');
  for (final weight in const ['regular', 'medium', 'semi_bold', 'bold']) {
    montserrat.addFont(rootBundle.load('assets/fonts/montserrat_$weight.ttf'));
  }
  final roboto = FontLoader('Roboto');
  for (final weight in const ['Regular', 'Medium', 'Bold']) {
    roboto.addFont(Future.value(_sdkFont('Roboto-$weight.ttf')));
  }
  final cjk = FontLoader(cjkBoxFamily)
    ..addFont(Future.value(ByteData.sublistView(buildCjkBoxFont())));
  await Future.wait([montserrat.load(), roboto.load(), cjk.load()]);
}

/// Roboto ships with the Flutter SDK's material fonts.
ByteData _sdkFont(String name) {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) {
    throw StateError(
      'FLUTTER_ROOT is not set; run the layout tests through `flutter test` '
      'so Roboto can be read from the SDK cache.',
    );
  }
  final file = File('$root/bin/cache/artifacts/material_fonts/$name');
  if (!file.existsSync()) {
    throw StateError(
      'Missing ${file.path}: the layout harness measures Cyrillic in the '
      "SDK's Roboto. If the SDK moved its material fonts, update this path.",
    );
  }
  return ByteData.sublistView(file.readAsBytesSync());
}

const _unitsPerEm = 1000;
// Noto Sans CJK hhea metrics, the AOSP default CJK font.
const _ascent = 1160;
const _descent = 288;
const _full = 1000;
const _half = 500;

/// (first, last, glyph): glyph 1 is the full-width box, 2 the half-width.
const _cjkRanges = [
  (0x2E80, 0x2FDF, 1), // CJK radicals, Kangxi radicals
  (0x3000, 0x303F, 1), // CJK symbols and punctuation
  (0x3040, 0x30FF, 1), // hiragana, katakana
  (0x3100, 0x312F, 1), // bopomofo
  (0x31F0, 0x31FF, 1), // katakana phonetic extensions
  (0x3200, 0x33FF, 1), // enclosed CJK, CJK compatibility
  (0x3400, 0x4DBF, 1), // extension A
  (0x4E00, 0x9FFF, 1), // unified ideographs
  (0xF900, 0xFAFF, 1), // compatibility ideographs
  (0xFE30, 0xFE4F, 1), // compatibility forms
  (0xFF00, 0xFF60, 1), // full-width forms
  (0xFF61, 0xFFDC, 2), // half-width forms
  (0xFFE0, 0xFFE6, 1), // full-width signs
  (0xFFE8, 0xFFEE, 2), // half-width signs
  (0x20000, 0x2A6DF, 1), // extension B
];

/// A minimal TrueType font: `.notdef`, a full-width box and a half-width
/// box, mapped by a format 13 (many-to-one) cmap. Boxes rather than empty
/// glyphs so a screenshot shows where CJK text sits.
Uint8List buildCjkBoxFont() {
  final glyphs = [Uint8List(0), _box(_full), _box(_half)];
  final glyf = _Bytes();
  final loca = _Bytes();
  for (final glyph in glyphs) {
    loca.u16(glyf.length ~/ 2);
    glyf.bytes(glyph);
  }
  loca.u16(glyf.length ~/ 2);

  final tables = <String, Uint8List>{
    'OS/2': _os2(),
    'cmap': _cmap(),
    'glyf': glyf.done(),
    'head': _head(),
    'hhea': _hhea(),
    'hmtx':
        (_Bytes()
              ..u16(_full)
              ..i16(0)
              ..u16(_full)
              ..i16(50)
              ..u16(_half)
              ..i16(50))
            .done(),
    'loca': loca.done(),
    'maxp': _maxp(),
    'name': _name(),
    'post':
        (_Bytes()
              ..u32(0x00030000)
              ..u32(0)
              ..i16(-100)
              ..i16(50)
              ..u32(1)
              ..u32(0)
              ..u32(0)
              ..u32(0)
              ..u32(0))
            .done(),
  };
  final tags = tables.keys.toList()..sort();
  final count = tags.length;
  final selector = count.bitLength - 1;
  final searchRange = (1 << selector) * 16;
  final font = _Bytes()
    ..u32(0x00010000)
    ..u16(count)
    ..u16(searchRange)
    ..u16(selector)
    ..u16(count * 16 - searchRange);
  final body = _Bytes();
  var headOffset = 0;
  final dataStart = 12 + 16 * count;
  for (final tag in tags) {
    final data = tables[tag]!;
    if (tag == 'head') headOffset = dataStart + body.length;
    font
      ..bytes(ascii.encode(tag))
      ..u32(_checksum(data))
      ..u32(dataStart + body.length)
      ..u32(data.length);
    body
      ..bytes(data)
      ..pad();
  }
  font.bytes(body.done());
  final bytes = font.done();
  final adjustment = (0xB1B0AFBA - _checksum(bytes)) & 0xFFFFFFFF;
  ByteData.sublistView(bytes).setUint32(headOffset + 8, adjustment);
  return bytes;
}

Uint8List _box(int width) {
  const y0 = -70, y1 = 830;
  final x0 = 50, x1 = width - 50;
  final xs = [x0, x1, x1, x0];
  final ys = [y0, y0, y1, y1];
  final glyph = _Bytes()
    ..i16(1)
    ..i16(x0)
    ..i16(y0)
    ..i16(x1)
    ..i16(y1)
    ..u16(3) // last point of the only contour
    ..u16(0) // no instructions
    ..bytes(Uint8List.fromList(const [1, 1, 1, 1])); // on-curve, long x/y
  for (var i = 0; i < 4; i++) {
    glyph.i16(i == 0 ? xs[0] : xs[i] - xs[i - 1]);
  }
  for (var i = 0; i < 4; i++) {
    glyph.i16(i == 0 ? ys[0] : ys[i] - ys[i - 1]);
  }
  return (glyph..pad()).done();
}

Uint8List _head() {
  final head = _Bytes()
    ..u32(0x00010000)
    ..u32(0x00010000)
    ..u32(0) // checkSumAdjustment, patched once the font is assembled
    ..u32(0x5F0F3CF5)
    ..u16(0x000B)
    ..u16(_unitsPerEm)
    ..u32(0)
    ..u32(0) // created
    ..u32(0)
    ..u32(0) // modified
    ..i16(0)
    ..i16(-_descent)
    ..i16(_full)
    ..i16(_ascent)
    ..u16(0) // macStyle
    ..u16(8) // lowestRecPPEM
    ..i16(2) // fontDirectionHint
    ..i16(0) // short loca
    ..i16(0);
  return head.done();
}

Uint8List _hhea() {
  final hhea = _Bytes()
    ..u32(0x00010000)
    ..i16(_ascent)
    ..i16(-_descent)
    ..i16(0) // lineGap
    ..u16(_full)
    ..i16(0)
    ..i16(0)
    ..i16(_full)
    ..i16(1) // caretSlopeRise
    ..i16(0)
    ..i16(0);
  for (var i = 0; i < 5; i++) {
    hhea.i16(0); // reserved ×4, metricDataFormat
  }
  return (hhea..u16(3)).done();
}

Uint8List _maxp() {
  final maxp = _Bytes()
    ..u32(0x00010000)
    ..u16(3) // glyphs
    ..u16(4) // maxPoints
    ..u16(1) // maxContours
    ..u16(0)
    ..u16(0)
    ..u16(2); // maxZones
  for (var i = 0; i < 8; i++) {
    maxp.u16(0);
  }
  return maxp.done();
}

Uint8List _cmap() {
  final groups = _Bytes();
  for (final (first, last, glyph) in _cjkRanges) {
    groups
      ..u32(first)
      ..u32(last)
      ..u32(glyph);
  }
  final groupBytes = groups.done();
  return (_Bytes()
        ..u16(0)
        ..u16(1)
        ..u16(3) // Windows
        ..u16(10) // full Unicode repertoire
        ..u32(12)
        ..u16(13) // many-to-one range mappings
        ..u16(0)
        ..u32(16 + groupBytes.length)
        ..u32(0)
        ..u32(_cjkRanges.length)
        ..bytes(groupBytes))
      .done();
}

Uint8List _name() {
  const records = [
    (1, cjkBoxFamily),
    (2, 'Regular'),
    (4, cjkBoxFamily),
    (6, cjkBoxFamily),
  ];
  final head = _Bytes()
    ..u16(0)
    ..u16(records.length)
    ..u16(6 + 12 * records.length);
  final strings = _Bytes();
  for (final (id, text) in records) {
    final utf16 = _Bytes();
    for (final unit in text.codeUnits) {
      utf16.u16(unit);
    }
    final encoded = utf16.done();
    head
      ..u16(3)
      ..u16(1)
      ..u16(0x409)
      ..u16(id)
      ..u16(encoded.length)
      ..u16(strings.length);
    strings.bytes(encoded);
  }
  return (head..bytes(strings.done())).done();
}

Uint8List _os2() {
  final os2 = _Bytes()
    ..u16(4) // version
    ..i16(_full) // xAvgCharWidth
    ..u16(400)
    ..u16(5)
    ..u16(0); // fsType
  for (final value in const [650, 700, 0, 140, 650, 700, 0, 480, 50, 250, 0]) {
    os2.i16(value); // sub/superscript, strikeout, family class
  }
  os2
    ..bytes(Uint8List(10)) // panose
    ..u32(0)
    ..u32(0)
    ..u32(0)
    ..u32(0) // unicode ranges
    ..bytes(ascii.encode('NONE'))
    ..u16(0x40) // REGULAR: line height comes from hhea
    ..u16(0x3000)
    ..u16(0xFFEE)
    ..i16(880)
    ..i16(-120)
    ..i16(0)
    ..u16(_ascent)
    ..u16(_descent)
    ..u32(0)
    ..u32(0) // code page ranges
    ..i16(500) // sxHeight
    ..i16(700) // sCapHeight
    ..u16(0)
    ..u16(0x20)
    ..u16(0);
  return os2.done();
}

int _checksum(Uint8List data) {
  final padded = Uint8List((data.length + 3) & ~3)..setAll(0, data);
  final view = ByteData.sublistView(padded);
  var sum = 0;
  for (var i = 0; i < padded.length; i += 4) {
    sum = (sum + view.getUint32(i)) & 0xFFFFFFFF;
  }
  return sum;
}

/// Big-endian byte writer.
class _Bytes {
  final _out = BytesBuilder(copy: false);

  int get length => _out.length;

  void u16(int value) => _out.add([(value >> 8) & 0xFF, value & 0xFF]);

  void i16(int value) => u16(value & 0xFFFF);

  void u32(int value) => _out.add([
    (value >> 24) & 0xFF,
    (value >> 16) & 0xFF,
    (value >> 8) & 0xFF,
    value & 0xFF,
  ]);

  void bytes(List<int> data) => _out.add(data);

  /// Pads to a 4-byte boundary.
  void pad() {
    final rest = (4 - length % 4) % 4;
    if (rest > 0) _out.add(List.filled(rest, 0));
  }

  Uint8List done() => _out.toBytes();
}
