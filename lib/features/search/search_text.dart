import 'package:flutter/material.dart';

import '../../l10n/lookup.dart';
import '../../l10n/context.dart';

/// Dynamic label resolution for the search enums (tab/filter labelKeys).
String searchText(BuildContext context, String key) =>
    l10nLookup(context.l10n, key);
