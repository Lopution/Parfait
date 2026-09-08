import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

/// One shared client for third-party HTTP traffic: comment translation,
/// SauceNAO reverse-image search and update APK downloads.
///
/// A single instance keeps connection pools warm and gives tests exactly one
/// override point. Production code never constructs an `http.Client()`
/// inline (C5e); the provider owns the lifecycle.
final thirdPartyHttpClientProvider = Provider<http.Client>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return client;
});

/// dart:io client for resolver/probe-grade traffic (update manifest fetch,
/// DoH lookups and layered connectivity probes).
///
/// `dart:io` is required where `connectionFactory` steering matters; plain
/// third-party calls must use [thirdPartyHttpClientProvider] instead.
final resolverHttpClientProvider = Provider<HttpClient>((ref) {
  final client = HttpClient();
  ref.onDispose(client.close);
  return client;
});
