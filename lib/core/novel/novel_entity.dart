import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../network/api_error.dart';
import '../network/compat/network_contracts.dart';
import '../network/pixiv_http_client.dart';
import '../user/user_entity.dart';
import '../entity/json_read.dart';

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

/// A typed piece of Pixiv Novel markup.
///
/// The parser never turns these values into HTML or executes a URI. Every
/// token retains the exact source marker and its raw payload so unsupported
/// syntax remains diagnosable and can be rendered as visible fallback text.
@immutable
sealed class NovelMarkupToken {
  NovelMarkupToken({
    required this.rawName,
    required this.rawText,
    this.sourceOffset = 0,
    Map<String, String> attributes = const {},
  }) : attributes = Map.unmodifiable(attributes);

  final String rawName;
  final String rawText;
  final int sourceOffset;
  final Map<String, String> attributes;

  String get raw => rawText;

  String get displayText => rawText;

  bool get isUnsupported => false;
}

class NovelTextToken extends NovelMarkupToken {
  NovelTextToken(this.text, {super.sourceOffset, super.attributes})
    : super(rawName: 'text', rawText: text);

  final String text;

  @override
  String get displayText => text;
}

class NovelNewPageToken extends NovelMarkupToken {
  NovelNewPageToken({
    required super.rawText,
    required super.sourceOffset,
    super.attributes,
  }) : super(rawName: 'newpage');

  @override
  String get displayText => '';
}

class NovelChapterToken extends NovelMarkupToken {
  NovelChapterToken({
    required this.title,
    required super.rawText,
    required super.sourceOffset,
    super.attributes,
  }) : super(rawName: 'chapter');

  final String title;

  @override
  String get displayText => '';
}

class NovelRubyToken extends NovelMarkupToken {
  NovelRubyToken({
    required this.baseText,
    required this.annotation,
    required super.rawText,
    required super.sourceOffset,
    this.error,
    super.attributes,
  }) : super(rawName: 'rb');

  final String baseText;
  final String annotation;
  final String? error;

  bool get isValid => error == null;

  @override
  String get displayText => isValid ? baseText : rawText;

  @override
  bool get isUnsupported => !isValid;
}

sealed class NovelJumpTarget {
  const NovelJumpTarget();
}

class NovelPageJumpTarget extends NovelJumpTarget {
  const NovelPageJumpTarget(this.page);

  final int page;
}

class NovelUriJumpTarget extends NovelJumpTarget {
  const NovelUriJumpTarget(this.uri);

  final Uri uri;
}

class NovelJumpToken extends NovelMarkupToken {
  NovelJumpToken({
    required this.label,
    required this.targetText,
    required this.target,
    required super.rawName,
    required super.rawText,
    required super.sourceOffset,
    this.error,
    super.attributes,
  });

  final String label;
  final String targetText;
  final NovelJumpTarget? target;
  final String? error;

  bool get isValid => target != null && error == null;

  /// A page jump without a label shows nothing of its own: the reader
  /// lays out a label in the reader's language at its place.
  @override
  String get displayText => switch (target) {
    _ when !isValid => rawText,
    _ when label.isNotEmpty => label,
    NovelPageJumpTarget() => '',
    _ => targetText,
  };

  /// This jump, now invalid with [error]: it reads as written.
  NovelJumpToken invalidated(String error) => NovelJumpToken(
    label: label,
    targetText: targetText,
    target: null,
    rawName: rawName,
    rawText: rawText,
    sourceOffset: sourceOffset,
    error: error,
    attributes: attributes,
  );

  @override
  bool get isUnsupported => !isValid;
}

enum NovelImageSource { pixiv, uploaded }

/// An uploaded image's URLs: the reader's size (`1200x1200`) and the file
/// as uploaded. Either is the other when the payload has only one.
typedef NovelUploadedImage = ({String large, String original});

/// A validated image identifier, not a URL. Resolving it into a request stays
/// with the shared Pixiv image/network policy and is deliberately separate
/// from markup parsing.
@immutable
class NovelImageLoadRequest {
  const NovelImageLoadRequest({
    required this.source,
    required this.identifier,
    this.illustId,
    this.page,
  });

  final NovelImageSource source;

  /// The payload's key: an uploaded image's id; a Pixiv work's `id`, or
  /// `id-page` for one page of a set.
  final String identifier;

  /// A Pixiv work's id, and the page the marker names (1 for the first),
  /// null when it names none.
  final int? illustId;
  final int? page;

  @override
  bool operator ==(Object other) =>
      other is NovelImageLoadRequest &&
      other.source == source &&
      other.identifier == identifier;

  @override
  int get hashCode => Object.hash(source, identifier);

  @override
  String toString() => 'NovelImageLoadRequest(${source.name}, $identifier)';
}

class NovelPixivImageToken extends NovelMarkupToken {
  NovelPixivImageToken({
    required this.identifier,
    required this.illustId,
    this.page,
    required super.rawText,
    required super.sourceOffset,
    this.error,
    super.attributes,
  }) : super(rawName: 'pixivimage');

  final String identifier;
  final int? illustId;

  /// The page of a set the marker names (`[pixivimage:id-page]`, 1 for the
  /// first), or null.
  final int? page;
  final String? error;

  bool get isValid => illustId != null && error == null;

  NovelImageLoadRequest? get loadRequest => isValid
      ? NovelImageLoadRequest(
          source: NovelImageSource.pixiv,
          identifier: identifier,
          illustId: illustId,
          page: page,
        )
      : null;

  @override
  String get displayText => isValid ? '' : rawText;

  @override
  bool get isUnsupported => !isValid;
}

class NovelUploadedImageToken extends NovelMarkupToken {
  NovelUploadedImageToken({
    required this.identifier,
    required super.rawText,
    required super.sourceOffset,
    this.error,
    super.attributes,
  }) : super(rawName: 'uploadedimage');

  final String identifier;
  final String? error;

  bool get isValid => error == null;

  NovelImageLoadRequest? get loadRequest => isValid
      ? NovelImageLoadRequest(
          source: NovelImageSource.uploaded,
          identifier: identifier,
        )
      : null;

  @override
  String get displayText => isValid ? '' : rawText;

  @override
  bool get isUnsupported => !isValid;
}

