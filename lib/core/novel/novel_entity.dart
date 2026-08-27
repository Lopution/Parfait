import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../network/api_error.dart';
import '../network/compat/network_contracts.dart';
import '../network/pixiv_http_client.dart';
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

  @override
  String get displayText =>
      isValid ? (label.isEmpty ? targetText : label) : rawText;

  @override
  bool get isUnsupported => !isValid;
}

enum NovelImageSource { pixiv, uploaded }

/// A validated image identifier, not a URL. Resolving it into a request stays
/// with the shared Pixiv image/network policy and is deliberately separate
/// from markup parsing.
@immutable
class NovelImageLoadRequest {
  const NovelImageLoadRequest({required this.source, required this.identifier});

  final NovelImageSource source;
  final String identifier;
}

class NovelPixivImageToken extends NovelMarkupToken {
  NovelPixivImageToken({
    required this.identifier,
    required this.illustId,
    required super.rawText,
    required super.sourceOffset,
    this.error,
    super.attributes,
  }) : super(rawName: 'pixivimage');

  final String identifier;
  final int? illustId;
  final String? error;

  bool get isValid => illustId != null && error == null;

  NovelImageLoadRequest? get loadRequest => isValid
      ? NovelImageLoadRequest(
          source: NovelImageSource.pixiv,
          identifier: identifier,
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
  });

  @override
  final String id;
  final String text;
  final List<NovelInlineMark> inlineMarks;
  final List<NovelMarkupToken> tokens;
  final bool pageBreakBefore;
  final bool isChapterHeading;

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

  UserEntity get author => user;

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
    final markup = contentAvailable
        ? NovelContentMapper.parse(rawContent)
        : null;
    final paragraphs = markup?.paragraphs ?? const <NovelParagraph>[];
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
      markup: markup,
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
  static NovelMarkupDocument parse(
    Object? raw, {
    NovelMarkupBudget budget = const NovelMarkupBudget(),
    NovelMarkupProgressCallback? onProgress,
  }) {
    final parser = NovelMarkupParser(budget: budget);
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
  const NovelMarkupParser({this.budget = const NovelMarkupBudget()});

  final NovelMarkupBudget budget;

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
    if (!source.startsWith('[[', cursor)) {
      final marker = source.indexOf('[[', cursor);
      final end = (marker < 0 ? sourceLimit : marker).clamp(
        cursor + 1,
        cursor + budget.chunkSize,
      );
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
        final identifier = payload.trim();
        final id = int.tryParse(identifier);
        if (id == null || id <= 0 || identifier != '$id') {
          accumulator.add(
            kind: NovelMarkupIssueKind.invalidImage,
            message: 'pixivimage requires a positive numeric identifier',
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
          final start = text.length;
          text.write(lines[index]);
          if (token is! NovelTextToken) {
            currentMarks.add(
              _inlineMark(token, start: start, end: text.length),
            );
          }
          currentTokens.add(token);
        }
        if (index + 1 < lines.length) flushParagraph(force: true);
      }
      if (value.isEmpty && token is! NovelTextToken) {
        currentTokens.add(token);
        currentMarks.add(
          _inlineMark(token, start: text.length, end: text.length),
        );
      }
    }

    for (final token in scanned.tokens) {
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
        default:
          appendText(token.displayText, token);
      }
    }
    flushParagraph(
      force: blocks.isEmpty || currentTokens.isNotEmpty || text.isNotEmpty,
    );
    return NovelMarkupDocument(
      tokens: scanned.tokens,
      blocks: blocks,
      diagnostics: scanned.diagnostics,
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
