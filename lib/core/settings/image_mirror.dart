/// Image-source mirror selection → pximg URL rewrite.
///
/// Semantics follow Shaft `ImageHostManager` (issue #865): presets mirror
/// both the `i.` and `s.` pximg subdomains; a custom source is a full URL
/// prefix (`https://host[:port][/path]`) that replaces the pximg origin
/// wholesale while preserving the original path tail and query.
///
/// The resolver is pure data: [of] parses the persisted `imageSource`
/// string and [rewrite] maps one URL. Wiring (registry allowlist, image
/// client) lives in the network layer.
library;

/// Image source exposed by settings. [custom] carries no fixed host — the
/// actual prefix is the persisted `imageSource` string itself (normalized
/// to `https://host[/path]` by [ImageMirror.normalizeCustomSource]).
enum ImageSourceMode {
  normal('i.pximg.net'),
  pixivCat('i.pixiv.cat'),
  pixivRe('i.pixiv.re'),
  pixivNl('i.pixiv.nl'),
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
  const ImageMirror._(this._presetPair, this._customPrefix);

  const ImageMirror._preset(String i, String s) : this._((i, s), null);

  /// Direct loading: every URL passes through unchanged.
  static const ImageMirror direct = ImageMirror._(null, null);

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

  static const String _iPximg = 'i.pximg.net';
  static const String _sPximg = 's.pximg.net';

  /// Resolves the persisted `imageSource` into a working mirror. Unknown
  /// or unparseable values fall back to [direct] — a corrupt setting must
  /// degrade to stock loading, not to a broken image pipeline.
  factory ImageMirror.of(String imageSource) {
    if (imageSource == _iPximg) return direct;
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
    final host = uri.host.toLowerCase();
    if (host.endsWith('.') ||
        host.contains('..') ||
        host.codeUnits.any((c) => c > 0x7f)) {
      return null;
    }
    var path = uri.path;
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return Uri(
      scheme: 'https',
      host: host,
      port: uri.hasPort ? uri.port : null,
      path: path,
    ).toString();
  }

  /// Hosts the image-purpose allowlist must accept for this selection,
  /// in addition to the canonical pximg pair the registry already knows.
  Set<String> get extraHosts => {
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