class NovelUnknownToken extends NovelMarkupToken {
  NovelUnknownToken({
    required super.rawName,
    required this.payload,
    required super.rawText,
    required super.sourceOffset,
    this.isMalformed = false,
    super.attributes,
  });

  final String payload;
  final bool isMalformed;

  @override
  bool get isUnsupported => true;
}

class NovelBudgetExceededToken extends NovelMarkupToken {
  NovelBudgetExceededToken({
    required this.reason,
    required super.rawText,
    required super.sourceOffset,
    super.attributes,
  }) : super(rawName: 'budget_exceeded');

  final String reason;

  @override
  bool get isUnsupported => true;
}

enum NovelMarkupIssueKind {
  unknown,
  malformed,
  invalidRuby,
  invalidJump,
  invalidImage,
  budgetExceeded,
}

@immutable
class NovelMarkupDiagnostic {
  const NovelMarkupDiagnostic({
    required this.kind,
    required this.message,
    required this.sourceOffset,
    required this.rawName,
  });

  final NovelMarkupIssueKind kind;
  final String message;
  final int sourceOffset;
  final String rawName;
}

@immutable
class NovelMarkupBudget {
  const NovelMarkupBudget({
    this.maxSourceUnits = 2 * 1024 * 1024,
    this.maxTokens = 100000,
    this.chunkSize = 256,
    this.maxDiagnostics = 64,
    this.maxMarkerUnits = 16384,
  }) : assert(maxSourceUnits > 0),
       assert(maxTokens > 1),
       assert(chunkSize > 0),
       assert(maxDiagnostics > 0),
       assert(maxMarkerUnits > 4);

  final int maxSourceUnits;
  final int maxTokens;
  final int chunkSize;
  final int maxDiagnostics;
  final int maxMarkerUnits;
}

@immutable
class NovelMarkupProgress {
  const NovelMarkupProgress({
    required this.processedUnits,
    required this.totalUnits,
    required this.tokenCount,
    required this.chunkIndex,
    required this.isComplete,
    this.budgetExceeded = false,
  });

  final int processedUnits;
  final int totalUnits;
  final int tokenCount;
  final int chunkIndex;
  final bool isComplete;
  final bool budgetExceeded;

  double get fraction {
    if (totalUnits <= 0) return isComplete ? 1 : 0;
    return (processedUnits / totalUnits).clamp(0.0, 1.0);
  }

  double get progress => fraction;
}

typedef NovelMarkupProgressCallback = void Function(NovelMarkupProgress);

@immutable
class NovelMarkupParseResult {
  const NovelMarkupParseResult({
    required this.document,
    required this.progress,
  });

  final NovelMarkupDocument document;
  final NovelMarkupProgress progress;
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
    this.tokens = const [],
    this.pageBreakBefore = false,
    this.isChapterHeading = false,
    this.image,
  });

  @override
  final String id;
  final String text;
  final List<NovelInlineMark> inlineMarks;
  final List<NovelMarkupToken> tokens;
  final bool pageBreakBefore;
  final bool isChapterHeading;

  /// The illustration this empty paragraph stands for in a layout
  /// ([NovelImageBlock]).
  final NovelImageLoadRequest? image;

  @override
  String get plainText => text;
}

class NovelPageBreakBlock extends NovelBlock {
  const NovelPageBreakBlock({required this.id, required this.token});

  @override
  final String id;
  final NovelNewPageToken token;

  @override
  String get plainText => '';
}

/// An illustration on a page of its own (`[uploadedimage:…]`,
/// `[pixivimage:…]`) whose URL the novel's payload resolves. Its id is the
/// paragraph id its marker line had as text, so the paragraphs after it
/// keep theirs.
class NovelImageBlock extends NovelBlock {
  const NovelImageBlock({required this.id, required this.image});

  @override
  final String id;
  final NovelImageLoadRequest image;

  @override
  String get plainText => '';
}

class NovelChapterBlock extends NovelBlock {
  const NovelChapterBlock({required this.id, required this.token});

  @override
  final String id;
  final NovelChapterToken token;

  String get title => token.title;

  @override
  String get plainText => title;
}

/// Immutable AST produced by [NovelMarkupParser]. The block list preserves
/// page/chapter boundaries while [paragraphs] remains available to existing
/// feeds and history code.
@immutable
class NovelMarkupDocument {
  NovelMarkupDocument({
    required List<NovelMarkupToken> tokens,
    required List<NovelBlock> blocks,
    required List<NovelMarkupDiagnostic> diagnostics,
    required this.sourceLength,
    required this.budgetExceeded,
  }) : tokens = List.unmodifiable(tokens),
       blocks = List.unmodifiable(blocks),
       diagnostics = List.unmodifiable(diagnostics),
       paragraphs = List.unmodifiable(blocks.whereType<NovelParagraph>());

  final List<NovelMarkupToken> tokens;
  final List<NovelBlock> blocks;
  final List<NovelParagraph> paragraphs;
  final List<NovelMarkupDiagnostic> diagnostics;
  final int sourceLength;
  final bool budgetExceeded;

  List<NovelMarkupToken> get unsupportedTokens =>
      List.unmodifiable(tokens.where((token) => token.isUnsupported));

  List<NovelImageLoadRequest> get imageRequests => [
    for (final token in tokens)
      if (token is NovelPixivImageToken && token.loadRequest != null)
        token.loadRequest!,
    for (final token in tokens)
      if (token is NovelUploadedImageToken && token.loadRequest != null)
        token.loadRequest!,
  ];

  bool get hasUnsupportedTokens => unsupportedTokens.isNotEmpty;

  String get plainText => blocks.map((block) => block.plainText).join('\n');

  /// The id of each Pixiv page's first block, page 1 first. The author's
  /// `[newpage]` markers split a body into Pixiv pages, which page jumps
  /// and the account's bookmark count in; a chapter does not start one.
  /// A page left empty between two markers starts where the next does.
  late final List<String> pixivPageStarts = pixivPageStartsOf(blocks);

  late final Map<String, int> _pixivPages = () {
    final pages = <String, int>{};
    var page = 1;
    for (final block in blocks) {
      if (block is NovelPageBreakBlock) {
        page++;
      } else {
        pages[block.id] = page;
      }
    }
    return pages;
  }();

