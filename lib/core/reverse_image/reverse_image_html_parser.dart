import 'package:flutter/foundation.dart';

import '../platform/intent_router.dart';
import 'reverse_image_engine.dart';
import 'reverse_image_external.dart';
import 'reverse_image_navigation_policy.dart';

/// A single match extracted from a service-rendered reverse-image HTML page
/// (SauceNAO / IQDB) for platforms without an in-app WebView.
@immutable
class ReverseImageHtmlMatch {
  const ReverseImageHtmlMatch({
    required this.uri,
    required this.action,
    required this.title,
    this.similarity,
    this.illustId,
    this.userId,
  });

  /// Validated HTTPS destination URL (never engine-self, never non-HTTPS).
  final Uri uri;

  /// Policy decision: `openIllust`, `openUser`, or `openExternal`.
  final ReverseImageNavigationAction action;

  /// Human-readable match label (title, source site, or host fallback).
  final String title;

  /// Optional similarity text such as `94.82%`.
  final String? similarity;

  /// Pixiv artwork id when [action] is [ReverseImageNavigationAction.openIllust].
  final int? illustId;

  /// Pixiv user id when [action] is [ReverseImageNavigationAction.openUser].
  final int? userId;
}

const int _maxParsedMatches = 25;

final _sauceNaoBlockPattern = RegExp(
  r'<div\b[^>]*class="[^"]*\bresult\b[^"]*"[^>]*>(.*?)(?=<div\b[^>]*class="[^"]*\bresult\b|<div\b[^>]*id="result-hidden-notification"|</div>\s*</div>\s*<div\b[^>]*id="footer"|$)',
  caseSensitive: false,
  dotAll: true,
);
final _sauceNaoSimPattern = RegExp(
  r'class="[^"]*\bresultsimilarityinfo\b[^"]*"[^>]*>(.*?)<',
  caseSensitive: false,
  dotAll: true,
);
final _sauceNaoTitlePattern = RegExp(
  r'class="[^"]*\bresulttitle\b[^"]*"[^>]*>(.*?)</div>',
  caseSensitive: false,
  dotAll: true,
);

final _iqdbTablePattern = RegExp(
  r'<table\b[^>]*>(.*?)</table>',
  caseSensitive: false,
  dotAll: true,
);
final _iqdbHeadingPattern = RegExp(
  r'<th\b[^>]*>(.*?)</th>',
  caseSensitive: false,
  dotAll: true,
);
final _iqdbSimPattern = RegExp(
  r'(\d+(?:\.\d+)?)\s*%\s*similarity',
  caseSensitive: false,
);

final _anchorPattern = RegExp(
  r'''<a\b[^>]*\bhref\s*=\s*(?:"([^"]+)"|'([^']+)')[^>]*>(.*?)</a>''',
  caseSensitive: false,
  dotAll: true,
);
final _tagPattern = RegExp(r'<[^>]+>');
final _whitespacePattern = RegExp(r'\s+');
final _numericEntityPattern = RegExp(r'&#(x[0-9a-fA-F]+|\d+);');

/// Parses clickable matches from a service-rendered SauceNAO or IQDB HTML page.
///
/// Every returned match passes [ReverseImageEngineSpec.navigationPolicy] and,
/// for external links, [validateExternalResultUrl] (strictly HTTPS, no
/// credentials/ports/fragments, never engine-self navigation).
List<ReverseImageHtmlMatch> parseReverseImageHtmlMatches(
  ReverseImageEngineSpec spec,
  String html,
) {
  if (html.trim().isEmpty) return const [];
  final policy = spec.navigationPolicy;
  final matches = switch (spec.engine) {
    ReverseImageEngine.sauceNao => _parseSauceNao(html, policy),
    ReverseImageEngine.iqdb => _parseIqdb(html, policy),
    ReverseImageEngine.ascii2d ||
    ReverseImageEngine.tinEye => const <ReverseImageHtmlMatch>[],
  };
  if (matches.isNotEmpty) return matches;
  return _parseFallbackAnchors(html, policy);
}

List<ReverseImageHtmlMatch> _parseSauceNao(
  String html,
  ReverseImageNavigationPolicy policy,
) {
  final out = <ReverseImageHtmlMatch>[];
  final seen = <String>{};
  for (final blockMatch in _sauceNaoBlockPattern.allMatches(html)) {
    if (out.length >= _maxParsedMatches) break;
    final block = blockMatch.group(1) ?? '';
    final similarity = _cleanText(
      _sauceNaoSimPattern.firstMatch(block)?.group(1),
    );
    final title = _cleanText(_sauceNaoTitlePattern.firstMatch(block)?.group(1));
    final best = _pickBestCandidate(block, policy, seen);
    if (best == null) continue;
    seen.add(best.uri.toString());
    out.add(
      ReverseImageHtmlMatch(
        uri: best.uri,
        action: best.action,
        title: title.isNotEmpty
            ? title
            : (best.anchorText.isNotEmpty ? best.anchorText : best.uri.host),
        similarity: similarity.isNotEmpty ? similarity : null,
        illustId: best.illustId,
        userId: best.userId,
      ),
    );
  }
  return out;
}

