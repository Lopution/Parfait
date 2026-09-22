/// Image-source mirror selection → pximg URL rewrite.
///
/// Semantics follow Shaft `ImageHostManager` (issue #865): presets mirror
/// both the `i.` and `s.` pximg subdomains; a custom source is a full URL
/// prefix (`https://host[/path]`) that replaces the pximg origin wholesale
/// while preserving the original path tail and query.
///
/// The resolver is pure data: [of] parses the persisted `imageSource`
/// string and [rewrite] maps one URL. Wiring (registry allowlist, image
/// client) lives in the network layer.
library;

import 'dart:io' show InternetAddress;

/// Image source exposed by settings. [custom] carries no fixed host — the
/// actual prefix is the persisted `imageSource` string itself (normalized
/// to `https://host[/path]` by [ImageMirror.normalizeCustomSource]).
enum ImageSourceMode {
  normal('i.pximg.net'),
  pixivCat('i.pixiv.cat'),
  pixivRe('i.pixiv.re'),
  pixivNl('i.pixiv.nl'),
  auto('auto'),
  custom('');

  const ImageSourceMode(this.host);

  /// Persisted preset key. Empty for [custom] — it never matches in
  /// [fromHost], so a custom `imageSource` maps to [custom] via the
  /// `imageSourceMode` getter's null branch.
  final String host;

  static ImageSourceMode? fromHost(String? host) {
    for (final mode in values) {
      if (mode.host.isNotEmpty && mode.host == host) return mode;
    }
    return null;
  }
}

class ImageMirror {
  const ImageMirror._(this._presetPair, this._customPrefix, [this._extraHosts]);

  const ImageMirror._preset(String i, String s) : this._((i, s), null);

  /// Direct loading: every URL passes through unchanged.
  static const ImageMirror direct = ImageMirror._(null, null);

  /// Hosts the auto mode races for the winning source. `i.pixiv.cat` is a
  /// candidate even though it is unreachable from the mainland — the race
  /// is the measurement, so an unreachable candidate simply loses.
  static const autoCandidates = [
    'i.pximg.net',
    'i.pixiv.re',
    'i.pixiv.nl',
    'i.pixiv.cat',
  ];

  /// Auto mode: rewrites through the last raced winner (a preset host, or
  /// direct when the winner is pximg / not yet resolved), while the
  /// allowlist admits every candidate so probes are routable.
  factory ImageMirror.auto(String? winnerHost) {
    final preset = winnerHost == null ? null : _presets[winnerHost];
    return ImageMirror._(
      preset?._presetPair,
      null,
      Set.unmodifiable(autoCandidates),
    );
  }

  /// Preset mirrors keyed by their persisted `imageSource` value (the
  /// `ImageSourceMode.host` of the matching enum entry). Each entry maps
  /// `i.pximg.net` → first host and `s.pximg.net` → second host.
  static const Map<String, ImageMirror> _presets = {
    'i.pixiv.cat': ImageMirror._preset('i.pixiv.cat', 's.pixiv.cat'),
    'i.pixiv.re': ImageMirror._preset('i.pixiv.re', 's.pixiv.re'),
    'i.pixiv.nl': ImageMirror._preset('i.pixiv.nl', 's.pixiv.nl'),
  };

  final (String, String)? _presetPair;
  final Uri? _customPrefix;

  /// Allowlist override — auto mode admits every candidate host so probes
  /// stay routable regardless of which one currently wins rewrites.
  final Set<String>? _extraHosts;

  static const String _iPximg = 'i.pximg.net';
  static const String _sPximg = 's.pximg.net';

  /// Resolves the persisted `imageSource` into a working mirror. Unknown
  /// or unparseable values fall back to [direct] — a corrupt setting must
  /// degrade to stock loading, not to a broken image pipeline.
  factory ImageMirror.of(String imageSource) {
    if (imageSource == _iPximg) return direct;
    // 'auto' is resolved by the provider layer via the last raced winner;
    // here it must never normalize into a bogus `https://auto` prefix.
    if (imageSource == ImageSourceMode.auto.host) {
      return ImageMirror.auto(null);
    }
    final preset = _presets[imageSource];
    if (preset != null) return preset;
    final normalized = normalizeCustomSource(imageSource);
    if (normalized != null) {
      return ImageMirror._(null, Uri.parse(normalized));
    }
    return direct;
  }

