import 'dart:math' as math;

import 'package:flutter/foundation.dart' show immutable;

import '../../core/novel/novel_entity.dart';

/// Minimum paragraph count before [NovelLayoutEngine] emits a preliminary
/// anchor-window layout ahead of full-book background pagination.
const int novelProgressiveMinParagraphs = 48;

/// Paragraphs shaped before and after the target anchor for the preliminary
/// first-page layout pass.
const int novelPriorityWindowLead = 8;
const int novelPriorityWindowTrail = 24;

/// Resolves the contiguous `[start, end)` paragraph slice around
/// [priorityParagraphId] so the active page can render before full-book layout
/// completes.
({int start, int end}) resolveNovelPriorityWindow({
  required List<NovelParagraph> paragraphs,
  required String? priorityParagraphId,
}) {
  if (paragraphs.isEmpty) return (start: 0, end: 0);
  var target = 0;
  if (priorityParagraphId != null) {
    for (var i = 0; i < paragraphs.length; i++) {
      if (paragraphs[i].id == priorityParagraphId) {
        target = i;
        break;
      }
    }
  }
  final start = math.max(0, target - novelPriorityWindowLead);
  final end = math.min(
    paragraphs.length,
    math.max(
      start + novelPriorityWindowTrail,
      target + novelPriorityWindowTrail,
    ),
  );
  return (start: start, end: end);
}

/// Hard limits for one layout transaction. They make work proportional to a
/// caller-provided finite budget instead of allowing a malformed/huge novel
/// to create unbounded line and page state.
@immutable
class NovelLayoutBudget {
  const NovelLayoutBudget({
    this.maxParagraphs = 100000,
    this.maxTextUnits = 4 * 1024 * 1024,
    this.maxLines = 200000,
    this.maxPages = 100000,
    this.chunkParagraphs = 8,
  }) : assert(maxParagraphs > 0),
       assert(maxTextUnits > 0),
       assert(maxLines > 0),
       assert(maxPages > 0),
       assert(chunkParagraphs > 0);

  final int maxParagraphs;
  final int maxTextUnits;
  final int maxLines;
  final int maxPages;
  final int chunkParagraphs;
}

@immutable
class NovelLayoutProgress {
  const NovelLayoutProgress({
    required this.processedParagraphs,
    required this.totalParagraphs,
    required this.measuredLines,
    required this.pages,
    required this.isComplete,
  });

  final int processedParagraphs;
  final int totalParagraphs;
  final int measuredLines;
  final int pages;
  final bool isComplete;

  double get fraction {
    if (totalParagraphs <= 0) return isComplete ? 1 : 0;
    return (processedParagraphs / totalParagraphs).clamp(0.0, 1.0);
  }

  double get progress => fraction;
}

class NovelLayoutBudgetExceeded implements Exception {
  const NovelLayoutBudgetExceeded({
    required this.budgetName,
    required this.actual,
    required this.limit,
  });

  final String budgetName;
  final int actual;
  final int limit;

  @override
  String toString() =>
      'NovelLayoutBudgetExceeded($budgetName: $actual > $limit)';
}

typedef NovelLayoutProgressCallback = void Function(NovelLayoutProgress);

/// A pixiv novel's title and byline, laid out at the top of its first page.
@immutable
class NovelTitleBlock {
  const NovelTitleBlock({required this.title, required this.byline});

  final String title;

  /// The author, and the series when there is one.
  final String byline;

  @override
  bool operator ==(Object other) =>
      other is NovelTitleBlock &&
      other.title == title &&
      other.byline == byline;

  @override
  int get hashCode => Object.hash(title, byline);
}
