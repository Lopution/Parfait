/// Local TXT novel decoding — Shaft's chain: BOM detection first, strict
/// UTF-8 next, GBK fallback for legacy Simplified-Chinese files, and a
/// visibly-tagged UTF-8 lossy last resort so mojibake is never silent.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:charset/charset.dart';

/// How a file was decoded; the lossy tag lets the UI annotate possible
/// mojibake instead of guessing.
enum LocalNovelEncoding { utf8, utf16, gbk, utf8Lossy }

/// Decoded local text plus the encoding that produced it.
typedef DecodedLocalNovel = (String text, LocalNovelEncoding encoding);

/// Decodes raw TXT bytes. Order matters: a BOM is authoritative, UTF-8 is
/// the common case, GBK covers the legacy files Shaft targets, and the
/// final lossy pass guarantees some text over an import failure.
DecodedLocalNovel decodeLocalNovelText(Uint8List bytes) {
  if (bytes.isEmpty) return ('', LocalNovelEncoding.utf8);
  // BOMs are checked before any heuristic: FF FE / FE FF are UTF-16, and a
  // UTF-8 BOM still decodes as UTF-8.
  if (bytes.length >= 2) {
    if (bytes[0] == 0xFF && bytes[1] == 0xFE ||
        bytes[0] == 0xFE && bytes[1] == 0xFF) {
      return (utf16.decode(bytes), LocalNovelEncoding.utf16);
    }
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    return (utf8.decode(bytes.sublist(3)), LocalNovelEncoding.utf8);
  }
  try {
    return (utf8.decode(bytes), LocalNovelEncoding.utf8);
  } on FormatException {
    // Not valid UTF-8 — fall through to the legacy-codepage chain.
  }
  try {
    return (gbk.decode(bytes), LocalNovelEncoding.gbk);
  } on FormatException {
    // Bytes map to no known charset — produce visible text anyway.
  }
  return (
    utf8.decode(bytes, allowMalformed: true),
    LocalNovelEncoding.utf8Lossy,
  );
}
