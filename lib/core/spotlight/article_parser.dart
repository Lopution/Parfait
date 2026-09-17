import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../network/api_error.dart';
import 'spotlight_models.dart';

/// Parses a www.pixivision.net article page into typed blocks for in-app
/// rendering (no webview).
///
/// Structure (verified against PixEz `soup_store` and Shaft):
/// - `article .am__body` holds the content; the `_feature` layout nests the
///   real blocks one wrapper deeper.
/// - `.illust` cards carry an `/artworks/<id>` link, an `h3` title, a
///   thumbnail `img` and a `/users/<id>` author link.
/// - `article header` carries the lead description.
SpotlightArticleBody parseSpotlightArticle(String html) {
  final document = html_parser.parse(html);
  final article = document.querySelector('article');
  if (article == null) {
    throw const ApiParseError('spotlight page has no article element');
  }
  final bodyElement = article.querySelector('.am__body');
  if (bodyElement == null) {
    throw const ApiParseError('spotlight article has no .am__body');
  }
  // `_feature` articles wrap the real blocks in a single inner container.
  var container = bodyElement;
  for (final child in bodyElement.children) {
    if (child.classes.contains('_feature')) {
      container = child;
      break;
    }
  }
  final blocks = <SpotlightBlock>[];
  for (final element in container.children) {
    _collectBlock(element, blocks);
  }
  if (blocks.isEmpty) {
    throw const ApiParseError('spotlight article body is empty');
  }
  final header = article.querySelector('header');
  final title =
      article.querySelector('h1')?.text.trim() ??
      document.querySelector('title')?.text.trim() ??
      '';
  return SpotlightArticleBody(
    title: title,
    description: _headerDescription(header),
    blocks: blocks,
  );
}

/// The header holds the lead paragraph(s); skip nav/ads that share the tag.
String? _headerDescription(dom.Element? header) {
  if (header == null) return null;
  final text = header.text.trim();
  return text.isEmpty ? null : text;
}

void _collectBlock(dom.Element element, List<SpotlightBlock> out) {
  if (element.classes.contains('illust')) {
    final card = _parseIllustCard(element);
    if (card != null) out.add(card);
    return;
  }
  switch (element.localName) {
    case 'p':
      final segments = _paragraphSegments(element);
      if (segments.isNotEmpty) {
        out.add(SpotlightParagraph(segments));
      } else {
        // `<p><img></p>` — a standalone image wrapped in a paragraph.
        for (final img in element.querySelectorAll('img')) {
          final url = _imageUrl(img);
          if (url != null) out.add(SpotlightImage(url));
        }
      }
    case 'h1' || 'h2' || 'h3' || 'h4':
      final text = element.text.trim();
      if (text.isNotEmpty) {
        out.add(
          SpotlightHeading(text, level: int.parse(element.localName![1])),
        );
      }
    case 'img':
      final url = _imageUrl(element);
      if (url != null) out.add(SpotlightImage(url));
    default:
      // Wrappers (section/div/figure/ul/blockquote/…) recurse so nested
      // paragraphs and cards are still found; leaf elements with text that
      // are not handled above degrade to a paragraph.
      if (element.children.isNotEmpty) {
        for (final child in element.children) {
          _collectBlock(child, out);
        }
      } else {
        final text = element.text.trim();
        if (text.isNotEmpty) {
          out.add(SpotlightParagraph(_paragraphSegments(element)));
        }
      }
  }
}

/// Flattens a paragraph into ordered (text, href) runs; nested inline
/// markup (em/strong inside or around links) keeps the link context.
List<({String text, String? href})> _paragraphSegments(dom.Element element) {
  final segments = <({String text, String? href})>[];
  void walk(dom.Node node, String? href) {
    if (node is dom.Text) {
      final text = node.text.replaceAll(RegExp(r'\s+'), ' ');
      if (text.trim().isNotEmpty) segments.add((text: text, href: href));
      return;
    }
    if (node is! dom.Element) return;
    final tag = node.localName;
    if (tag == 'br') return;
    final next = tag == 'a' ? node.attributes['href'] ?? href : href;
    for (final child in node.nodes) {
      walk(child, next);
    }
  }

  for (final node in element.nodes) {
    walk(node, null);
  }
  return segments;
}

String? _imageUrl(dom.Element img) {
  for (final attr in const ['src', 'data-src', 'data-original']) {
    final value = img.attributes[attr];
    if (value != null && value.isNotEmpty) return value;
  }
  return null;
}

final _artworksPattern = RegExp(r'/artworks/(\d+)');
final _usersPattern = RegExp(r'/users/(\d+)');

int? _idFromHref(dom.Element? link, RegExp pattern) {
  final href = link?.attributes['href'];
  if (href == null) return null;
  return int.tryParse(pattern.firstMatch(href)?.group(1) ?? '');
}

SpotlightIllustCard? _parseIllustCard(dom.Element element) {
  final link = element.querySelector('a[href*="/artworks/"]');
  final illustId = _idFromHref(link, _artworksPattern);
  if (illustId == null) return null;
  final image = element.querySelector('img');
  final title =
      element.querySelector('h3')?.text.trim() ??
      element.querySelector('h2, h4')?.text.trim() ??
      link?.text.trim() ??
      '';
  final userLink = element.querySelector('a[href*="/users/"]');
  return SpotlightIllustCard(
    illustId: illustId,
    title: title,
    imageUrl: image == null ? null : _imageUrl(image),
    userName: userLink?.text.trim(),
    userId: _idFromHref(userLink, _usersPattern),
  );
}
