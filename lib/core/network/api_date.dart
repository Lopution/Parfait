/// Pixiv's calendar-date wire format (`yyyy-MM-dd`), shared by search
/// filters, ranking dates and the route parameters that carry them.
library;

final _apiDatePattern = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');

String formatApiDate(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';

/// A local calendar date from `yyyy-MM-dd`; anything else — other
/// layouts, impossible days such as `2026-02-31` — is null.
DateTime? parseApiDate(String? raw) {
  final match = raw == null ? null : _apiDatePattern.firstMatch(raw);
  if (match == null) return null;
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  final date = DateTime(year, month, day);
  if (date.year != year || date.month != month || date.day != day) {
    return null;
  }
  return date;
}
