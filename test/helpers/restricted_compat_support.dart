import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:parfait/core/network/compat/network_contracts.dart';
import 'package:parfait/core/network/compat/secure_resolver.dart';

// Shared by the restricted_compat_network tests.
class FakeClient extends http.BaseClient {
  FakeClient({this.failure, this.statusCode = 200, this.body = '{}'});

  final Object? failure;
  final int statusCode;
  final String body;
  final requests = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    final failure = this.failure;
    if (failure != null) throw failure;
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(body)),
      statusCode,
      request: request,
    );
  }
}

/// Answers every lookup with [addresses] from [source]; no addresses is a
/// failed lookup.
class FakeResolver implements SecureResolver {
  FakeResolver(this.addresses, {this.answered, this.source = DnsSource.system});

  final List<InternetAddress> addresses;
  final DnsSource source;
  var calls = 0;

  /// Each lookup answers once this completes; a DoH endpoint that cannot
  /// connect never does.
  final Future<void>? answered;

  @override
  Future<ResolvedHost> resolve(
    String host, {
    required NetworkRevision revision,
    NetworkCancelSignal? cancelSignal,
  }) async {
    calls++;
    await answered;
    if (addresses.isEmpty) {
      throw const SecureResolutionException('fake lookup failed');
    }
    return ResolvedHost(
      host: host,
      addresses: addresses,
      dnsSource: source,
      revision: revision,
      ttl: const Duration(seconds: 30),
    );
  }

  @override
  Future<void> dispose() async {}
}

class FakeEchResolver extends FakeResolver implements EchConfigResolver {
  FakeEchResolver(
    super.addresses, {
    this.frontAddresses = const [],
    this.ttl = const Duration(seconds: 30),
  });

  final List<InternetAddress> frontAddresses;
  final Duration ttl;
  var echCalls = 0;

  @override
  Future<EchConfigResult> lookupEchConfig(
    String frontHost, {
    required NetworkRevision revision,
    NetworkCancelSignal? cancelSignal,
  }) async {
    echCalls++;
    return EchConfigResult(
      echConfig: Uint8List.fromList(const [1, 2, 3, 4]),
      ttl: ttl,
      frontAddresses: frontAddresses,
    );
  }
}

class GateFailureClient extends http.BaseClient {
  final gate = Completer<void>();
  final requests = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    await gate.future;
    throw SocketException('Connection refused');
  }
}

/// send() never resolves — simulates a socket that stalls before headers.
class NeverSendClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      Completer<http.StreamedResponse>().future;
}

/// Emits [bytes] of body then stalls forever — a mid-body connection stall.
class StallClient extends http.BaseClient {
  StallClient([this.bytes = 1, this.error]);

  final int bytes;

  /// Sent after the bytes, without ending the body.
  final Object? error;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      Stream<List<int>>.multi((controller) {
        controller.add(List.filled(bytes, 1));
        if (error case final error?) controller.addError(error);
      }),
      200,
      request: request,
    );
  }
}

/// A body shaped like rhttp's: flutter_rust_bridge's `async*` generator over
/// the Rust [port], where an error message throws. Cancelled while it
/// waits, the generator goes on waiting; an error that comes next fails the
/// cancel future instead of reaching any handler.
class RustBodyClient extends http.BaseClient {
  final port = StreamController<Object>();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(_body(), 200, request: request);

  Stream<List<int>> _body() async* {
    await for (final message in port.stream) {
      if (message is String) throw http.ClientException(message);
      yield message as List<int>;
    }
  }
}

class ScriptedClient extends http.BaseClient {
  ScriptedClient(this.outcomes);

  final List<Object?> outcomes;
  final requests = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    if (outcomes.isEmpty) {
      return http.StreamedResponse(
        Stream<List<int>>.value(utf8.encode('{}')),
        200,
        request: request,
      );
    }
    final outcome = outcomes.removeAt(0);
    if (outcome is Object && outcome is! http.StreamedResponse) {
      throw outcome;
    }
    return outcome as http.StreamedResponse? ??
        http.StreamedResponse(
          Stream<List<int>>.value(utf8.encode('{}')),
          200,
          request: request,
        );
  }
}

/// Answers 200 unless its route kind is in [down]; logs every send's kind.
class KindClient extends http.BaseClient {
  KindClient(this.kind, this.log, this.down);

  final NetworkRouteKind kind;
  final List<NetworkRouteKind> log;
  final Set<NetworkRouteKind> down;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    log.add(kind);
    if (down.contains(kind)) {
      throw const SocketException('Connection refused');
    }
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode('ok')),
      200,
      request: request,
    );
  }
}

/// Delays the inner send so race tests can pick the winner deterministically.
class DelayedClient extends http.BaseClient {
  DelayedClient(this.inner, this.delay);

  final http.Client inner;
  final Duration delay;

  /// Records on arrival — the delay simulates a slow tier, and a test
  /// asserting "the loser was also sent" must not depend on it finishing.
  final requests = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    await Future<void>.delayed(delay);
    return inner.send(request);
  }
}

final apiUri = Uri.parse(
  'https://app-api.pixiv.net/v1/illust/recommended?offset=0',
);
