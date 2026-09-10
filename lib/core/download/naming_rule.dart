/// File naming presets (D6). `custom` uses [NamingRule.template].
enum NamingPreset {
  id('id'),
  artistTitleId('artistTitleId'),
  titleId('titleId'),
  custom('custom');

  const NamingPreset(this.code);

  final String code;

  static NamingPreset fromCode(Object? value) {
    for (final preset in values) {
      if (preset.code == value) return preset;
    }
    return NamingPreset.id;
  }
}

/// Single owner for template expansion, illegal-character cleanup, length
/// trimming and multi-page numbering (D6). No JS eval, no regex rules, no
/// conditional syntax; `/` can never appear in a rendered name.
class NamingRule {
  const NamingRule({required this.preset, this.template});

  final NamingPreset preset;
  final String? template;

  static const NamingRule defaultRule = NamingRule(preset: NamingPreset.id);

  /// Variables a custom template may use.
  static const Set<String> supportedVariables = {
    'artist',
    'title',
    'id',
    'page',
    'ext',
    'date',
  };

  static const int maxFileNameLength = 180;

  /// Characters replaced by `_` inside a rendered file name. This set is
  /// intentionally tighter than the platform's own list because names also
  /// cross the MediaStore display path.
  static const String illegalCharacters = r'/\:*?"<>|';

  /// Characters other than the illegal set that are also unsafe in a
  /// rendered name (control chars and surrounding dots).
  static bool _isUnsafe(int unit) => unit < 0x20 || unit == 0x7f;

  /// Custom template token validation: returns true when the template only
  /// uses supported variables and literal text. Empty/absent template is
  /// invalid for the `custom` preset.
  static bool isValidTemplate(String? input) {
    if (input == null) return false;
    final trimmed = input.trim();
    if (trimmed.isEmpty) return false;
    final matches = _tokenPattern.allMatches(trimmed).toList();
    if (matches.isEmpty) return false;
    var lastEnd = 0;
    for (final match in matches) {
      if (!supportedVariables.contains(match.group(1))) return false;
      if (!_isSafeLiteral(trimmed.substring(lastEnd, match.start))) {
        return false;
      }
      lastEnd = match.end;
    }
    return _isSafeLiteral(trimmed.substring(lastEnd));
  }

  /// Resolves a file name (without extension? — no: full name including
  /// extension) for one downloaded page. Result is traversal-safe: no
  /// separator and max [maxFileNameLength] chars.
  String resolve({
    required int illustId,
    required int pageIndex,
    required String extension,
    String? artist,
    String? title,
    DateTime? date,
  }) {
    final ext = _safeExtension(extension);
    final effectiveTemplate = switch (preset) {
      NamingPreset.id => '{id}_p{page}.{ext}',
      NamingPreset.artistTitleId => '{artist}_{title}_{id}_p{page}.{ext}',
      NamingPreset.titleId => '{title}_{id}_p{page}.{ext}',
      NamingPreset.custom =>
        (template != null && isValidTemplate(template))
            ? template!
            : '{id}_p{page}.{ext}',
    };
    var rendered = _expand(
      effectiveTemplate,
      illustId: illustId,
      pageIndex: pageIndex,
      extension: ext,
      artist: artist,
      title: title,
      date: date,
    );
    rendered = _clean(rendered);
    rendered = _trim(rendered, ext);
    if (rendered.isEmpty) rendered = '${illustId}_p$pageIndex.$ext';
    return rendered;
  }

  /// Live preview used by the settings page. Same expansion, same cleanup;
  /// `artist`/`title` may be omitted and render as empty segments.
  String preview({
    required int illustId,
    required int pageIndex,
    required String extension,
    String? artist,
    String? title,
    DateTime? date,
  }) => resolve(
    illustId: illustId,
    pageIndex: pageIndex,
    extension: extension,
    artist: artist,
    title: title,
    date: date,
  );

  static String _expand(
    String template, {
    required int illustId,
    required int pageIndex,
    required String extension,
    String? artist,
    String? title,
    DateTime? date,
  }) {
    String resolveName(String key) => switch (key) {
      'artist' => artist ?? '',
      'title' => title ?? '',
      'id' => '$illustId',
      'page' => '$pageIndex',
      'ext' => extension,
      'date' => _formatDate(date),
      _ => '',
    };
    return template.replaceAllMapped(_tokenPattern, (match) {
      final key = match.group(1)!;
      return supportedVariables.contains(key) ? resolveName(key) : '';
    });
  }

  static String _formatDate(DateTime? date) {
    if (date == null) return '';
    final y = date.year.toString().padLeft(4, '0');
    final m = date.month.toString().padLeft(2, '0');
    final d = date.day.toString().padLeft(2, '0');
    return '$y$m$d';
  }

  static String _clean(String input) {
    final buffer = StringBuffer();
    for (final unit in input.codeUnits) {
      final char = String.fromCharCode(unit);
      if (illegalCharacters.contains(char) || _isUnsafe(unit)) {
        buffer.write('_');
      } else {
        buffer.write(char);
      }
    }
    var cleaned = buffer.toString();
    while (cleaned.contains('__')) {
      cleaned = cleaned.replaceAll('__', '_');
    }
    if (cleaned.startsWith('.')) cleaned = '_${cleaned.substring(1)}';
    if (cleaned.endsWith('.')) {
      cleaned = '${cleaned.substring(0, cleaned.length - 1)}_';
    }
    return cleaned;
  }

  static String _trim(String name, String extension) {
    if (name.length <= maxFileNameLength) return name;
    final suffix = '.$extension';
    final keep = suffix.length;
    return '${name.substring(0, maxFileNameLength - keep)}$suffix';
  }

  /// Matches exactly `{name}` tokens with an alphabetic name.
  static final RegExp _tokenPattern = RegExp(r'\{([a-zA-Z]+)\}');

  static bool _isSafeLiteral(String value) {
    // Any stray brace inside literal text would be a malformed token.
    if (value.contains('{') || value.contains('}')) return false;
    return true;
  }

  static String _safeExtension(String raw) {
    final ext = raw.toLowerCase().replaceAll('.', '');
    return ext.isEmpty ? 'jpg' : ext;
  }

  @override
  bool operator ==(Object other) =>
      other is NamingRule &&
      other.preset == preset &&
      other.template == template;

  @override
  int get hashCode => Object.hash(preset, template);
}