  /// The Pixiv page (1-based) of the block with [blockId], or null.
  int? pixivPageOf(String blockId) => _pixivPages[blockId];

  static List<String> pixivPageStartsOf(List<NovelBlock> blocks) {
    final starts = <String>[];
    var open = 1;
    for (final block in blocks) {
      if (block is NovelPageBreakBlock) {
        open++;
        continue;
      }
      while (starts.length < open) {
        starts.add(block.id);
      }
    }
    return List.unmodifiable(starts);
  }

  factory NovelMarkupDocument.fromParagraphs(List<NovelParagraph> paragraphs) {
    return NovelMarkupDocument(
      tokens: [
        for (final paragraph in paragraphs)
          if (paragraph.tokens.isNotEmpty)
            ...paragraph.tokens
          else
            NovelTextToken(paragraph.text),
      ],
      blocks: paragraphs,
      diagnostics: const [],
      sourceLength: paragraphs.fold<int>(
        0,
        (total, paragraph) => total + paragraph.text.length + 1,
      ),
      budgetExceeded: false,
    );
  }
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
    this.markup,
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
    this.embeddedImages = const {},
    this.embeddedIllustThumbs = const {},
    this.seriesPrevId,
    this.seriesNextId,
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
  final NovelMarkupDocument? markup;
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

  /// `uploadedimage` identifier → its URLs in the webview payload.
  final Map<String, NovelUploadedImage> embeddedImages;

  /// `pixivimage` identifier → preview URL resolved from the webview
  /// payload's `illusts` map.
  final Map<String, String> embeddedIllustThumbs;

  /// Adjacent series entries reported by the webview payload. Fallback
  /// navigation for novels whose `seriesId` is absent.
  final int? seriesPrevId;
  final int? seriesNextId;

  UserEntity get author => user;

  /// An uploaded image's URLs in the webview payload, or null.
  NovelUploadedImage? uploadedImage(NovelImageLoadRequest image) =>
      embeddedImages[image.identifier];

  /// The payload's preview of a Pixiv work's page, or null. A page is keyed
  /// `id-page`; a marker naming the work alone, or a payload keying it so,
  /// finds it by `id`.
  String? illustThumb(NovelImageLoadRequest image) =>
      embeddedIllustThumbs[image.identifier] ??
      embeddedIllustThumbs['${image.illustId}'];

  bool get isRestricted => !visible || isXRestricted;

