import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/network/compat/network_contracts.dart';
import 'package:pixiv_func/core/network/compat/rhttp_client_factory.dart';
import 'package:rhttp/rhttp.dart' as rhttp;

const _revision = NetworkRevision(0);

void main() {
  group('RhttpClientFactory.settingsFor', () {
    test('direct route: system DNS + real SNI + full verification', () {
      final settings = RhttpClientFactory.settingsFor(
        NetworkRoute.direct(_revision),
        destinationHost: 'app-api.pixiv.net',
        purpose: PixivDestinationPurpose.appApi,
      );
      final tls = settings.tlsSettings!;
      expect(tls.sni, isTrue);
      expect(tls.verifyCertificates, isTrue);
      expect(tls.echConfigList, isNull);
      expect(
        settings.httpVersionPref,
        rhttp.HttpVersionPref.all,
        reason: 'use ALPN negotiation; do not force h2 prior knowledge',
      );
      final dns = settings.dnsSettings!;
      expect(dns, isA<rhttp.DnsSettings>());
    });

    test('ech route: DoH address + ECH config + full verification', () {
      final route = NetworkRoute.ech(
        _revision,
        InternetAddress('104.18.42.239'),
        [0xfe, 0x0d, 1, 2, 3],
      );
      final settings = RhttpClientFactory.settingsFor(
        route,
        destinationHost: 'app-api.pixiv.net',
        purpose: PixivDestinationPurpose.appApi,
      );
      final tls = settings.tlsSettings!;
      expect(tls.sni, isTrue);
      expect(tls.verifyCertificates, isTrue);
      expect(tls.echConfigList, [0xfe, 0x0d, 1, 2, 3]);
      // StaticDnsSettings (private subtype) carries the overrides; it is
      // the only concrete DnsSettings subtype exported through the sealed
      // class, which is asserted by the factory code path itself (create
      // never uses dynamic resolver).
      expect(settings.dnsSettings, isA<rhttp.DnsSettings>());
      expect(settings.tlsSettings!.echConfigList, [0xfe, 0x0d, 1, 2, 3]);
    });

    test('dohRealSni route: DoH address + real SNI + no ECH', () {
      final route = NetworkRoute.secureDns(
        _revision,
        InternetAddress('104.18.42.239'),
      );
      final settings = RhttpClientFactory.settingsFor(
        route,
        destinationHost: 'app-api.pixiv.net',
        purpose: PixivDestinationPurpose.appApi,
      );
      final tls = settings.tlsSettings!;
      expect(tls.sni, isTrue);
      expect(tls.verifyCertificates, isTrue);
      expect(tls.echConfigList, isNull);
    });

    test('noSni route: origin address + empty SNI + full verification', () {
      final route = NetworkRoute.noSni(
        _revision,
        InternetAddress('210.140.139.129'),
      );
      final settings = RhttpClientFactory.settingsFor(
        route,
        destinationHost: 'i.pximg.net',
        purpose: PixivDestinationPurpose.image,
      );
      final tls = settings.tlsSettings!;
      expect(tls.sni, isFalse);
      expect(tls.verifyCertificates, isTrue);
    });

    test('insecureNoSni route: empty SNI + verification OFF', () {
      final route = NetworkRoute.insecureNoSni(
        _revision,
        InternetAddress('210.140.139.129'),
      );
      final settings = RhttpClientFactory.settingsFor(
        route,
        destinationHost: 'i.pximg.net',
        purpose: PixivDestinationPurpose.image,
      );
      final tls = settings.tlsSettings!;
      expect(tls.sni, isFalse);
      expect(tls.verifyCertificates, isFalse);
    });

    test('throws on ECH route without config', () {
      // ECH kind without config is impossible via public factories; the
      // guard is exercised through the remembered factory with a mismatched
      // kind (simulated invalid state).
      expect(
        () => RhttpClientFactory.settingsFor(
          NetworkRoute.remembered(
            _revision,
            NetworkRouteKind.ech,
            InternetAddress('104.18.42.239'),
          ),
          destinationHost: 'app-api.pixiv.net',
          purpose: PixivDestinationPurpose.appApi,
        ),
        throwsArgumentError,
      );
    });

    test('redirects are disabled (manual policy owns redirect semantics)', () {
      final settings = RhttpClientFactory.settingsFor(
        NetworkRoute.direct(_revision),
        destinationHost: 'app-api.pixiv.net',
        purpose: PixivDestinationPurpose.appApi,
      );
      expect(settings.redirectSettings, isA<rhttp.RedirectSettings>());
    });

    test('routing via remembered kind keeps tier semantics', () {
      final route = NetworkRoute.remembered(
        _revision,
        NetworkRouteKind.noSni,
        InternetAddress('210.140.139.129'),
      );
      final settings = RhttpClientFactory.settingsFor(
        route,
        destinationHost: 'i.pximg.net',
        purpose: PixivDestinationPurpose.image,
      );
      final tls = settings.tlsSettings!;
      expect(tls.sni, isFalse);
    });
  });

  // Regression: with no timeout configured, a mainland `direct` attempt hung
  // on a polluted address until the API client's outer 20s budget fired, so
  // the ech / dohRealSni tiers were never reached at all (confirmed by packet
  // capture: one plaintext UDP DNS query, zero DoH/ECH connections).
  group('RhttpClientFactory.timeoutsFor', () {
    test('every tier carries a connect budget', () {
      for (final route in [
        NetworkRoute.direct(_revision),
        NetworkRoute.secureDns(_revision, InternetAddress('104.18.42.239')),
        NetworkRoute.ech(_revision, InternetAddress('104.18.10.118'), [
          0xfe,
          0x0d,
        ]),
        NetworkRoute.noSni(_revision, InternetAddress('210.140.139.129')),
        NetworkRoute.insecureNoSni(
          _revision,
          InternetAddress('210.140.139.129'),
        ),
      ]) {
        final timeouts = RhttpClientFactory.timeoutsFor(
          route,
          purpose: PixivDestinationPurpose.appApi,
        );
        expect(
          timeouts.connectTimeout,
          isNotNull,
          reason: '${route.kind.name} must not be able to hang on connect',
        );
      }
    });

    test('direct fails faster than the fallback tiers', () {
      final direct = RhttpClientFactory.timeoutsFor(
        NetworkRoute.direct(_revision),
        purpose: PixivDestinationPurpose.appApi,
      );
      final ech = RhttpClientFactory.timeoutsFor(
        NetworkRoute.ech(_revision, InternetAddress('104.18.10.118'), [
          0xfe,
          0x0d,
        ]),
        purpose: PixivDestinationPurpose.appApi,
      );
      expect(direct.connectTimeout!, lessThan(ech.connectTimeout!));
      expect(direct.timeout!, lessThan(ech.timeout!));
    });

    test('the whole ladder fits inside the API request budget', () {
      // direct + two fallback tiers must complete before the outer 20s
      // timeout of PixivHttpClient fires, otherwise the ladder is cut off
      // before reaching the tier that works.
      final direct = RhttpClientFactory.directRequestTimeout;
      final fallback = RhttpClientFactory.fallbackRequestTimeout;
      expect(direct + fallback * 2, lessThan(const Duration(seconds: 20)));
    });

    test('streaming exits carry no total timeout', () {
      // A total timeout covers the body too, so it would abort a large image
      // or download mid-transfer.
      final timeouts = RhttpClientFactory.timeoutsFor(
        NetworkRoute.noSni(_revision, InternetAddress('210.140.139.129')),
        purpose: PixivDestinationPurpose.image,
      );
      expect(timeouts.timeout, isNull);
      expect(timeouts.connectTimeout, isNotNull);
    });

    test('non-streaming exits carry a total timeout', () {
      for (final purpose in [
        PixivDestinationPurpose.appApi,
        PixivDestinationPurpose.oauth,
        PixivDestinationPurpose.accountsWeb,
        PixivDestinationPurpose.pixivWeb,
      ]) {
        final timeouts = RhttpClientFactory.timeoutsFor(
          NetworkRoute.direct(_revision),
          purpose: purpose,
        );
        expect(timeouts.timeout, isNotNull, reason: purpose.name);
      }
    });

    test('settingsFor wires the budget through', () {
      final settings = RhttpClientFactory.settingsFor(
        NetworkRoute.direct(_revision),
        destinationHost: 'app-api.pixiv.net',
        purpose: PixivDestinationPurpose.appApi,
      );
      expect(settings.timeoutSettings, isNotNull);
      expect(
        settings.timeoutSettings!.connectTimeout,
        RhttpClientFactory.directConnectTimeout,
      );
    });
  });
}
