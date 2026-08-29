import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/network/compat/dns_message.dart';

Uint8List _hex(String hex) {
  final cleaned = hex.replaceAll(RegExp(r'\s+'), '');
  return Uint8List.fromList([
    for (var i = 0; i < cleaned.length; i += 2)
      int.parse(cleaned.substring(i, i + 2), radix: 16),
  ]);
}

void main() {
  group('encodeQuery', () {
    test('encodes header, name, type and class', () {
      final bytes = encodeQuery(id: 0x1234, name: 'app-api.pixiv.net', type: 1);
      expect(bytes.sublist(0, 12), _hex('1234 0100 0001 0000 0000 0000'));
      // header(12) + label-length(1) + "app-api"(7) + label-length(1).
      expect(
        String.fromCharCodes(bytes.sublist(13, 13 + 7)),
        'app-api',
      );
      expect(bytes[20], 5);
      // trailing root + type + class IN.
      expect(bytes.sublist(bytes.length - 5), [0, 0, 1, 0, 1]);
    });

    test('rejects out-of-range id and pathological names', () {
      expect(
        () => encodeQuery(id: 0x10000, name: 'a.com'),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => encodeQuery(id: 0, name: ''),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => encodeQuery(id: 0, name: 'a..com'),
        throwsA(isA<ArgumentError>()),
      );
      final long = '${'a' * 64}.com';
      expect(
        () => encodeQuery(id: 0, name: long),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('recursionDesired flag is controllable', () {
      final on = encodeQuery(id: 0, name: 'example.com', recursionDesired: true);
      final off = encodeQuery(id: 0, name: 'example.com', recursionDesired: false);
      expect(on[2], 0x01);
      expect(off[2], 0x00);
    });
  });

  group('decodeResponse', () {
    test('decodes a single A answer with TTL', () {
      // id=0x1234, flags=0x8180 (QR RD RA), 1 question, 1 answer.
      final bytes = _hex(
        '1234 8180 0001 0001 0000 0000 '
        '07617070 2d617069 05706978 6976036e 657400 0001 0001 '
        'c00c 0001 0001 0000003c 0004 0102 0304',
      );
      final response = decodeResponse(bytes);
      expect(response.id, 0x1234);
      expect(response.isOk, isTrue);
      expect(response.isTruncated, isFalse);
      expect(response.question?.name, 'app-api.pixiv.net');
      expect(response.question?.type, 1);
      expect(response.addressAnswers, hasLength(1));
      expect(response.addressAnswers.single.address, InternetAddress('1.2.3.4'));
      expect(response.addressAnswers.single.ttl, 60);
    });

    test('decodes AAAA answer into an IPv6 address', () {
      final bytes = _hex(
        '0001 8180 0001 0001 0000 0000 '
        '0469 7069 7600 001c 0001 '
        'c00c 001c 0001 0000003c 0010 '
        '2606 4700 4700 0000 0000 0000 0000 1111',
      );
      final response = decodeResponse(bytes);
      final parsed = InternetAddress('2606:4700:4700::1111');
      expect(
        response.addressAnswers.single.address!.rawAddress,
        parsed.rawAddress,
      );
    });

    test('reports truncation and rcode', () {
      final truncated = decodeResponse(
        _hex('0001 8380 0001 0000 0000 0000 0469 7069 7600 0001 0001'),
      );
      expect(truncated.isTruncated, isTrue);
      expect(truncated.isOk, isTrue);

      final nxdomain = decodeResponse(
        _hex('0001 8183 0001 0000 0000 0000 0469 7069 7600 0001 0001'),
      );
      expect(nxdomain.isTruncated, isFalse);
      expect(nxdomain.isOk, isFalse);
      expect(nxdomain.rcode, 3);
    });

    test('follows compression pointers in answer names', () {
      final bytes = _hex(
        '0001 8180 0001 0001 0000 0000 '
        '0469 7069 7600 0001 0001 '
        'c00c 0001 0001 0000003c 0004 0a00 0001',
      );
      final response = decodeResponse(bytes);
      expect(response.answers.single.name, 'ipiv');
      expect(response.addressAnswers.single.address, InternetAddress('10.0.0.1'));
    });

    test('mixed A/AAAA answers keep both', () {
      final bytes = _hex(
        '0001 8180 0001 0002 0000 0000 '
        '0469 7069 7600 0001 0001 '
        'c00c 0001 0001 0000003c 0004 0102 0304 '
        'c00c 001c 0001 0000003c 0010 '
        '2001 0db8 0000 0000 0000 0000 0000 0001',
      );
      final response = decodeResponse(bytes);
      expect(response.addressAnswers, hasLength(2));
      final a = InternetAddress('1.2.3.4');
      final aaaa = InternetAddress('2001:db8::1');
      expect(
        response.addressAnswers.map((e) => e.address!.rawAddress).toList(),
        [a.rawAddress, aaaa.rawAddress],
      );
    });

    test('ignores non-address record types', () {
      final bytes = _hex(
        '0001 8180 0001 0001 0000 0000 '
        '0469 7069 7600 0001 0001 '
        'c00c 000f 0001 0000003c 0009 0a42 6f6f 7468 6775 6172 64',
      );
      // TXT record (type 15) with payload "Boothguard".
      final response = decodeResponse(bytes);
      expect(response.addressAnswers, isEmpty);
      expect(response.answers, hasLength(1));
      expect(response.answers.single.type, 15);
    });

    test('rejects malformed payloads observably', () {
      expect(
        () => decodeResponse(Uint8List(0)),
        throwsA(isA<DnsCodecException>()),
      );
      expect(
        () => decodeResponse(Uint8List(11)),
        throwsA(isA<DnsCodecException>()),
      );
      // Answer claims 4-byte data but message ends early.
      expect(
        () => decodeResponse(
          _hex('0001 8180 0001 0001 0000 0000 0469 7069 7600 0001 0001 '
              'c00c 0001 0001 0000003c 0004 0102'),
        ),
        throwsA(isA<DnsCodecException>()),
      );
    });

    test('bounded compression pointer loop raises', () {
      // Two pointers pointing at each other.
      final bytes = _hex(
        '0001 8180 0001 0001 0000 0000 0469 7069 7600 0001 0001 '
        'c00c 0001 0001 0000003c 0004 0a00 0001',
      );
      // Sanity: pointer target 0x000c -> offset 0 is the name "ipiv" from
      // the question; a self-loop is not constructible in 12 bytes, so the
      // bounded-loop guarantee is exercised via a crafted pointer chain.
      final loop = Uint8List.fromList([
        ...bytes.sublist(0, 12), // header + question
        0xc0, 0x0c, // answer name -> offset 12 (points at itself)
      ]);
      late Object error;
      try {
        decodeResponse(loop);
      } on Object catch (e) {
        error = e;
      }
      expect(error, isA<DnsCodecException>());
    });
  });
}