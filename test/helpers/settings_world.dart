import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:parfait/core/network/compat/network_contracts.dart'
    show
        DnsSource,
        NetworkCancelSignal,
        NetworkRevision,
        PixivDestinationRegistry;
import 'package:parfait/core/network/compat/network_policy.dart';
import 'package:parfait/core/network/compat/secure_resolver.dart';
import 'package:parfait/core/settings/app_settings.dart';
import 'package:parfait/core/translation/translation_credentials.dart';

export 'fake_settings.dart';

/// In-memory credential store — the root-page summary only exercises the
/// `hasX()` existence probes, but the full surface is implemented so the
/// fake stays usable if more assertions appear.
class FakeTranslationStore implements TranslationCredentialStore {
  BaiduTranslationCredentials? baidu;
  LlmTranslationCredentials? llm;
  DoubaoWebSession? doubao;

  @override
  Future<BaiduTranslationCredentials?> readBaidu() async => baidu;

  @override
  Future<void> writeBaidu(BaiduTranslationCredentials credentials) async {
    baidu = credentials;
  }

  @override
  Future<LlmTranslationCredentials?> readLlm() async => llm;

  @override
  Future<void> writeLlm(LlmTranslationCredentials credentials) async {
    llm = credentials;
  }

  @override
  Future<DoubaoWebSession?> readDoubao() async => doubao;

  @override
  Future<void> writeDoubao(DoubaoWebSession session) async {
    doubao = session;
  }

  @override
  Future<bool> hasBaidu() async => baidu != null;

  @override
  Future<bool> hasLlm() async => llm != null;

  @override
  Future<bool> hasDoubao() async => doubao != null;

  @override
  Future<void> deleteBaidu() async => baidu = null;

  @override
  Future<void> deleteLlm() async => llm = null;

  @override
  Future<void> deleteDoubao() async => doubao = null;

  @override
  Future<void> deleteAll() async {
    baidu = null;
    llm = null;
    doubao = null;
  }
}

/// Settings past onboarding with a fixed language, theme and image source.
AppSettings baseTestSettings({String languageTag = 'en-US'}) => AppSettings(
  guideCompleted: true,
  languageTag: languageTag,
  themeCode: AppSettings.lightTheme,
  imageSource: AppSettings.normalImageSource,
);

/// Resolves every host to [addresses] from the system DNS.
class StubResolver implements SecureResolver {
  StubResolver(this.addresses);

  final List<InternetAddress> addresses;

  @override
  Future<ResolvedHost> resolve(
    String host, {
    required NetworkRevision revision,
    NetworkCancelSignal? cancelSignal,
  }) async => ResolvedHost(
    host: host,
    addresses: addresses,
    dnsSource: DnsSource.system,
    revision: revision,
    ttl: const Duration(seconds: 30),
  );

  @override
  Future<void> dispose() async {}
}

/// Records requests and answers `{}` (or throws [failure]).
class RecordingClient extends http.BaseClient {
  final requests = <http.BaseRequest>[];
  Object? failure;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    final failure = this.failure;
    if (failure != null) throw failure;
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode('{}')),
      200,
      request: request,
    );
  }
}

/// A network policy whose every route resolves and answers locally: for
/// pages that read network state without exercising it.
NetworkAccessPolicy stubNetworkPolicy() => NetworkAccessPolicy(
  registry: PixivDestinationRegistry(),
  resolver: StubResolver([InternetAddress('93.184.216.34')]),
  clientFactory: (route, canonicalHost, _) => RecordingClient(),
);
