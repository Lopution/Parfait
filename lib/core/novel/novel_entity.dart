import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../user/user_entity.dart';

/// A piece of inline formatting understood by the novel reader.
///
/// The reader deliberately keeps the source span as plain text.  This means
/// ruby, jump links and future Pixiv marks can be rendered safely even when
/// the visual treatment is not available yet.
class NovelInlineMark {
  const NovelInlineMark({
    required this.kind,
    required this.start,
    required this.end,
    this.value,
    this.raw,
  });

  final String kind;
  final int start;
  final int end;
  final String? value;
  final String? raw;

  bool get isUnknown => kind == 'unknown';
}

/// The content model intentionally has a block boundary even though the
/// current API returns paragraphs.  Future image or separator blocks can be
/// added without making the layout engine depend on raw API JSON.
sealed class NovelBlock {
  const NovelBlock();

  String get id;
  String get plainText;
}

class NovelParagraph extends NovelBlock {
  const NovelParagraph({
    required this.id,
    required this.text,
    this.inlineMarks = const [],
  });

  @override
  final String id;
  final String text;
  final List<NovelInlineMark> inlineMarks;

  @override
  String get plainText => text;
}

class NovelTag {
  const NovelTag({required this.name, this.translatedName});

  final String name;
  final String? translatedName;
}

class NovelSeriesEntry {
  const NovelSeriesEntry({
    required this.id,
    required this.title,
    required this.viewable,
    this.contentOrder,
    this.viewableMessage,
  });

  final int id;
  final String title;
  final bool viewable;
  final String? contentOrder;
  final String? viewableMessage;
}

/// Domain representation of a Pixiv novel.
///
/// List endpoints normally contain metadata only.  [contentAvailable] keeps
/// that distinction explicit so a preview can be displayed and opened without
/// accidentally treating a missing body as an empty body.
class NovelEntity {
  const NovelEntity({
    required this.id,
    required this.title,
    required this.caption,
    required this.user,
    required this.tags,
    required this.textLength,
    required this.contentVersion,
    required this.paragraphs,
    this.seriesId,
    this.seriesTitle,
    this.coverImageUrl,
    this.restrict = 0,
    this.xRestrict = 0,
    this.isOriginal = false,
    this.isBookmarked = false,
    this.totalBookmarks = 0,
    this.totalView = 0,
    this.totalComments = 0,
    this.visible = true,
    this.isMuted = false,
    this.isMyPixivOnly = false,
    this.isXRestricted = false,
    this.novelAiType = 0,
    this.createDate,
    this.contentAvailable = false,
  });

  final int id;
  final String title;
  final String caption;
  final UserEntity user;
  final List<NovelTag> tags;
  final int textLength;
  final String contentVersion;
  final List<NovelParagraph> paragraphs;
  final int? seriesId;
  final String? seriesTitle;
  final String? coverImageUrl;
  final int restrict;
  final int xRestrict;
  final bool isOriginal;
  final bool isBookmarked;
  final int totalBookmarks;
  final int totalView;
  final int totalComments;
  final bool visible;
  final bool isMuted;
  final bool isMyPixivOnly;
  final bool isXRestricted;
  final int novelAiType;
  final String? createDate;
  final bool contentAvailable;

  UserEntity get author => user;

  bool get isRestricted => !visible || isXRestricted;

  String get plainText =>
      paragraphs.map((paragraph) => paragraph.text).join('\n');

