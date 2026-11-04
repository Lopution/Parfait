import 'dart:async';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:http/http.dart' as http;

import '../pixiv_headers.dart';
import 'image_route_scores.dart';
import 'network_fast_route_store.dart';
import 'network_policy.dart';
import 'proven_origins.dart';

/// Keeps pixiv's origin candidate current without a release: at most once
/// [every], it asks encrypted DNS for `i.pximg.net`, and each address it
/// names beyond the built-in ten and those already proven gets one image
/// GET over the empty-SNI route, certificates verified. Those that answer
/// join the origin book of both image hosts (after the address served
/// last, before the built-in ten); a proven address DNS no longer names
/// leaves it. A proven address that fails three loads in a row is
/// skipped for a day, or until the network changes; the built-in ten never
/// are.
///
/// It runs in the image worker, on an image sample, only while no visible
/// image waits for a lane ([idle]). A DNS lookup that fails counts as the
/// day's ask: mainland networks often block DoH.
class OriginRefresh {
  OriginRefresh(
    this._policy, {
    required bool Function() idle,
    required Uri Function() image,
  }) : _idle = idle,
       _image = image;

  static const every = Duration(days: 1);
  static const maxAddresses = 10;
  static const probeLimit = Duration(seconds: 10);

  final NetworkAccessPolicy _policy;
  final bool Function() _idle;
  final Uri Function() _image;

  DateTime? _nextAsk;
  var _running = false;
  var _closed = false;

  /// The refresh in progress, for tests.
  Future<void> _work = Future.value();
  Future<void> get settled => _work;

  /// Called for each image sample the policy records.
  void noteSample(String networkIdentity, ImageRouteSample sample) {
    final next = _nextAsk;
    if (_closed ||
        _running ||
        !_policy.bootstrapNoSniEnabled ||
        (next != null && clock.now().isBefore(next)) ||
        !_idle()) {
      return;
    }
    _running = true;
    _work = _refresh().whenComplete(() => _running = false);
  }

  void close() => _closed = true;

  Future<void> _refresh() async {
    final known = await _policy.provenOrigins();
    final now = clock.now();
    if (known != null && now.difference(known.refreshedAt) < every) {
      _nextAsk = known.refreshedAt.add(every);
      return;
    }
    _nextAsk = now.add(every);
    final List<InternetAddress>? named;
    try {
      named = await _policy.resolveImageOrigins();
    } on Object {
      if (!_closed) {
        _policy.rememberProvenOrigins(
          ProvenOrigins(known?.addresses ?? const [], refreshedAt: now),
        );
      }
      return;
    }
    if (_closed || named == null) return;
    final builtIn = {
      for (final address in PixivFastRouteStore.originAddresses)
        address.address,
    };
    final namedSet = {for (final address in named) address.address};
    final kept = [
      for (final address in known?.addresses ?? const <InternetAddress>[])
        if (namedSet.contains(address.address)) address,
    ];
    final keptSet = {for (final address in kept) address.address};
    for (final address in named) {
      if (_closed || kept.length >= maxAddresses) break;
      if (builtIn.contains(address.address) ||
          keptSet.contains(address.address)) {
        continue;
      }
      if (await _proves(address)) {
        kept.add(address);
        keptSet.add(address.address);
      }
    }
    if (_closed) return;
    _policy.rememberProvenOrigins(ProvenOrigins(kept, refreshedAt: now));
  }

  /// Whether one image GET through [address] answers 200 with a body.
  Future<bool> _proves(InternetAddress address) async {
    final abort = Completer<void>();
    final limit = Timer(probeLimit, abort.complete);
    try {
      return await _policy.throughImageOrigin(address, (client) async {
        final request = http.AbortableRequest(
          'GET',
          _image(),
          abortTrigger: abort.future,
        )..headers.addAll(PixivHeaders.image());
        final response = await client.send(request);
        var bytes = 0;
        await for (final chunk in response.stream) {
          bytes += chunk.length;
        }
        return response.statusCode == 200 && bytes > 0;
      });
    } on Object {
      return false;
    } finally {
      limit.cancel();
    }
  }
}
