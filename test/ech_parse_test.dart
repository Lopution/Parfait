import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/network/compat/dns_message.dart';

void main() {
  test('decode real 223.5.5.5 ech65 response', () {
    final bytes = File('/tmp/ech65.out').readAsBytesSync();
    final response = decodeResponse(Uint8List.fromList(bytes));
    // ignore: avoid_print
    print('id=${response.id} answers=${response.answers.length}');
    for (final a in response.answers) {
      // ignore: avoid_print
      print('  type=${a.type} ttl=${a.ttl} rdata=${a.rdata?.length}');
    }
    expect(response.answers, isNotEmpty);
    final echAnswer = response.answers.firstWhere((a) => a.type == 65);
    final config = echConfigFromHttpsRdata(echAnswer.rdata!);
    // ignore: avoid_print
    print('ECH config bytes: ${config?.length}');
    expect(config, isNotNull);
    expect(config!.length, greaterThan(40));
  });
}
