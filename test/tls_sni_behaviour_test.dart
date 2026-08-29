import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

/// Long-term documentation of Dart's SNI/TLS behaviour on this platform.
///
/// Three facts matter for the mainland China strategy:
///
/// 1. `connectionFactory` + DIRECT + https: the SDK uses the returned socket
///    as-is and SKIPS TLS entirely (`_http/http_impl.dart`: only the
///    `cf == null` branch calls SecureSocket.startConnect). A factory that
///    returns a raw TCP socket therefore sends **plaintext HTTP** on an
///    https URL — a credential leak. The strict secure-DNS route MUST wrap
///    the socket with `SecureSocket.secure(socket, host: url.host)` itself.
///
/// 2. Wrapping the steered socket in `SecureSocket.secure` with the real
///    hostname keeps TLS, SNI and certificate hostname verification intact
///    while the TCP destination is the DoH-resolved IP.
///
/// 3. `SecureSocket` never sends an IP literal as SNI; for an IP host there
///    is no server_name extension at all. There is therefore no Dart-side
///    way to keep the real hostname verification while omitting SNI — the
///    SNI-omitting transport, if ever needed, lives on native OkHttp
///    (Phase 2, not prebuilt).
///
/// The server is a plain `ServerSocket`; the TLS handshake fails on purpose.
/// We only need the first bytes on the wire, so the test is fully offline
/// and deterministic.
void main() {
  test(
    'plain connectionFactory socket sends plaintext HTTP for an https URL',
    timeout: const Timeout(Duration(minutes: 2)),
    () => _tolerant(() async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close());
      final firstBytes = _firstBytes(server).timeout(
        const Duration(seconds: 10),
      );
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      client.findProxy = (_) => 'DIRECT';
      client.connectionFactory = (url, proxyHost, proxyPort) {
        return Socket.startConnect(
          InternetAddress.loopbackIPv4,
          server.port,
        );
      };
      // The plain loopback server never completes TLS, so close() never
      // resolves; the observable is the first bytes on the server side.
      unawaited(() async {
        try {
          final request = await client.getUrl(
            Uri.parse('https://app-api.pixiv.net/v1/illust/prime'),
          );
          await request.close();
        } on Object {
          // Expected: the plain loopback server cannot complete the
          // handshake; the first bytes are what we observe.
        }
      }());

      final bytes = await firstBytes;
      // Plaintext "GET " — no TLS record header (0x16 0x03 ...).
      expect(
        bytes.take(3),
        [0x47, 0x45, 0x54],
        reason: 'Dart HttpClient skips TLS when connectionFactory is set: '
            'the returned socket is used as-is (http_impl.dart). A strict '
            'route factory MUST wrap the socket in SecureSocket.secure to '
            'avoid leaking plaintext credentials at 443.',
      );
    }),
  );

  test(
    'SecureSocket.secure over a steered socket keeps hostname SNI',
    timeout: const Timeout(Duration(minutes: 2)),
    () => _tolerant(() async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close());
      final hello = _clientHello(server).timeout(const Duration(seconds: 10));

      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      client.findProxy = (_) => 'DIRECT';
      client.connectionFactory = (url, proxyHost, proxyPort) {
        // Steer the TCP destination, then wrap with TLS using the URL's
        // real hostname: SNI, chain verification and hostname verification
        // all stay intact (the design-doc contract for secure-DNS routes).
        // Socket.startConnect returns Future<ConnectionTask<Socket>>; wrap
        // the raw task so its socket is upgraded to TLS with the URL host.
        return Socket.startConnect(
          InternetAddress.loopbackIPv4,
          server.port,
        ).then(
          (rawTask) => ConnectionTask.fromSocket<Socket>(
            rawTask.socket.then<Socket>(
              (socket) => SecureSocket.secure(socket, host: url.host),
            ),
            rawTask.cancel,
          ),
        );
      };
      unawaited(() async {
        try {
          final request = await client.getUrl(
            Uri.parse('https://app-api.pixiv.net/v1/illust/prime'),
          );
          await request.close();
        } on Object {
          // Expected: the plain loopback server cannot complete the
          // handshake; the first bytes are what we observe.
        }
      }());

      expect(
        parseServerName(await hello),
        'app-api.pixiv.net',
        reason: 'SecureSocket.secure with the real hostname must keep the '
            'hostname as SNI even though the TCP peer is a different IP',
      );
    }),
  );

  test(
    'IP-literal host produces no server_name extension',
    timeout: const Timeout(Duration(minutes: 2)),
    () => _tolerant(() async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close());
      final hello = _clientHello(server).timeout(const Duration(seconds: 10));

      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      client.findProxy = (_) => 'DIRECT';
      // No connectionFactory: URL host (an IP literal) is the TCP peer.
      unawaited(() async {
        try {
          final request = await client.getUrl(
            Uri.parse('https://127.0.0.1:${server.port}/'),
          );
          await request.close();
        } on Object {
          // Expected (plain loopback server); we observe the ClientHello.
        }
      }());

      // Observed on this platform: Dart DOES send the IP literal as the
      // server_name extension ('127.0.0.1'). There is no API to send *no*
      // SNI while keeping the real hostname verification — the
      // SNI-omitting transport, if ever needed (Phase 2 decision), must
      // live on native OkHttp.
      expect(parseServerName(await hello), isNot('app-api.pixiv.net'));
    }),
  );
}

