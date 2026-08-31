/// Minimal RFC 1035 wire codec for the subset of DNS messages used by the
/// strict DoH resolver: one question, A/AAAA answers, TTLs, truncation and
/// error status. Pure functions — no I/O, no dependencies.
library;

import 'dart:io';
import 'dart:typed_data';

/// A parsed DNS question (QNAME + QTYPE).
class DnsQuestion {
  const DnsQuestion({required this.name, required this.type});

  final String name;
  final int type;
}

/// A single resource record from the answer section. Non-address record
/// types are carried opaquely (the strict resolver ignores them), except
/// HTTPS records (type 65) whose rdata is retained for ECH config parsing.
class DnsAnswer {
  const DnsAnswer({
    required this.name,
    required this.type,
    required this.ttl,
    this.address,
    this.rdata,
  });

  final String name;
  final int type;
  final int ttl;
  final InternetAddress? address;

  /// Raw RDATA for non-A/AAAA records (only kept for type 65 HTTPS so the
  /// SvcParams can be parsed). Null for A/AAAA answers.
  final Uint8List? rdata;
}

/// DNS record type constants used by this codec.
class DnsRecordType {
  static const int a = 1;
  static const int https = 65;
  static const int aaaa = 28;
}

/// A decoded DNS response.
class DnsResponse {
  const DnsResponse({
    required this.id,
    required this.isTruncated,
    required this.rcode,
    required this.question,
    required this.answers,
    required this.rawSize,
  });

  final int id;
  final bool isTruncated;
  final int rcode;

  /// The question echoed by the server (may be empty on FORMERR).
  final DnsQuestion? question;
  final List<DnsAnswer> answers;
  final int rawSize;

  bool get isOk => rcode == 0;

  /// Address-bearing answers (A/AAAA) for the asked name.
  List<DnsAnswer> get addressAnswers =>
      answers.where((a) => a.address != null).toList(growable: false);
}

class DnsCodecException implements Exception {
  const DnsCodecException(this.message);

  final String message;

  @override
  String toString() => 'DnsCodecException: $message';
}

/// Encodes one query for [name] of [type] (1 = A, 28 = AAAA) with [id].
Uint8List encodeQuery({
  required int id,
  required String name,
  int type = 1,
  bool recursionDesired = true,
}) {
  if (id < 0 || id > 0xffff) {
    throw ArgumentError.value(id, 'id', 'outside 0..65535');
  }
  final writer = _Writer();
  writer.u16(id);
  writer.u16((recursionDesired ? 0x0100 : 0) | 0); // flags: RD
  writer.u16(1); // QDCOUNT
  writer.u16(0); // ANCOUNT
  writer.u16(0); // NSCOUNT
  writer.u16(0); // ARCOUNT
  writer.encodedName(name);
  writer.u16(type);
  writer.u16(1); // CLASS IN
  return writer.bytes;
}

/// Decodes a response payload (the body of `application/dns-message`).
DnsResponse decodeResponse(Uint8List bytes) {
  final reader = _Reader(bytes);
  if (bytes.length < 12) {
    throw const DnsCodecException('response shorter than DNS header');
  }
  final id = reader.u16();
  final flags = reader.u16();
  final questionCount = reader.u16();
  final answerCount = reader.u16();
  reader.u16(); // NSCOUNT
  reader.u16(); // ARCOUNT

  DnsQuestion? question;
  for (var i = 0; i < questionCount; i++) {
    final name = reader.name();
    final type = reader.u16();
    reader.u16(); // class
    question = DnsQuestion(name: name, type: type);
  }

  final answers = <DnsAnswer>[];
  for (var i = 0; i < answerCount; i++) {
    answers.add(_readAnswer(reader));
  }

  final isTruncated = flags & 0x0200 != 0;
  final rcode = flags & 0x000f;
  return DnsResponse(
    id: id,
    isTruncated: isTruncated,
    rcode: rcode,
    question: question,
    answers: answers,
    rawSize: bytes.length,
  );
}