List<ReverseImageHtmlMatch> _parseIqdb(
  String html,
  ReverseImageNavigationPolicy policy,
) {
  final out = <ReverseImageHtmlMatch>[];
  final seen = <String>{};
  for (final tableMatch in _iqdbTablePattern.allMatches(html)) {
    if (out.length >= _maxParsedMatches) break;
    final table = tableMatch.group(1) ?? '';
    final heading = _cleanText(_iqdbHeadingPattern.firstMatch(table)?.group(1));
    final lowerHeading = heading.toLowerCase();
    if (lowerHeading.contains('your image') ||
        lowerHeading.contains('no relevant')) {
      continue;
    }
    final simRaw = _iqdbSimPattern.firstMatch(table)?.group(1);
    final similarity = simRaw != null ? '$simRaw%' : null;
    final best = _pickBestCandidate(table, policy, seen);
    if (best == null) continue;
    seen.add(best.uri.toString());
    final label = heading.isNotEmpty
        ? '$heading · ${best.uri.host}'
        : (best.anchorText.isNotEmpty ? best.anchorText : best.uri.host);
    out.add(
      ReverseImageHtmlMatch(
        uri: best.uri,
        action: best.action,
        title: label,
        similarity: similarity,
        illustId: best.illustId,
        userId: best.userId,
      ),
    );
  }
  return out;
}

List<ReverseImageHtmlMatch> _parseFallbackAnchors(
  String html,
  ReverseImageNavigationPolicy policy,
) {
  final out = <ReverseImageHtmlMatch>[];
  final seen = <String>{};
  for (final match in _anchorPattern.allMatches(html)) {
    if (out.length >= _maxParsedMatches) break;
    final rawHref = match.group(1) ?? match.group(2) ?? '';
    final anchorText = _cleanText(match.group(3));
    final candidate = _classifyHref(rawHref, anchorText, policy);
    if (candidate == null) continue;
    final key = candidate.uri.toString();
    if (!seen.add(key)) continue;
    out.add(
      ReverseImageHtmlMatch(
        uri: candidate.uri,
        action: candidate.action,
        title: candidate.anchorText.isNotEmpty
            ? candidate.anchorText
            : candidate.uri.host,
        illustId: candidate.illustId,
        userId: candidate.userId,
      ),
    );
  }
  return out;
}

class _CandidateLink {
  const _CandidateLink({
    required this.uri,
    required this.action,
    required this.anchorText,
    required this.priority,
    this.illustId,
    this.userId,
  });

  final Uri uri;
  final ReverseImageNavigationAction action;
  final String anchorText;
  final int priority;
  final int? illustId;
  final int? userId;
}

_CandidateLink? _pickBestCandidate(
  String fragment,
  ReverseImageNavigationPolicy policy,
  Set<String> seen,
) {
  _CandidateLink? best;
  for (final match in _anchorPattern.allMatches(fragment)) {
    final rawHref = match.group(1) ?? match.group(2) ?? '';
    final anchorText = _cleanText(match.group(3));
    final candidate = _classifyHref(rawHref, anchorText, policy);
    if (candidate == null || seen.contains(candidate.uri.toString())) continue;
    if (best == null || candidate.priority > best.priority) {
      best = candidate;
    }
  }
  return best;
}

_CandidateLink? _classifyHref(
  String rawHref,
  String anchorText,
  ReverseImageNavigationPolicy policy,
) {
  final decoded = _decodeHtmlEntities(rawHref).trim();
  if (decoded.isEmpty) return null;
  final normalized = decoded.startsWith('//') ? 'https:$decoded' : decoded;
  final uri = Uri.tryParse(normalized);
  if (uri == null) return null;
  final action = policy.decide(uri);
  switch (action) {
    case ReverseImageNavigationAction.openIllust:
      final route = IntentRouter.route(uri);
      if (route is! IllustRoute) return null;
      return _CandidateLink(
        uri: uri,
        action: action,
        anchorText: anchorText,
        priority: 3,
        illustId: route.illustId,
      );
    case ReverseImageNavigationAction.openUser:
      final route = IntentRouter.route(uri);
      if (route is! UserRoute) return null;
      return _CandidateLink(
        uri: uri,
        action: action,
        anchorText: anchorText,
        priority: 2,
        userId: route.userId,
      );
    case ReverseImageNavigationAction.openExternal:
      try {
        validateExternalResultUrl(uri);
      } on FormatException {
        return null;
      }
      return _CandidateLink(
        uri: uri,
        action: action,
        anchorText: anchorText,
        priority: 1,
      );
    case ReverseImageNavigationAction.navigate:
    case ReverseImageNavigationAction.reject:
      return null;
  }
}

String _cleanText(String? html) {
  if (html == null || html.isEmpty) return '';
  final stripped = html.replaceAll(_tagPattern, ' ');
  return _decodeHtmlEntities(
    stripped,
  ).replaceAll(_whitespacePattern, ' ').trim();
}

String _decodeHtmlEntities(String input) {
  var result = input
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&nbsp;', ' ');
  result = result.replaceAllMapped(_numericEntityPattern, (m) {
    final token = m.group(1)!;
    final code = token.startsWith('x') || token.startsWith('X')
        ? int.tryParse(token.substring(1), radix: 16)
        : int.tryParse(token);
    if (code == null || code <= 0 || code > 0x10FFFF) return m.group(0)!;
    return String.fromCharCode(code);
  });
  return result;
}