  String get plainText =>
      markup?.plainText ??
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
    Object? markup = _unset,
    Object? isBookmarked = _unset,
    Object? visible = _unset,
    Object? contentAvailable = _unset,
    Object? embeddedImages = _unset,
    Object? embeddedIllustThumbs = _unset,
    Object? seriesPrevId = _unset,
    Object? seriesNextId = _unset,
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
      markup: identical(markup, _unset)
          ? this.markup
          : markup as NovelMarkupDocument?,
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
      embeddedImages: identical(embeddedImages, _unset)
          ? this.embeddedImages
          : embeddedImages as Map<String, NovelUploadedImage>,
      embeddedIllustThumbs: identical(embeddedIllustThumbs, _unset)
          ? this.embeddedIllustThumbs
          : embeddedIllustThumbs as Map<String, String>,
      seriesPrevId: identical(seriesPrevId, _unset)
          ? this.seriesPrevId
          : seriesPrevId as int?,
      seriesNextId: identical(seriesNextId, _unset)
          ? this.seriesNextId
          : seriesNextId as int?,
    );
  }

  static const _unset = Object();

  /// Merges the body resolved from `/webview/v2/novel` into a metadata entity.
  ///
  /// `/v2/novel/detail` never carries `novel_text`; the webview page's
  /// embedded pixiv object is the only source. A null [text] keeps the
  /// entity metadata-only while still recording navigation/image fields.
  NovelEntity withWebContent(
    String? text, {
    Map<String, NovelUploadedImage> embeddedImages = const {},
    Map<String, String> embeddedIllustThumbs = const {},
    int? seriesPrevId,
    int? seriesNextId,
  }) {
    if (text == null) {
      return copyWith(
        embeddedImages: Map<String, NovelUploadedImage>.unmodifiable(
          embeddedImages,
        ),
        embeddedIllustThumbs: Map<String, String>.unmodifiable(
          embeddedIllustThumbs,
        ),
        seriesPrevId: seriesPrevId,
        seriesNextId: seriesNextId,
      );
    }
    final markup = NovelContentMapper.parse(text, images: true);
    final paragraphs = markup.paragraphs;
    final version = sha256.convert(utf8.encode(jsonEncode(text))).toString();
    return copyWith(
      // Keep the API `text_length` when present — it is pixiv's official
      // count (and what list rows already show). The parsed-paragraph sum
      // excludes markup and would silently change the number on reopen.
      textLength: textLength == 0
          ? paragraphs.fold<int>(0, (total, item) => total + item.text.length)
          : textLength,
      contentVersion: version,
      paragraphs: List<NovelParagraph>.unmodifiable(paragraphs),
      markup: markup,
      contentAvailable: true,
      embeddedImages: Map<String, NovelUploadedImage>.unmodifiable(
        embeddedImages,
      ),
      embeddedIllustThumbs: Map<String, String>.unmodifiable(
        embeddedIllustThumbs,
      ),
      seriesPrevId: seriesPrevId,
      seriesNextId: seriesNextId,
    );
  }

  /// Parses either a list/detail novel object.  The parser never accepts an
  /// HTML body; only JSON `content` or a structured JSON content list is used.
  factory NovelEntity.fromJson(Map<String, dynamic> json) {
    final id = requireParsedPositiveInt(json['id'], 'novel.id');
    final title = requireString(json['title'], 'novel.title');
    final userJson = json['user'];
    if (userJson is! Map<String, dynamic>) {
      throw const FormatException('novel.user is missing or malformed');
    }
    final user = UserEntity.fromUserJson(userJson);
    final rawContent = json.containsKey('content')
        ? json['content']
        : json['novel_text'];
    final contentAvailable = rawContent is String || rawContent is List;
    final markup = contentAvailable
        ? NovelContentMapper.parse(rawContent)
        : null;
    final paragraphs = markup?.paragraphs ?? const <NovelParagraph>[];
    final series = readMap(json['series']);
    final imageUrls = readMap(json['image_urls']);
    final contentSeed = rawContent == null
        ? 'metadata:$id:${json['text_length'] ?? 0}'
        : jsonEncode(rawContent);
    final contentVersion = sha256.convert(utf8.encode(contentSeed)).toString();
    final apiTextLength = readNonNegativeIntOrZero(json['text_length']);

    return NovelEntity(
      id: id,
      title: title,
      caption: readOptionalString(json['caption']) ?? '',
      user: user,
      tags: _tags(json['tags']),
      textLength: apiTextLength == 0 && contentAvailable
          ? paragraphs.fold<int>(0, (total, item) => total + item.text.length)
          : apiTextLength,
      contentVersion: contentVersion,
      paragraphs: List.unmodifiable(paragraphs),
      seriesId: readPositiveInt(series['id']),
      seriesTitle: readOptionalString(series['title']),
      coverImageUrl: readFirstString(imageUrls, const [
        'medium',
        'large',
        'square_medium',
      ]),
      markup: markup,
      restrict: readNonNegativeIntOrZero(json['restrict']),
      xRestrict: readNonNegativeIntOrZero(json['x_restrict']),
      isOriginal: json['is_original'] == true,
      isBookmarked: json['is_bookmarked'] == true,
      totalBookmarks: readNonNegativeIntOrZero(json['total_bookmarks']),
      totalView: readNonNegativeIntOrZero(json['total_view']),
      totalComments: readNonNegativeIntOrZero(json['total_comments']),
      visible: json['visible'] is! bool || json['visible'] == true,
      isMuted: json['is_muted'] == true,
      isMyPixivOnly: json['is_mypixiv_only'] == true,
      isXRestricted: json['is_x_restricted'] == true,
      novelAiType: readNonNegativeIntOrZero(json['novel_ai_type']),
      createDate: readOptionalString(json['create_date']),
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
  static NovelMarkupDocument parse(
    Object? raw, {
    NovelMarkupBudget budget = const NovelMarkupBudget(),
    NovelMarkupProgressCallback? onProgress,
    bool images = false,
  }) {
    final parser = NovelMarkupParser(budget: budget, images: images);
    if (raw is String) {
      return parser.parse(raw, onProgress: onProgress);
    }
    if (raw is! List) {
      throw const FormatException('novel content is not JSON text or a list');
    }
    final source = StringBuffer();
    var hasMoreItems = false;
    for (var index = 0; index < raw.length; index++) {
      if (source.length >= budget.maxSourceUnits) {
        hasMoreItems = true;
        break;
      }
      final item = raw[index];
      String? part;
      if (item is String) {
        part = item;
      } else if (item is Map<String, dynamic>) {
        final text = item['text'] ?? item['content'];
        if (text is String) {
          part = text;
        }
      }
      if (part == null) {
        // Preserve an unknown JSON block visibly rather than dropping content
        // or pretending it was successfully rendered. The fallback is bounded
        // because the body parser owns a finite source budget.
        final encoded = jsonEncode(item);
        part = encoded.length <= budget.maxMarkerUnits
            ? encoded
            : '${encoded.substring(0, budget.maxMarkerUnits)}…';
      }
      if (index > 0) source.write('\n');
      final remaining = budget.maxSourceUnits - source.length;
      if (part.length > remaining) {
        source.write(part.substring(0, remaining));
        hasMoreItems = true;
        break;
      }
      source.write(part);
      hasMoreItems = index + 1 < raw.length;
    }
    if (hasMoreItems && source.length < budget.maxSourceUnits) {
      source.write('\n');
    }
    return parser.parse(source.toString(), onProgress: onProgress);
  }

  static List<NovelParagraph> fromRaw(Object? raw) => parse(raw).paragraphs;

  static List<NovelParagraph> fromText(String raw) => parse(raw).paragraphs;
}

class NovelMarkupParser {
  const NovelMarkupParser({
    this.budget = const NovelMarkupBudget(),
    this.images = false,
  });

  final NovelMarkupBudget budget;

  /// Whether valid image markers become image blocks: a pixiv body's do,
  /// whatever its payload holds (one that cannot be shown says so on its
  /// page). Off, they stay visible text, as in a local file.
  final bool images;

  /// The single-bracket markers that carry a payload, up to their `]`.
  static const _payloadMarkers = [
    '[chapter:',
    '[jump:',
    '[uploadedimage:',
    '[pixivimage:',
  ];

  static final _pixivImageIdentifier = RegExp(r'^(\d{1,18})(?:-(\d{1,4}))?$');

  NovelMarkupDocument parse(
    String source, {
    CancelToken? cancelToken,
    NovelMarkupProgressCallback? onProgress,
  }) {
    final scanned = _scanSync(
      source,
      cancelToken: cancelToken,
      onProgress: onProgress,
    );
    return _buildDocument(source.length, scanned);
  }

  Future<NovelMarkupParseResult> parseCancellable(
    String source, {
    CancelToken? cancelToken,
    NovelMarkupProgressCallback? onProgress,
  }) async {
    final scanned = await _scanAsync(
      source,
      cancelToken: cancelToken,
      onProgress: onProgress,
    );
    final document = _buildDocument(source.length, scanned);
    final progress = NovelMarkupProgress(
      processedUnits: scanned.processedUnits,
      totalUnits: source.length,
      tokenCount: scanned.tokens.length,
      chunkIndex: scanned.chunkIndex,
      isComplete: true,
      budgetExceeded: scanned.budgetExceeded,
    );
    return NovelMarkupParseResult(document: document, progress: progress);
  }

  Future<NovelMarkupDocument> parseAsync(
    String source, {
    CancelToken? cancelToken,
    NovelMarkupProgressCallback? onProgress,
  }) async => (await parseCancellable(
    source,
    cancelToken: cancelToken,
    onProgress: onProgress,
  )).document;

  _NovelScanResult _scanSync(
    String source, {
    required CancelToken? cancelToken,
    required NovelMarkupProgressCallback? onProgress,
  }) {
    final accumulator = _NovelScanAccumulator(budget.maxDiagnostics);
    final tokens = <NovelMarkupToken>[];
    final sourceLimit = source.length.clamp(0, budget.maxSourceUnits);
    final regularTokenLimit = budget.maxTokens - 1;
    var cursor = 0;
    var chunkUnits = 0;
    var chunkIndex = 0;
    var budgetExceeded = source.length > sourceLimit;

    while (cursor < sourceLimit && tokens.length < regularTokenLimit) {
      _checkCancelled(cancelToken);
      final scanned = _scanOne(source, cursor, sourceLimit, accumulator);
      tokens.add(scanned.token);
      final consumed = scanned.end - cursor;
      cursor = scanned.end;
      chunkUnits += consumed;
      if (chunkUnits >= budget.chunkSize) {
        chunkIndex++;
        _report(
          onProgress,
          NovelMarkupProgress(
            processedUnits: cursor,
            totalUnits: source.length,
            tokenCount: tokens.length,
            chunkIndex: chunkIndex,
            isComplete: false,
            budgetExceeded: budgetExceeded,
          ),
        );
        chunkUnits = 0;
      }
    }

    if (cursor < sourceLimit) {
      budgetExceeded = true;
    }
    if (budgetExceeded) {
      _appendBudgetToken(
        tokens,
        sourceOffset: cursor,
        reason: source.length > sourceLimit
            ? 'source exceeds maxSourceUnits'
            : 'token count exceeds maxTokens',
        maxTokens: budget.maxTokens,
        accumulator: accumulator,
      );
    }
    chunkIndex++;
    _report(
      onProgress,
      NovelMarkupProgress(
        processedUnits: cursor,
        totalUnits: source.length,
        tokenCount: tokens.length,
        chunkIndex: chunkIndex,
        isComplete: true,
        budgetExceeded: budgetExceeded,
      ),
    );
    return _NovelScanResult(
      tokens: tokens,
      diagnostics: accumulator.diagnostics,
      processedUnits: cursor,
      chunkIndex: chunkIndex,
      budgetExceeded: budgetExceeded,
    );
  }

  Future<_NovelScanResult> _scanAsync(
    String source, {
    required CancelToken? cancelToken,
    required NovelMarkupProgressCallback? onProgress,
  }) async {
    final accumulator = _NovelScanAccumulator(budget.maxDiagnostics);
    final tokens = <NovelMarkupToken>[];
    final sourceLimit = source.length.clamp(0, budget.maxSourceUnits);
    final regularTokenLimit = budget.maxTokens - 1;
    var cursor = 0;
    var chunkUnits = 0;
    var chunkIndex = 0;
    var budgetExceeded = source.length > sourceLimit;

    while (cursor < sourceLimit && tokens.length < regularTokenLimit) {
      _checkCancelled(cancelToken);
      final scanned = _scanOne(source, cursor, sourceLimit, accumulator);
      tokens.add(scanned.token);
      final consumed = scanned.end - cursor;
      cursor = scanned.end;
      chunkUnits += consumed;
      if (chunkUnits >= budget.chunkSize) {
        chunkIndex++;
        _report(
          onProgress,
          NovelMarkupProgress(
            processedUnits: cursor,
            totalUnits: source.length,
            tokenCount: tokens.length,
            chunkIndex: chunkIndex,
            isComplete: false,
            budgetExceeded: budgetExceeded,
          ),
        );
        chunkUnits = 0;
        await Future<void>.delayed(Duration.zero);
      }
    }
    _checkCancelled(cancelToken);

    if (cursor < sourceLimit) {
      budgetExceeded = true;
    }
    if (budgetExceeded) {
      _appendBudgetToken(
        tokens,
        sourceOffset: cursor,
        reason: source.length > sourceLimit
            ? 'source exceeds maxSourceUnits'
            : 'token count exceeds maxTokens',
        maxTokens: budget.maxTokens,
        accumulator: accumulator,
      );
    }
    chunkIndex++;
    _report(
      onProgress,
      NovelMarkupProgress(
        processedUnits: cursor,
        totalUnits: source.length,
        tokenCount: tokens.length,
        chunkIndex: chunkIndex,
        isComplete: true,
        budgetExceeded: budgetExceeded,
      ),
    );
    return _NovelScanResult(
      tokens: tokens,
      diagnostics: accumulator.diagnostics,
      processedUnits: cursor,
      chunkIndex: chunkIndex,
      budgetExceeded: budgetExceeded,
    );
  }

  _ScannedNovelToken _scanOne(
    String source,
    int cursor,
    int sourceLimit,
    _NovelScanAccumulator accumulator,
  ) {
    final singleEnd = _singleMarkerEnd(
      source,
      cursor,
      sourceLimit,
      accumulator,
    );
    if (singleEnd != null) {
      return _ScannedNovelToken(
        token: _parseMarker(
          source.substring(cursor, singleEnd),
          source.substring(cursor + 1, singleEnd - 1),
          cursor,
          accumulator,
        ),
        end: singleEnd,
      );
    }
    if (!source.startsWith('[[', cursor)) {
      // A text token never passes the chunk, so a marker past it is moot.
      final window = math.min(sourceLimit, cursor + budget.chunkSize);
      final marker = _nextMarker(
        source,
        cursor,
        window,
        sourceLimit,
        accumulator,
      );
      final end = (marker ?? window).clamp(cursor + 1, window);
      return _ScannedNovelToken(
        token: NovelTextToken(
          source.substring(cursor, end),
          sourceOffset: cursor,
        ),
        end: end,
      );
    }

    final markerEnd = _findMarkerEnd(source, cursor, sourceLimit);
    if (markerEnd == null) {
      final raw = source.substring(cursor, sourceLimit);
      accumulator.add(
        kind: NovelMarkupIssueKind.malformed,
        message: 'unterminated novel marker',
        sourceOffset: cursor,
        rawName: 'malformed',
      );
      return _ScannedNovelToken(
        token: NovelUnknownToken(
          rawName: 'malformed',
          payload: raw,
          rawText: raw,
          sourceOffset: cursor,
          isMalformed: true,
          attributes: {'payload': raw, 'reason': 'unterminated'},
        ),
        end: sourceLimit,
      );
    }
    final raw = source.substring(cursor, markerEnd);
    if (raw.length > budget.maxMarkerUnits) {
      accumulator.add(
        kind: NovelMarkupIssueKind.budgetExceeded,
        message: 'novel marker exceeds maxMarkerUnits',
        sourceOffset: cursor,
        rawName: 'budget_exceeded',
      );
      return _ScannedNovelToken(
        token: NovelUnknownToken(
          rawName: 'oversized_marker',
          payload: raw.substring(0, budget.maxMarkerUnits),
          rawText: raw.substring(0, budget.maxMarkerUnits),
          sourceOffset: cursor,
          isMalformed: true,
          attributes: {
            'payload': raw.substring(0, budget.maxMarkerUnits),
            'truncated': 'true',
          },
        ),
        end: markerEnd,
      );
    }
    return _ScannedNovelToken(
      token: _parseMarker(
        raw,
        source.substring(cursor + 2, markerEnd - 2),
        cursor,
        accumulator,
      ),
      end: markerEnd,
    );
  }

  NovelMarkupToken _parseMarker(
    String raw,
    String content,
    int sourceOffset,
    _NovelScanAccumulator accumulator,
  ) {
    final colon = content.indexOf(':');
    if (colon < 0) {
      if (content.trim().toLowerCase() == 'newpage') {
        return NovelNewPageToken(
          rawText: raw,
          sourceOffset: sourceOffset,
          attributes: const {'payload': ''},
        );
      }
      return _unknown(
        rawName: content.trim().isEmpty ? 'malformed' : content.trim(),
        payload: '',
        rawText: raw,
        sourceOffset: sourceOffset,
        isMalformed: true,
        accumulator: accumulator,
        message: 'novel marker is missing a colon payload',
      );
    }
    final rawName = content.substring(0, colon).trim();
    final payload = content.substring(colon + 1);
    if (rawName.isEmpty) {
      return _unknown(
        rawName: 'malformed',
        payload: payload,
        rawText: raw,
        sourceOffset: sourceOffset,
        isMalformed: true,
        accumulator: accumulator,
        message: 'novel marker name is empty',
      );
    }
    final name = rawName.toLowerCase();
    final attributes = _attributes(payload);
    switch (name) {
      case 'newpage':
        if (payload.isNotEmpty) {
          return _unknown(
            rawName: rawName,
            payload: payload,
            rawText: raw,
            sourceOffset: sourceOffset,
            isMalformed: true,
            accumulator: accumulator,
            message: 'newpage does not accept a payload',
          );
        }
        return NovelNewPageToken(
          rawText: raw,
          sourceOffset: sourceOffset,
          attributes: attributes,
        );
      case 'chapter':
        if (payload.trim().isEmpty || payload.contains('[[')) {
          return _unknown(
            rawName: rawName,
            payload: payload,
            rawText: raw,
            sourceOffset: sourceOffset,
            isMalformed: true,
            accumulator: accumulator,
            message: 'chapter title is malformed',
          );
        }
        return NovelChapterToken(
          title: payload.trim(),
          rawText: raw,
          sourceOffset: sourceOffset,
          attributes: {...attributes, 'title': payload.trim()},
        );
      case 'rb':
        final pair = _splitLabelTarget(payload);
        if (pair == null || pair.$1.isEmpty || pair.$2.isEmpty) {
          accumulator.add(
            kind: NovelMarkupIssueKind.invalidRuby,
            message: 'ruby marker requires base > annotation',
            sourceOffset: sourceOffset,
            rawName: rawName,
          );
          return NovelRubyToken(
            baseText: payload,
            annotation: '',
            rawText: raw,
            sourceOffset: sourceOffset,
            error: 'ruby marker requires base > annotation',
            attributes: attributes,
          );
        }
        return NovelRubyToken(
          baseText: pair.$1,
          annotation: pair.$2,
          rawText: raw,
          sourceOffset: sourceOffset,
          attributes: {...attributes, 'base': pair.$1, 'annotation': pair.$2},
        );
      case 'jump':
        return _jumpToken(
          rawName: rawName,
          rawText: raw,
          payload: payload,
          sourceOffset: sourceOffset,
          accumulator: accumulator,
          attributes: attributes,
          allowPage: true,
        );
      case 'jumpuri':
      case 'jumpurl':
        return _jumpToken(
          rawName: rawName,
          rawText: raw,
          payload: payload,
          sourceOffset: sourceOffset,
          accumulator: accumulator,
          attributes: attributes,
          allowPage: false,
        );
      case 'pixivimage':
        // A work, or one page of a set: `id` or `id-page`.
        final identifier = payload.trim();
        final match = _pixivImageIdentifier.firstMatch(identifier);
        final id = match == null ? null : int.tryParse(match[1]!);
        final page = match?[2] == null ? null : int.tryParse(match![2]!);
        if (id == null || id <= 0 || (page != null && page <= 0)) {
          accumulator.add(
            kind: NovelMarkupIssueKind.invalidImage,
            message: 'pixivimage requires a work id and an optional page',
            sourceOffset: sourceOffset,
            rawName: rawName,
          );
          return NovelPixivImageToken(
            identifier: identifier,
            illustId: null,
            rawText: raw,
            sourceOffset: sourceOffset,
            error: 'invalid Pixiv image identifier',
            attributes: attributes,
          );
        }
        return NovelPixivImageToken(
          identifier: identifier,
          illustId: id,
          page: page,
          rawText: raw,
          sourceOffset: sourceOffset,
          attributes: attributes,
        );
      case 'uploadedimage':
        final identifier = payload.trim();
        final valid = RegExp(
          r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$',
        ).hasMatch(identifier);
        if (!valid) {
          accumulator.add(
            kind: NovelMarkupIssueKind.invalidImage,
            message: 'uploadedimage identifier is not allowlisted',
            sourceOffset: sourceOffset,
            rawName: rawName,
          );
        }
        return NovelUploadedImageToken(
          identifier: identifier,
          rawText: raw,
          sourceOffset: sourceOffset,
          error: valid ? null : 'invalid uploaded image identifier',
          attributes: attributes,
        );
      default:
        return _unknown(
          rawName: rawName,
          payload: payload,
          rawText: raw,
          sourceOffset: sourceOffset,
          isMalformed: content.contains('[['),
          accumulator: accumulator,
          message: content.contains('[[')
              ? 'nested novel marker is unsupported'
              : 'novel marker is not supported',
          attributes: attributes,
        );
    }
  }

  NovelJumpToken _jumpToken({
    required String rawName,
    required String rawText,
    required String payload,
    required int sourceOffset,
    required _NovelScanAccumulator accumulator,
    required Map<String, String> attributes,
    required bool allowPage,
  }) {
    final pair = _splitLabelTarget(payload);
    final label = pair?.$1 ?? '';
    final targetText = (pair?.$2 ?? payload).trim();
    NovelJumpTarget? target;
    String? error;
    final page = int.tryParse(targetText);
    if (allowPage && page != null && page > 0 && '$page' == targetText) {
      target = NovelPageJumpTarget(page);
    } else {
      final uri = Uri.tryParse(targetText);
      final destination = uri == null
          ? null
          : PixivDestinationRegistry().resolve(
              uri,
              PixivDestinationPurpose.pixivWeb,
            );
      if (destination != null) {
        target = NovelUriJumpTarget(destination.uri);
      } else {
        error = allowPage
            ? 'jump target must be a positive page or allowlisted Pixiv URI'
            : 'jump target must be an allowlisted Pixiv URI';
      }
    }
    if (target == null) {
      accumulator.add(
        kind: NovelMarkupIssueKind.invalidJump,
        message: error!,
        sourceOffset: sourceOffset,
        rawName: rawName,
      );
    }
    return NovelJumpToken(
      label: label,
      targetText: targetText,
      target: target,
      rawName: rawName,
      rawText: rawText,
      sourceOffset: sourceOffset,
      error: error,
      attributes: {...attributes, 'label': label, 'target': targetText},
    );
  }

  NovelUnknownToken _unknown({
    required String rawName,
    required String payload,
    required String rawText,
    required int sourceOffset,
    required bool isMalformed,
    required _NovelScanAccumulator accumulator,
    required String message,
    Map<String, String>? attributes,
  }) {
    accumulator.add(
      kind: isMalformed
          ? NovelMarkupIssueKind.malformed
          : NovelMarkupIssueKind.unknown,
      message: message,
      sourceOffset: sourceOffset,
      rawName: rawName,
    );
    return NovelUnknownToken(
      rawName: rawName,
      payload: payload,
      rawText: rawText,
      sourceOffset: sourceOffset,
      isMalformed: isMalformed,
      attributes: attributes ?? _attributes(payload),
    );
  }

  static Map<String, String> _attributes(String payload) =>
      Map.unmodifiable({'payload': payload});

  static (String, String)? _splitLabelTarget(String payload) {
    final separator = payload.indexOf(' > ');
    if (separator < 0) return null;
    return (
      payload.substring(0, separator).trim(),
      payload.substring(separator + 3).trim(),
    );
  }

  /// The first marker start in `[from, window)`: a `[[` or a single-bracket
  /// marker.
  int? _nextMarker(
    String source,
    int from,
    int window,
    int limit,
    _NovelScanAccumulator scan,
  ) {
    var index = source.indexOf('[', from);
    while (index >= 0 && index < window) {
      if (source.startsWith('[[', index) ||
          _singleMarkerEnd(source, index, limit, scan) != null) {
        return index;
      }
      index = source.indexOf('[', index + 1);
    }
    return null;
  }

  /// The end of a single-bracket marker at [start], or null. Pixiv writes
  /// page breaks, chapters, page jumps and images in single brackets
  /// (`[newpage]`, `[chapter:title]`, `[jump:page]`, `[uploadedimage:id]`,
  /// `[pixivimage:id-page]`, closed on the same line); only those exact
  /// names are markers, so bracketed prose (`[注]`, `[1]`) stays text.
  int? _singleMarkerEnd(
    String source,
    int start,
    int limit,
    _NovelScanAccumulator scan,
  ) {
    const newPage = '[newpage]';
    if (source.startsWith(newPage, start)) {
      final end = start + newPage.length;
      return end <= limit ? end : null;
    }
    final prefix = _payloadMarkers
        .where((prefix) => source.startsWith(prefix, start))
        .firstOrNull;
    if (prefix == null) return null;
    final from = start + prefix.length;
    final searchEnd = math.min(limit, start + budget.maxMarkerUnits);
    // A payload inside a stretch an earlier marker already read resumes at
    // its end, so a run of unclosed prefixes reads each unit once.
    final known = scan.payloadStretch;
    final resumes = known != null && from >= known.from && from < known.to;
    final stretchFrom = resumes ? known.from : from;
    var index = resumes ? known.to : from;
    for (; index < searchEnd; index++) {
      switch (source.codeUnitAt(index)) {
        case 0x5D: // ]
          scan.payloadStretch = (from: stretchFrom, to: index);
          return index + 1;
        case 0x0A || 0x0D:
          scan.payloadStretch = (from: stretchFrom, to: index);
          return null;
      }
    }
    scan.payloadStretch = (from: stretchFrom, to: index);
    return null;
  }

  static int? _findMarkerEnd(String source, int start, int limit) {
    var depth = 1;
    var cursor = start + 2;
    while (cursor + 1 < limit) {
      if (source.startsWith('[[', cursor)) {
        depth++;
        cursor += 2;
        continue;
      }
      if (source.startsWith(']]', cursor)) {
        depth--;
        cursor += 2;
        if (depth == 0) return cursor;
        continue;
      }
      cursor++;
    }
    return null;
  }

  static void _appendBudgetToken(
    List<NovelMarkupToken> tokens, {
    required int sourceOffset,
    required String reason,
    required int maxTokens,
    required _NovelScanAccumulator accumulator,
  }) {
    accumulator.add(
      kind: NovelMarkupIssueKind.budgetExceeded,
      message: reason,
      sourceOffset: sourceOffset,
      rawName: 'budget_exceeded',
    );
    final token = NovelBudgetExceededToken(
      reason: reason,
      rawText: '[[unsupported:content budget exceeded]]',
      sourceOffset: sourceOffset,
      attributes: {'reason': reason},
    );
    if (tokens.length < maxTokens) tokens.add(token);
  }

  static void _checkCancelled(CancelToken? cancelToken) {
    if (cancelToken?.isCancelled ?? false) throw const ApiCancelled();
  }

  static void _report(
    NovelMarkupProgressCallback? callback,
    NovelMarkupProgress progress,
  ) {
    callback?.call(progress);
  }

  NovelMarkupDocument _buildDocument(
    int sourceLength,
    _NovelScanResult scanned,
  ) {
    final blocks = <NovelBlock>[];
    final currentTokens = <NovelMarkupToken>[];
    final currentMarks = <NovelInlineMark>[];
    final text = StringBuffer();
    var paragraphIndex = 0;
    var structuralIndex = 0;
    // An image block took its marker line's paragraph: the break ending
    // that line closes the image, not another (empty) paragraph.
    var imageLineOpen = false;

    void flushParagraph({bool force = false}) {
      if (!force && currentTokens.isEmpty && text.isEmpty) return;
      blocks.add(
        NovelParagraph(
          id: 'p$paragraphIndex',
          text: text.toString(),
          inlineMarks: List.unmodifiable(currentMarks),
          tokens: List.unmodifiable(currentTokens),
        ),
      );
      paragraphIndex++;
      currentTokens.clear();
      currentMarks.clear();
      text.clear();
    }

    void appendText(String value, NovelMarkupToken token) {
      final normalized = value.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
      final lines = normalized.split('\n');
      for (var index = 0; index < lines.length; index++) {
        if (lines[index].isNotEmpty) {
          imageLineOpen = false;
          final start = text.length;
          text.write(lines[index]);
          if (token is! NovelTextToken) {
            currentMarks.add(
              _inlineMark(token, start: start, end: text.length),
            );
          }
          currentTokens.add(token);
        }
        if (index + 1 < lines.length) {
          if (imageLineOpen) {
            imageLineOpen = false;
          } else {
            flushParagraph(force: true);
          }
        }
      }
      if (value.isEmpty && token is! NovelTextToken) {
        currentTokens.add(token);
        currentMarks.add(
          _inlineMark(token, start: text.length, end: text.length),
        );
      }
    }

    // A page jump past the body's last Pixiv page goes nowhere: it reads
    // as written, as an invalid marker does.
    final pixivPages = 1 + scanned.tokens.whereType<NovelNewPageToken>().length;
    final diagnostics = [...scanned.diagnostics];
    final tokens = [
      for (final token in scanned.tokens)
        switch (token) {
          NovelJumpToken(target: NovelPageJumpTarget(:final page))
              when page > pixivPages =>
            () {
              const error = 'jump target is past the last page';
              if (diagnostics.length < budget.maxDiagnostics) {
                diagnostics.add(
                  NovelMarkupDiagnostic(
                    kind: NovelMarkupIssueKind.invalidJump,
                    message: error,
                    sourceOffset: token.sourceOffset,
                    rawName: token.rawName,
                  ),
                );
              }
              return token.invalidated(error);
            }(),
          _ => token,
        },
    ];

    for (final token in tokens) {
      switch (token) {
        case NovelTextToken():
          appendText(token.text, token);
        case NovelNewPageToken():
          flushParagraph();
          blocks.add(
            NovelPageBreakBlock(
              id: 'page-break-${structuralIndex++}',
              token: token,
            ),
          );
        case NovelChapterToken():
          flushParagraph();
          blocks.add(
            NovelChapterBlock(id: 'chapter-${structuralIndex++}', token: token),
          );
        case NovelPixivImageToken(:final loadRequest?) ||
                NovelUploadedImageToken(:final loadRequest?)
            when images:
          flushParagraph();
          // The id its marker line had as a paragraph.
          blocks.add(
            NovelImageBlock(id: 'p${paragraphIndex++}', image: loadRequest),
          );
          imageLineOpen = true;
        case NovelPixivImageToken() || NovelUploadedImageToken():
          // A malformed marker, or a body without images: as written.
          appendText(token.rawText, token);
        default:
          appendText(token.displayText, token);
      }
    }
    flushParagraph(
      force: blocks.isEmpty || currentTokens.isNotEmpty || text.isNotEmpty,
    );
    return NovelMarkupDocument(
      tokens: tokens,
      blocks: blocks,
      diagnostics: diagnostics,
      sourceLength: sourceLength,
      budgetExceeded: scanned.budgetExceeded,
    );
  }

  static NovelInlineMark _inlineMark(
    NovelMarkupToken token, {
    required int start,
    required int end,
  }) {
    final value = switch (token) {
      NovelRubyToken(:final annotation) => annotation,
      NovelJumpToken(target: NovelPageJumpTarget(:final page)) => '$page',
      NovelJumpToken(target: NovelUriJumpTarget(:final uri)) => '$uri',
      NovelJumpToken(:final targetText) => targetText,
      NovelPixivImageToken(:final identifier) => identifier,
      NovelUploadedImageToken(:final identifier) => identifier,
      _ => null,
    };
    return NovelInlineMark(
      kind: token.isUnsupported ? 'unknown' : token.rawName.toLowerCase(),
      start: start,
      end: end,
      value: value,
      raw: token.rawText,
    );
  }
}

class _NovelScanAccumulator {
  _NovelScanAccumulator(this.maxDiagnostics);

  final int maxDiagnostics;
  final List<NovelMarkupDiagnostic> diagnostics = [];

  /// The last stretch a single-bracket payload (a chapter title, an image
  /// id) was read across: it holds no `]` and no line break.
  ({int from, int to})? payloadStretch;

  void add({
    required NovelMarkupIssueKind kind,
    required String message,
    required int sourceOffset,
    required String rawName,
  }) {
    if (diagnostics.length >= maxDiagnostics) return;
    diagnostics.add(
      NovelMarkupDiagnostic(
        kind: kind,
        message: message,
        sourceOffset: sourceOffset,
        rawName: rawName,
      ),
    );
  }
}

class _ScannedNovelToken {
  const _ScannedNovelToken({required this.token, required this.end});

  final NovelMarkupToken token;
  final int end;
}

class _NovelScanResult {
  const _NovelScanResult({
    required this.tokens,
    required this.diagnostics,
    required this.processedUnits,
    required this.chunkIndex,
    required this.budgetExceeded,
  });

  final List<NovelMarkupToken> tokens;
  final List<NovelMarkupDiagnostic> diagnostics;
  final int processedUnits;
  final int chunkIndex;
  final bool budgetExceeded;
}

List<NovelTag> _tags(Object? value) {
  if (value is! List) return const [];
  return [
    for (final item in value)
      if (item is Map<String, dynamic> && item['name'] is String)
        NovelTag(
          name: item['name'] as String,
          translatedName: readOptionalString(item['translated_name']),
        ),
  ];
}