DnsAnswer _readAnswer(_Reader reader) {
  final name = reader.name();
  final type = reader.u16();
  reader.u16(); // class
  final ttl = reader.u32();
  final dataLength = reader.u16();
  final data = reader.bytes(dataLength);
  final address = switch (type) {
    1 when dataLength == 4 => InternetAddress(
      '${data[0]}.${data[1]}.${data[2]}.${data[3]}',
    ),
    28 when dataLength == 16 => InternetAddress(
      List.generate(
        8,
        (i) => ByteData.sublistView(
          data,
          i * 2,
          i * 2 + 2,
        ).getUint16(0).toRadixString(16),
      ).join(':'),
    ),
    _ => null,
  };
  return DnsAnswer(
    name: name,
    type: type,
    ttl: ttl,
    address: address,
    // Keep rdata only for HTTPS records (type 65): the DohResolver's ECH
    // config lookup needs the SvcParams, while A/AAAA answers already have
    // their address decoded.
    rdata: type == 65 ? data : null,
  );
}

/// SvcParam key for ECH (RFC 9460 §9.5 / RFC 9849).
const int kSvcParamKeyEch = 5;

/// SvcParam key for ipv4hint (RFC 9460 §7.1: a sequence of IPv4 addresses,
/// each 4 bytes). Used as the ECH front's connect target when present.
const int kSvcParamKeyIpv4Hint = 4;

/// One parsed SvcParam from an HTTPS record's RDATA (RFC 9460 §2.2).
class HttpsSvcParam {
  const HttpsSvcParam({required this.key, required this.value});

  final int key;
  final Uint8List value;
}

/// Parses the SvcParams of an HTTPS (type 65) RDATA payload.
///
/// Supports RFC 9460 §2.2 (key=value pairs with 16-bit keys, 16-bit length
/// prefixed values) and the mandatory-key 8-bit field at the start. Unknown
/// keys are skipped. Returns an empty list when `ech` is absent.
///
/// Exceptions (DnsCodecException) are thrown on truncated/malformed input.
List<HttpsSvcParam> parseHttpsSvcParams(Uint8List rdata) {
  final reader = _Reader(rdata);
  final params = <HttpsSvcParam>[];
  if (rdata.isEmpty) {
    return params;
  }
  // RFC 9460 §2.2: SvcPriority is a 16-bit unsigned integer, followed by
  // the TargetName (wire-format domain name, must not use compression) and
  // the SvcParams.
  reader.u16(); // SvcPriority
  // TargetName is a wire-format domain name; read it but ignore its value.
  // Compression in the target name is not allowed by RFC 9460 §2.2 except
  // as an escape for the root label, and the reader handles plain labels.
  reader.targetName();
  while (reader.remaining > 0) {
    final key = reader.u16();
    final length = reader.u16();
    final value = reader.bytes(length);
    params.add(HttpsSvcParam(key: key, value: value));
  }
  return params;
}

/// Extracts the ECH config list bytes (SvcParam key 5) from an HTTPS
/// record's RDATA. Returns null when the parameter is absent.
Uint8List? echConfigFromHttpsRdata(Uint8List rdata) {
  for (final param in parseHttpsSvcParams(rdata)) {
    if (param.key == kSvcParamKeyEch) {
      // An empty `ech` value is syntactically well-formed but cannot drive an
      // ECH ClientHello. Treat it exactly like an absent parameter so callers
      // never mistake a plain-TLS probe for an ECH result.
      return param.value.isEmpty ? null : param.value;
    }
  }
  return null;
}

/// Extracts the ipv4hint addresses (SvcParam key 4) from an HTTPS record's
/// RDATA. Empty when absent or malformed. ipv4hint is the authoritative
/// connect target for ECH: Cloudflare publishes the anycast IPs the ECH
/// front is served on, which is exactly the clean answer we need (system
/// DNS / mainland DoH answers for the target host are polluted).
List<InternetAddress> ipv4HintFromHttpsRdata(Uint8List rdata) {
  for (final param in parseHttpsSvcParams(rdata)) {
    if (param.key == kSvcParamKeyIpv4Hint) {
      final out = <InternetAddress>[];
      for (var i = 0; i + 4 <= param.value.length; i += 4) {
        out.add(
          InternetAddress(
            '${param.value[i]}.${param.value[i + 1]}.'
            '${param.value[i + 2]}.${param.value[i + 3]}',
          ),
        );
      }
      return out;
    }
  }
  return const [];
}

