import 'package:flutter/services.dart';

/// A query is keywords split by spaces, half or full width, as pixiv's
/// search reads it.
bool isKeywordSeparator(String char) => char == ' ' || char == '\u3000';

/// pixiv's mark for a keyword a search leaves out.
const _exclude = '-';

/// Boolean operator recognized by pixiv search queries.
const kSearchOrOperator = 'OR';

/// Whether [token] is a boolean operator rather than a tag prefix.
bool isBooleanOperatorToken(String token) => token == kSearchOrOperator;

/// The keywords of [text], in order, as ranges into it.
List<TextRange> keywordRanges(String text) {
  final ranges = <TextRange>[];
  int? start;
  for (var i = 0; i <= text.length; i++) {
    if (i == text.length || isKeywordSeparator(text[i])) {
      if (start != null) ranges.add(TextRange(start: start, end: i));
      start = null;
    } else {
      start ??= i;
    }
  }
  return ranges;
}

/// The keywords a separator closes: those written out, not the one still
/// being typed at the end.
List<TextRange> finishedKeywordRanges(String text) => [
  for (final range in keywordRanges(text))
    if (range.end < text.length) range,
];

/// The keyword the caret is in or at the end of, the one autocomplete
/// works on; null when the caret follows a separator or text is selected.
TextRange? keywordAtCaret(TextEditingValue value) {
  final selection = value.selection;
  if (!selection.isValid || !selection.isCollapsed) return null;
  final caret = selection.baseOffset;
  for (final range in keywordRanges(value.text)) {
    if (range.start < caret && caret <= range.end) return range;
  }
  return null;
}

/// What [keyword] asks autocomplete for: an excluded keyword without its
/// minus, or empty when [keyword] is a boolean operator like `OR`.
String completionQueryOf(String keyword) {
  if (isBooleanOperatorToken(keyword)) return '';
  return keyword.startsWith(_exclude) ? keyword.substring(1) : keyword;
}

/// The keywords of [text] other than the one at [except], as autocomplete
/// would name them: a suggestion matching one of them is already there.
Set<String> otherKeywords(String text, TextRange except) => {
  for (final range in keywordRanges(text))
    if (range != except) completionQueryOf(range.textInside(text)),
};

/// [value] with the keyword at [range] replaced by [replacement], keeping
/// its exclusion minus (or forcing `-` when [exclude] is true). [thenSeparate]
/// adds a space after it unless one follows and puts the caret past it.
TextEditingValue replaceKeyword(
  TextEditingValue value,
  TextRange range,
  String replacement, {
  bool thenSeparate = false,
  bool exclude = false,
}) {
  final text = value.text;
  final clean = replacement.startsWith(_exclude)
      ? replacement.substring(1)
      : replacement;
  final shouldExclude = exclude || range.textInside(text).startsWith(_exclude);
  final keyword = shouldExclude ? '$_exclude$clean' : clean;
  var after = text.substring(range.end);
  if (thenSeparate && (after.isEmpty || !isKeywordSeparator(after[0]))) {
    after = ' $after';
  }
  final caret = range.start + keyword.length + (thenSeparate ? 1 : 0);
  return TextEditingValue(
    text: text.substring(0, range.start) + keyword + after,
    selection: TextSelection.collapsed(offset: caret),
  );
}

/// Appends `-tag ` to [value] (avoiding duplicate `-tag` tokens).
TextEditingValue appendExcludedTag(TextEditingValue value, String tag) {
  final clean = tag.trim().startsWith(_exclude)
      ? tag.trim().substring(1)
      : tag.trim();
  if (clean.isEmpty) return value;
  final token = '$_exclude$clean';
  final current = value.text.trimRight();
  final next = current.isEmpty ? '$token ' : '$current $token ';
  return TextEditingValue(
    text: next,
    selection: TextSelection.collapsed(offset: next.length),
  );
}

/// Inserts the `OR` operator at the end of [value] when a preceding keyword
/// exists and the query does not already end with `OR`.
TextEditingValue insertOrOperator(TextEditingValue value) {
  final trimmed = value.text.trimRight();
  if (trimmed.isEmpty) return value;
  final ranges = keywordRanges(trimmed);
  if (ranges.isNotEmpty &&
      isBooleanOperatorToken(ranges.last.textInside(trimmed))) {
    final next = '$trimmed ';
    return TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: next.length),
    );
  }
  final next = '$trimmed $kSearchOrOperator ';
  return TextEditingValue(
    text: next,
    selection: TextSelection.collapsed(offset: next.length),
  );
}