  static bool _isPximgHost(String host) => host == _iPximg || host == _sPximg;

  /// Normalizes a user-entered (or persisted) custom source to its
  /// canonical `https://host[:port][/path]` form, or null when the input
  /// cannot be a safe https origin.
  ///
  /// Bare `host[/path]` input is upgraded to https. userinfo, query and
  /// fragments are rejected so the stored value stays a pure origin
  /// prefix — anything richer would silently swallow parts of rewritten
  /// URLs.
  static String? normalizeCustomSource(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty || trimmed.contains(RegExp(r'\s'))) return null;
    final candidate = trimmed.contains('://') ? trimmed : 'https://$trimmed';
    final uri = Uri.tryParse(candidate);
    if (uri == null ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      return null;
    }
    // The destination registry only trusts https DNS names on 443 — IP
    // literals and explicit ports would pass this normalization but be
    // rejected at request time, so they are invalid here too.
    if (uri.hasPort && uri.port != 443) return null;
    final host = uri.host.toLowerCase();
    if (host.endsWith('.') ||
        host.contains('..') ||
        InternetAddress.tryParse(host) != null ||
        host.codeUnits.any((c) => c > 0x7f)) {
      return null;
    }
    var path = uri.path;
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return Uri(scheme: 'https', host: host, path: path).toString();
  }

  /// Hosts the image-purpose allowlist must accept for this selection,
  /// in addition to the canonical pximg pair the registry already knows.
  Set<String> get extraHosts =>
      _extraHosts ??
      {
        if (_presetPair != null) ...{_presetPair.$1, _presetPair.$2},
        ?_customPrefix?.host,
      };

  /// Rewrites a pximg image URL to the selected source. Returns [uri]
  /// unchanged for direct mode, non-pximg hosts, or unparseable state —
  /// mirroring never produces a request to a host the caller did not
  /// configure.
  Uri rewrite(Uri uri) {
    final pair = _presetPair;
    final prefix = _customPrefix;
    if (pair == null && prefix == null) return uri;
    if (!_isPximgHost(uri.host.toLowerCase())) return uri;
    if (pair != null) {
      final host = uri.host.toLowerCase() == _iPximg ? pair.$1 : pair.$2;
      return uri.replace(host: host);
    }
    final p = prefix!;
    return uri.replace(
      scheme: p.scheme,
      host: p.host,
      port: p.hasPort ? p.port : null,
      path: _joinPaths(p.path, uri.path),
    );
  }

  /// Convenience wrapper for string URLs; unparseable input passes
  /// through unchanged.
  String rewriteUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    return rewrite(uri).toString();
  }

  static String _joinPaths(String prefix, String suffix) {
    if (prefix.isEmpty || prefix == '/') return suffix;
    if (suffix.isEmpty || suffix == '/') return prefix;
    if (prefix.endsWith('/') && suffix.startsWith('/')) {
      return prefix + suffix.substring(1);
    }
    if (!prefix.endsWith('/') && !suffix.startsWith('/')) {
      return '$prefix/$suffix';
    }
    return '$prefix$suffix';
  }

  /// True when [imageSource] selects a preset mirror (one of
  /// [ImageSourceMode]'s non-normal entries) or a canonical custom prefix.
  ///
  /// Persisted custom values must already be normalized — the equality
  /// check rejects loose input like bare hosts (`proxy.com`) that
  /// [normalizeCustomSource] would rewrite (`https://proxy.com`).
  /// Callers accepting user input normalize first, then validate.
  static bool isValidSource(String imageSource) =>
      ImageSourceMode.fromHost(imageSource) != null ||
      normalizeCustomSource(imageSource) == imageSource;
}
