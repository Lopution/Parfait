import 'package:flutter_test/flutter_test.dart';
import 'package:parfait/core/format/byte_size.dart';

void main() {
  test('byte size renders B below 1 KiB', () {
    expect(formatByteSize(0), '0 B');
    expect(formatByteSize(1023), '1023 B');
  });

  test('byte size renders one-decimal KiB below 1 MiB', () {
    expect(formatByteSize(1024), '1.0 KiB');
    expect(formatByteSize(1536), '1.5 KiB');
    expect(formatByteSize(1024 * 1024 - 1), '1024.0 KiB');
  });

  test('byte size renders one-decimal MiB from 1 MiB', () {
    expect(formatByteSize(1024 * 1024), '1.0 MiB');
    expect(formatByteSize((1024 * 1024 * 1.5).round()), '1.5 MiB');
  });
}