  NovelEntity copyWith({
    Object? title = _unset,
    Object? caption = _unset,
    Object? tags = _unset,
    Object? textLength = _unset,
    Object? contentVersion = _unset,
    Object? paragraphs = _unset,
    Object? seriesId = _unset,
    Object? seriesTitle = _unset,
    Object? coverImageUrl = _unset,
    Object? isBookmarked = _unset,
    Object? visible = _unset,
    Object? contentAvailable = _unset,
  }) {
    return NovelEntity(
      id: id,
      title: identical(title, _unset) ? this.title : title as String,
      caption: identical(caption, _unset) ? this.caption : caption as String,
      user: user,
      tags: identical(tags, _unset) ? this.tags : tags as List<NovelTag>,
      textLength: identical(textLength, _unset)
          ? this.textLength
          : textLength as int,
      contentVersion: identical(contentVersion, _unset)
          ? this.contentVersion
          : contentVersion as String,
      paragraphs: identical(paragraphs, _unset)
          ? this.paragraphs
          : paragraphs as List<NovelParagraph>,
      seriesId: identical(seriesId, _unset) ? this.seriesId : seriesId as int?,
      seriesTitle: identical(seriesTitle, _unset)
          ? this.seriesTitle
          : seriesTitle as String?,
      coverImageUrl: identical(coverImageUrl, _unset)
          ? this.coverImageUrl
          : coverImageUrl as String?,
      restrict: restrict,
      xRestrict: xRestrict,
      isOriginal: isOriginal,
      isBookmarked: identical(isBookmarked, _unset)
          ? this.isBookmarked
          : isBookmarked as bool,
      totalBookmarks: totalBookmarks,
      totalView: totalView,
      totalComments: totalComments,
      visible: identical(visible, _unset) ? this.visible : visible as bool,
      isMuted: isMuted,
      isMyPixivOnly: isMyPixivOnly,
      isXRestricted: isXRestricted,
      novelAiType: novelAiType,
      createDate: createDate,
      contentAvailable: identical(contentAvailable, _unset)
          ? this.contentAvailable
          : contentAvailable as bool,
    );
  }

  static const _unset = Object();

  /// Parses either a list/detail novel object.  The parser never accepts an
  /// HTML body; only JSON `content` or a structured JSON content list is used.
  factory NovelEntity.fromJson(Map<String, dynamic> json) {
    final id = _positiveInt(json['id'], 'novel.id');
    final title = _requiredString(json['title'], 'novel.title');
    final userJson = json['user'];
    if (userJson is! Map<String, dynamic>) {
      throw const FormatException('novel.user is missing or malformed');
    }
    final user = UserEntity.fromUserJson(userJson);
    final rawContent = json.containsKey('content')
        ? json['content']
        : json['novel_text'];
    final contentAvailable = rawContent is String || rawContent is List;
    final paragraphs = contentAvailable
        ? NovelContentMapper.fromRaw(rawContent)
        : const <NovelParagraph>[];
    final series = _map(json['series']);
    final imageUrls = _map(json['image_urls']);
    final contentSeed = rawContent == null
        ? 'metadata:$id:${json['text_length'] ?? 0}'
        : jsonEncode(rawContent);
    final contentVersion = sha256.convert(utf8.encode(contentSeed)).toString();
    final apiTextLength = _nonNegativeInt(json['text_length']);

    return NovelEntity(
      id: id,
      title: title,
      caption: _optionalString(json['caption']) ?? '',
      user: user,
      tags: _tags(json['tags']),
      textLength: apiTextLength == 0 && contentAvailable
          ? paragraphs.fold<int>(0, (total, item) => total + item.text.length)
          : apiTextLength,
      contentVersion: contentVersion,
      paragraphs: List.unmodifiable(paragraphs),
      seriesId: _nullablePositiveInt(series['id']),
      seriesTitle: _optionalString(series['title']),
      coverImageUrl: _firstString(imageUrls, const [
        'medium',
        'large',
        'square_medium',
      ]),
      restrict: _nonNegativeInt(json['restrict']),
      xRestrict: _nonNegativeInt(json['x_restrict']),
      isOriginal: json['is_original'] == true,
      isBookmarked: json['is_bookmarked'] == true,
      totalBookmarks: _nonNegativeInt(json['total_bookmarks']),
      totalView: _nonNegativeInt(json['total_view']),
      totalComments: _nonNegativeInt(json['total_comments']),
      visible: json['visible'] is! bool || json['visible'] == true,
      isMuted: json['is_muted'] == true,
      isMyPixivOnly: json['is_mypixiv_only'] == true,
      isXRestricted: json['is_x_restricted'] == true,
      novelAiType: _nonNegativeInt(json['novel_ai_type']),
      createDate: _optionalString(json['create_date']),
      contentAvailable: contentAvailable,
    );
  }

  factory NovelEntity.fromDetailJson(Map<String, dynamic> json) {
    final novel = json['novel'];
    if (novel is! Map<String, dynamic>) {
      throw const FormatException('novel detail envelope is missing novel');
    }
    return NovelEntity.fromJson(novel);
  }

  @override
  String toString() => 'NovelEntity($id, $title)';
}