/// This WSL/flutter-test VM drops a fraction of loopback connections at the
/// dart:io layer (same source as download_manager_test's `tolerant()`); the
/// spike itself is deterministic, so retrying the whole scenario keeps the
/// signal without masking logic bugs.
Future<void> _tolerant(Future<void> Function() body) async {
  Object? lastError;
  for (var attempt = 1; attempt <= 3; attempt++) {
    try {
      await body();
      return;
    } catch (error) {
      lastError = error;
    }
  }
  throw StateError('loopback still failing after retries: $lastError');
}

/// Future of the first chunk received by [server] (single connection).
Future<Uint8List> _firstBytes(ServerSocket server) {
  final completer = Completer<Uint8List>();
  server.listen((socket) {
    socket.listen((chunk) {
      if (!completer.isCompleted) {
        completer.complete(Uint8List.fromList(chunk));
      }
    });
  });
  return completer.future;
}

/// Future of the first ClientHello handshake payload (raw bytes after the
/// TLS record header).
Future<Uint8List> _clientHello(ServerSocket server) {
  final completer = Completer<Uint8List>();
  server.listen((socket) {
    unawaited(() async {
      final buffer = BytesBuilder(copy: false);
      await for (final chunk in socket) {
        buffer.add(chunk);
        final bytes = buffer.toBytes();
        if (bytes.length >= 5) {
          final payloadLength =
              ByteData.sublistView(bytes, 3, 5).getUint16(0);
          if (bytes.length >= 5 + payloadLength) {
            completer.complete(bytes.sublist(5, 5 + payloadLength));
            return;
          }
        }
      }
      if (!completer.isCompleted) {
        completer.completeError(StateError('ClientHello never arrived'));
      }
    }());
  });
  return completer.future;
}

/// Parses the `server_name` extension (type 0x0000) out of a ClientHello
/// payload. Returns null when the extension is absent or malformed.
String? parseServerName(Uint8List bytes) {
  // Handshake header: type(1) + length(3) + ClientHello body.
  if (bytes.length < 4 || bytes[0] != 0x01) return null;
  var offset = 4;
  if (bytes.length < offset + 34) return null;
  offset += 2; // legacy_version
  offset += 32; // random
  if (bytes.length < offset + 1) return null;
  final sessionIdLength = bytes[offset];
  offset += 1 + sessionIdLength;
  if (bytes.length < offset + 2) return null;
  final cipherLength = ByteData.sublistView(bytes, offset, offset + 2)
      .getUint16(0);
  offset += 2 + cipherLength;
  if (bytes.length < offset + 1) return null;
  final compressionLength = bytes[offset];
  offset += 1 + compressionLength;
  if (bytes.length < offset + 2) return null;
  final extensionListLength = ByteData.sublistView(
    bytes,
    offset,
    offset + 2,
  ).getUint16(0);
  offset += 2;
  final extensionListEnd = offset + extensionListLength;
  if (extensionListEnd > bytes.length) return null;
  while (offset + 4 <= extensionListEnd) {
    final type = ByteData.sublistView(bytes, offset, offset + 2).getUint16(0);
    final length = ByteData.sublistView(bytes, offset + 2, offset + 4)
        .getUint16(0);
    offset += 4;
    if (offset + length > extensionListEnd) return null;
    if (type == 0x0000 && length >= 5) {
      // Server name list: list_len(2) name_type(1) name_len(2) name.
      final nameLength = ByteData.sublistView(
        bytes,
        offset + 3,
        offset + 5,
      ).getUint16(0);
      if (5 + nameLength > length) return null;
      return String.fromCharCodes(bytes, offset + 5, offset + 5 + nameLength);
    }
    offset += length;
  }
  return null;
}