/// Writer for header + question. Names are encoded without compression
/// because a query has a single name and the byte budget is tiny.
class _Writer {
  final BytesBuilder _builder = BytesBuilder(copy: false);

  Uint8List get bytes => _builder.toBytes();

  void u16(int value) {
    _builder.addByte((value >> 8) & 0xff);
    _builder.addByte(value & 0xff);
  }

  /// Encodes a DNS name: labels + root terminator. Tolerates a trailing
  /// dot and rejects empty or over-long labels per RFC 1035 limits.
  void encodedName(String name) {
    final withoutDot = name.endsWith('.')
        ? name.substring(0, name.length - 1)
        : name;
    if (withoutDot.isEmpty) {
      throw ArgumentError.value(name, 'name', 'empty DNS name');
    }
    final labels = withoutDot.split('.');
    int total = 1;
    for (final label in labels) {
      if (label.isEmpty || label.length > 63) {
        throw ArgumentError.value(name, 'name', 'invalid label length');
      }
      total += 1 + label.length;
    }
    if (total > 255) {
      throw ArgumentError.value(name, 'name', 'name exceeds 255 octets');
    }
    for (final label in labels) {
      _builder.addByte(label.length);
      _builder.add(label.codeUnits);
    }
    _builder.addByte(0);
  }
}

class _Reader {
  _Reader(this.raw) : _offset = 0;

  final Uint8List raw;
  int _offset;

  int u16() {
    if (_offset + 2 > raw.length) {
      throw const DnsCodecException('truncated u16');
    }
    final value = ByteData.sublistView(raw, _offset, _offset + 2).getUint16(0);
    _offset += 2;
    return value;
  }

  int u32() {
    if (_offset + 4 > raw.length) {
      throw const DnsCodecException('truncated u32');
    }
    final value = ByteData.sublistView(raw, _offset, _offset + 4).getUint32(0);
    _offset += 4;
    return value;
  }

  Uint8List bytes(int length) {
    if (_offset + length > raw.length) {
      throw const DnsCodecException('truncated data');
    }
    final slice = Uint8List.sublistView(raw, _offset, _offset + length);
    _offset += length;
    return slice;
  }

  int u8() {
    if (_offset + 1 > raw.length) {
      throw const DnsCodecException('truncated u8');
    }
    return raw[_offset++];
  }

  int get remaining => raw.length - _offset;

  /// Reads an uncompressed wire-format domain name. HTTPS target names must
  /// not use compression (RFC 9460 §2.2), so pointers are rejected here to
  /// keep the SvcParam parser simple and deterministic.
  String targetName() {
    final labels = <String>[];
    while (true) {
      final length = u8();
      if (length == 0) break;
      if (length & 0xc0 != 0) {
        throw const DnsCodecException('compressed name in HTTPS target');
      }
      labels.add(String.fromCharCodes(bytes(length)));
    }
    return labels.join('.');
  }

  /// Reads a possibly compressed name (RFC 1035 4.1.4). Pointers are
  /// followed with a bounded loop and the read pointer advances past the
  /// pointer itself.
  String name() {
    final labels = <String>[];
    var offset = _offset;
    var jumped = false;
    var pointerJumps = 0;
    while (true) {
      if (offset >= raw.length) {
        throw const DnsCodecException('name runs past end of message');
      }
      final length = raw[offset];
      if (length == 0) {
        offset += 1;
        break;
      }
      if (length & 0xc0 == 0xc0) {
        if (offset + 1 >= raw.length) {
          throw const DnsCodecException('truncated compression pointer');
        }
        pointerJumps++;
        if (pointerJumps > 32) {
          throw const DnsCodecException('compression pointer loop');
        }
        final pointer = ((length & 0x3f) << 8) | raw[offset + 1];
        if (!jumped) {
          _offset += 2;
          jumped = true;
        }
        offset = pointer;
        continue;
      }
      if (length & 0xc0 != 0) {
        throw const DnsCodecException('unsupported name encoding');
      }
      if (offset + 1 + length > raw.length) {
        throw const DnsCodecException('truncated label');
      }
      labels.add(String.fromCharCodes(raw, offset + 1, offset + 1 + length));
      offset += 1 + length;
    }
    if (!jumped) {
      _offset = offset;
    }
    return labels.isEmpty ? '' : labels.join('.');
  }
}
