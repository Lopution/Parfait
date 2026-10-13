import 'dart:typed_data';

/// The PNG signature and an RGBA IHDR chunk of [width]×[height] with a zero
/// CRC: enough for the readers that sniff a format and its size.
Uint8List pngHeader(int width, int height) => Uint8List.fromList([
  ...const [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a],
  ..._be32(13),
  ...'IHDR'.codeUnits,
  ..._be32(width),
  ..._be32(height),
  ...const [8, 6, 0, 0, 0, 0, 0, 0, 0],
]);

/// A RIFF/WEBP (VP8 lossy) header the input validator accepts: it reads the
/// 9d 01 2a start code at offset 26 and LE16 dimensions at 30 and 32.
Uint8List webpHeader(int width, int height) => Uint8List.fromList([
  ...'RIFF'.codeUnits,
  ...const [14, 0, 0, 0],
  ...'WEBPVP8 '.codeUnits,
  ...const [14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x9d, 0x01, 0x2a, 0],
  ...[width & 0xff, (width >> 8) & 0xff],
  ...[height & 0xff, (height >> 8) & 0xff],
]);

List<int> _be32(int value) =>
    (ByteData(4)..setUint32(0, value)).buffer.asUint8List();
