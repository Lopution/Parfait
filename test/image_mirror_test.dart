import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/settings/app_settings.dart';

void main() {
  group('ImageMirror.of', () {
    test('normal source is direct', () {
      final mirror = ImageMirror.of(AppSettings.normalImageSource);
      expect(mirror.extraHosts, isEmpty);
      final url = Uri.parse('https://i.pximg.net/img-original/img/1_p0.jpg');
      expect(identical(mirror.rewrite(url), url), isTrue);
    });

    test('preset maps both i. and s. subdomains', () {
      final mirror = ImageMirror.of('i.pixiv.cat');
      expect(mirror.extraHosts, {'i.pixiv.cat', 's.pixiv.cat'});
      expect(
        mirror.rewriteUrl('https://i.pximg.net/img-original/img/1_p0.jpg'),
        'https://i.pixiv.cat/img-original/img/1_p0.jpg',
      );
      expect(
        mirror.rewriteUrl('https://s.pximg.net/common/avatar.png?x=1'),
        'https://s.pixiv.cat/common/avatar.png?x=1',
      );
    });

    test('custom prefix replaces origin and preserves path tail', () {
      final mirror = ImageMirror.of('https://proxy.example.com');
      expect(
        mirror.rewriteUrl('https://i.pximg.net/c/540x540_70/img/1.jpg'),
        'https://proxy.example.com/c/540x540_70/img/1.jpg',
      );
    });

    test('custom prefix with path joins prefix and original path', () {
      final mirror = ImageMirror.of('https://proxy.example.com/pixiv');
      expect(
        mirror.rewriteUrl('https://i.pximg.net/img/a.jpg?q=1'),
        'https://proxy.example.com/pixiv/img/a.jpg?q=1',
      );
    });

    test('non-pximg hosts pass through untouched', () {
      final mirror = ImageMirror.of('i.pixiv.re');
      const other = 'https://embed.pixiv.net/spotlight.php?id=1';
      expect(mirror.rewriteUrl(other), other);
      const custom = 'https://proxy.example.com/p';
      expect(
        ImageMirror.of(custom).rewriteUrl('https://other.cdn/x.jpg'),
        'https://other.cdn/x.jpg',
      );
    });

    test('unparseable sources degrade to direct', () {
      final url = Uri.parse('https://i.pximg.net/a.jpg');
      for (final bad in ['', 'not a url', 'http://insecure.com']) {
        final mirror = ImageMirror.of(bad);
        expect(identical(mirror.rewrite(url), url), isTrue, reason: bad);
        expect(mirror.extraHosts, isEmpty, reason: bad);
      }
    });
  });

  group('auto source', () {
    final url = Uri.parse('https://i.pximg.net/img/a.jpg');

    test("'auto' never normalizes into a bogus https://auto prefix", () {
      final mirror = ImageMirror.of('auto');
      expect(identical(mirror.rewrite(url), url), isTrue);
      // The allowlist admits every race candidate so probes stay routable.
      expect(
        mirror.extraHosts,
        containsAll(<String>[
          'i.pximg.net',
          'i.pixiv.re',
          'i.pixiv.nl',
          'i.pixiv.cat',
        ]),
      );
    });

    test('a resolved winner rewrites through its preset pair', () {
      final mirror = ImageMirror.auto('i.pixiv.re');
      expect(
        mirror.rewriteUrl('https://i.pximg.net/img/a.jpg'),
        'https://i.pixiv.re/img/a.jpg',
      );
      expect(
        mirror.rewriteUrl('https://s.pximg.net/common/x.png'),
        'https://s.pixiv.re/common/x.png',
      );
    });

    test('a pximg winner is direct passthrough', () {
      final mirror = ImageMirror.auto('i.pximg.net');
      expect(identical(mirror.rewrite(url), url), isTrue);
    });

    test('an unknown winner host degrades to passthrough', () {
      final mirror = ImageMirror.auto('bogus.example.com');
      expect(identical(mirror.rewrite(url), url), isTrue);
      expect(mirror.extraHosts, isNotEmpty);
    });

    test("'auto' is a valid persisted source", () {
      expect(ImageMirror.isValidSource('auto'), isTrue);
    });
  });

  group('normalizeCustomSource', () {
    test('bare host upgrades to https', () {
      expect(
        ImageMirror.normalizeCustomSource('proxy.example.com'),
        'https://proxy.example.com',
      );
      expect(
        ImageMirror.normalizeCustomSource('Proxy.Example.COM/pixiv/'),
        'https://proxy.example.com/pixiv',
      );
    });

    test('rejects unsafe or ambiguous input', () {
      for (final bad in [
        '',
        '   ',
        'has space.com',
        'http://insecure.com',
        'https://user@host.com',
        'https://host.com/?q=1',
        'https://host.com/#frag',
        'https://host..com/',
        // The destination registry only trusts DNS names on 443 — IP
        // literals and non-443 ports must be rejected at validation time
        // rather than failing every image request at the allowlist.
        'https://192.168.1.5/pximg',
        'https://proxy.example.com:8443/',
      ]) {
        expect(ImageMirror.normalizeCustomSource(bad), isNull, reason: bad);
      }
    });

    test('canonical form is idempotent and keeps path', () {
      const canonical = 'https://proxy.example.com/pximg';
      expect(ImageMirror.normalizeCustomSource(canonical), canonical);
    });
  });

  group('isValidSource (persisted contract)', () {
    test('presets and canonical custom prefixes are valid', () {
      expect(ImageMirror.isValidSource('i.pximg.net'), isTrue);
      expect(ImageMirror.isValidSource('i.pixiv.cat'), isTrue);
      expect(ImageMirror.isValidSource('i.pixiv.re'), isTrue);
      expect(ImageMirror.isValidSource('i.pixiv.nl'), isTrue);
      expect(ImageMirror.isValidSource('https://proxy.example.com/px'), isTrue);
    });

    test('non-canonical values are rejected for persistence', () {
      // A bare host is a valid UI input but must be normalized before it
      // reaches AppSettings — mirrors the original "approved host only"
      // contract (unapproved bare host falls back to normal).
      expect(
        ImageMirror.isValidSource('unapproved-image-host.example'),
        isFalse,
      );
      expect(ImageMirror.isValidSource('http://proxy.com'), isFalse);
    });
  });

  group('AppSettings mirror persistence', () {
    const base = AppSettings(
      guideCompleted: true,
      languageTag: 'en-US',
      themeCode: AppSettings.lightTheme,
    );

    test('custom prefix survives fromJson and derives custom mode', () {
      final settings = AppSettings.fromJson(const {
        'imageSource': 'https://proxy.example.com/px',
      }, fallback: base);
      expect(settings.imageSource, 'https://proxy.example.com/px');
      expect(settings.imageSourceMode, ImageSourceMode.custom);
      // The prefix also lands in customImageSource so the UI can re-show it.
      expect(settings.customImageSource, 'https://proxy.example.com/px');
    });

    test('customImageSource round-trips and outlives a preset switch', () {
      final custom = base.copyWith(imageSource: 'https://p.example.com');
      expect(custom.customImageSource, 'https://p.example.com');
      final back = custom.copyWith(imageSource: 'i.pixiv.cat');
      expect(back.imageSourceMode, ImageSourceMode.pixivCat);
      expect(back.customImageSource, 'https://p.example.com');
      final json = AppSettings.fromJson(back.toJson(), fallback: base);
      expect(json.imageSource, 'i.pixiv.cat');
      expect(json.customImageSource, 'https://p.example.com');
    });

    test('unapproved bare host still falls back', () {
      final settings = AppSettings.fromJson(const {
        'imageSource': 'unapproved-image-host.example',
      }, fallback: base);
      expect(settings.imageSource, AppSettings.normalImageSource);
      expect(settings.imageSourceMode, ImageSourceMode.normal);
    });
  });
}
