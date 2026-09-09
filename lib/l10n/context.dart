import 'package:flutter/widgets.dart';

import 'app_localizations.dart';

/// Convenience accessor: `context.l10n.welcome1` (C6).
extension L10nContext on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);
}