/// Converts Pixiv's plain-text novel body into stable paragraph blocks.
abstract final class NovelContentMapper {
  static List<NovelParagraph> fromRaw(Object? raw) {
    if (raw is String) return fromText(raw);
    if (raw is! List) {
      throw const FormatException('novel content is not JSON text or a list');
    }
    final result = <NovelParagraph>[];
    for (var index = 0; index < raw.length; index++) {
      final item = raw[index];
      if (item is String) {
        result.add(_paragraph('p$index', item));
        continue;
      }
      if (item is Map<String, dynamic>) {
        final text = item['text'] ?? item['content'];
        if (text is String) {
          result.add(
            _paragraph(_optionalString(item['id']) ?? 'p$index', text),
          );
          continue;
        }
      }
      // Preserve an unknown JSON block visibly rather than dropping content
      // or pretending it was successfully rendered.
      result.add(_paragraph('p$index', jsonEncode(item), unknownOnly: true));
    }
    return result;
  }

  static List<NovelParagraph> fromText(String raw) {
    final normalized = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final lines = normalized.split('\n');
    return [
      for (var index = 0; index < lines.length; index++)
        _paragraph('p$index', lines[index]),
    ];
  }

  static NovelParagraph _paragraph(
    String id,
    String raw, {
    bool unknownOnly = false,
  }) {
    if (unknownOnly) {
      return NovelParagraph(
        id: id,
        text: raw,
        inlineMarks: [
          NovelInlineMark(kind: 'unknown', start: 0, end: raw.length, raw: raw),
        ],
      );
    }
    final markPattern = RegExp(r'\[\[([A-Za-z0-9_-]+):(.*?)\]\]', dotAll: true);
    final buffer = StringBuffer();
    final marks = <NovelInlineMark>[];
    var cursor = 0;
    for (final match in markPattern.allMatches(raw)) {
      buffer.write(raw.substring(cursor, match.start));
      final kind = match.group(1)!.toLowerCase();
      final payload = match.group(2)!;
      final separator = payload.indexOf(' > ');
      final isKnown = kind == 'rb' || kind == 'jumpuri' || kind == 'jumpurl';
      final display = switch (kind) {
        'rb' when separator >= 0 => payload.substring(0, separator),
        'jumpuri' ||
        'jumpurl' when separator >= 0 => payload.substring(separator + 3),
        _ => isKnown ? payload : match.group(0)!,
      };
      final start = buffer.length;
      buffer.write(display);
      final end = buffer.length;
      marks.add(
        NovelInlineMark(
          kind: isKnown ? kind : 'unknown',
          start: start,
          end: end,
          value: separator >= 0 ? payload.substring(separator + 3) : null,
          raw: match.group(0),
        ),
      );
      cursor = match.end;
    }
    buffer.write(raw.substring(cursor));
    return NovelParagraph(
      id: id,
      text: buffer.toString(),
      inlineMarks: List.unmodifiable(marks),
    );
  }
}

int _positiveInt(Object? value, String field) {
  final parsed = value is int ? value : int.tryParse('$value');
  if (parsed == null || parsed <= 0) {
    throw FormatException('$field must be a positive integer');
  }
  return parsed;
}

int? _nullablePositiveInt(Object? value) {
  final parsed = value is int ? value : int.tryParse('$value');
  return parsed == null || parsed <= 0 ? null : parsed;
}

int _nonNegativeInt(Object? value) {
  final parsed = value is int ? value : int.tryParse('$value');
  return parsed == null || parsed < 0 ? 0 : parsed;
}

String _requiredString(Object? value, String field) {
  if (value is! String || value.isEmpty) {
    throw FormatException('$field must be a non-empty string');
  }
  return value;
}

String? _optionalString(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

Map<String, dynamic> _map(Object? value) =>
    value is Map<String, dynamic> ? value : const <String, dynamic>{};

String? _firstString(Map<String, dynamic> values, List<String> keys) {
  for (final key in keys) {
    final value = _optionalString(values[key]);
    if (value != null) return value;
  }
  return null;
}

List<NovelTag> _tags(Object? value) {
  if (value is! List) return const [];
  return [
    for (final item in value)
      if (item is Map<String, dynamic> && item['name'] is String)
        NovelTag(
          name: item['name'] as String,
          translatedName: _optionalString(item['translated_name']),
        ),
  ];
}
