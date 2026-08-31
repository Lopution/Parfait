import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/network/compat/dns_message.dart';

/// Regression: real DoH (223.5.5.5) response for `cloudflare-ech.com` HTTPS
/// RR captured in mainland China without proxy (see task 08-29 research).
/// parseHttpsSvcParams previously read SvcPriority as u8 instead of u16
/// (RFC 9460 §2.2), which desynced the SvcParam stream and threw
/// `truncated data` on every real Cloudflare ECH response.
void main() {
  test('parses real cloudflare-ech.com HTTPS RR response from 223.5.5.5', () {
    const hex =
        'abcd818000010001000000010e636c6f7564666c6172652d65636803636f6d00'
        '00410001c00c00410001000000ba008800010000010006026833026832000400'
        '0868120a7668120b76000500470045fe0d0041d500200020c15c0dc77c1a06'
        'fdc9673c404f8498b784449370bffe2c8373d9c271bb956e42000400010001'
        '0012636c6f7564666c6172652d6563682e636f6d0000000600202606470000'
        '0000000000000068120a7626064700000000000000000068120b76';
    final bytes = Uint8List.fromList(_hexToBytes(hex));
    final response = decodeResponse(bytes);
    expect(response.id, 0xabcd);
    expect(response.answers, hasLength(1));

    final answer = response.answers.single;
    expect(answer.type, 65);
    expect(answer.rdata, isNotNull);

    final config = echConfigFromHttpsRdata(answer.rdata!);
    expect(config, isNotNull);
    // RFC 9849 ECHConfigList: first two bytes are the list length (0x0045 =
    // 69), so a valid single config is 2 + 69 = 71 bytes.
    expect(config!.length, 71);
    expect(config[0], 0x00);
    expect(config[1], 0x45);

    // The config must also parse through the SvcParam stream correctly:
    // key 1 (alpn h3,h2), key 4 (ipv4hint), key 5 (ech), key 6 (ipv6hint).
    final params = parseHttpsSvcParams(answer.rdata!);
    expect(params.map((p) => p.key), containsAll([1, 4, 5, 6]));
    expect(params.firstWhere((p) => p.key == 5).value, equals(config));

    // ipv4hint (key 4) carries the ECH front's anycast connect IPs — the
    // clean target that bypasses polluted answers for the target host.
    final hints = ipv4HintFromHttpsRdata(answer.rdata!);
    expect(
      hints.map((a) => a.address),
      containsAll(['104.18.10.118', '104.18.11.118']),
    );
  });
}

List<int> _hexToBytes(String hex) {
  final out = <int>[];
  for (var i = 0; i < hex.length; i += 2) {
    out.add(int.parse(hex.substring(i, i + 2), radix: 16));
  }
  return out;
}
