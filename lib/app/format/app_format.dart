import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

import '../../l10n/context.dart';

/// Locale-aware display formats. Every user-visible date and count goes
/// through here; data formats (search parameters, file names) do not.
abstract final class AppFormat {
  /// `DateFormat.yMMMd` in the app locale: zh「2026年10月4日」,
  /// en "Oct 4, 2026". [withTime] appends `Hm`.
  static String date(
    BuildContext context,
    DateTime value, {
    bool withTime = false,
  }) {
    final locale = Localizations.localeOf(context).toLanguageTag();
    final local = value.toLocal();
    final pattern = withTime
        ? DateFormat.yMMMd(locale).add_Hm()
        : DateFormat.yMMMd(locale);
    return pattern.format(local);
  }

  /// 刚刚 / N 分钟前 / N 小时前 / N 天前, then [date]. [now] is for tests.
  static String relative(
    BuildContext context,
    DateTime value, {
    DateTime? now,
  }) {
    final l10n = context.l10n;
    final diff = (now ?? DateTime.now()).difference(value);
    if (diff < const Duration(minutes: 1)) return l10n.timeJustNow;
    if (diff < const Duration(hours: 1)) {
      return l10n.timeMinutesAgo(diff.inMinutes);
    }
    if (diff < const Duration(days: 1)) {
      return l10n.timeHoursAgo(diff.inHours);
    }
    if (diff < const Duration(days: 7)) {
      return l10n.timeDaysAgo(diff.inDays);
    }
    return date(context, value);
  }

  /// `NumberFormat.compact` at two significant digits: zh「1.2万」,
  /// en "12K", ru "12 тыс.".
  static String count(BuildContext context, int value) {
    final locale = Localizations.localeOf(context).toLanguageTag();
    final format = NumberFormat.compact(locale: locale)..significantDigits = 2;
    return format.format(value);
  }
}
