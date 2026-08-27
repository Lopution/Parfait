import 'package:flutter/material.dart';

import '../../core/i18n/replica_strings.dart';

String searchText(BuildContext context, String key) => ReplicaStrings.fromTag(
  Localizations.localeOf(context).toLanguageTag(),
  key,
);
