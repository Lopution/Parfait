import 'package:flutter/material.dart';

import '../../app/replica_page_route.dart';
import '../../core/search/search_models.dart';
import '../illust/detail/illust_detail_page.dart';
import '../novel/novel_page.dart';
import '../profile/user_page.dart';
import 'search_page.dart';
import 'search_result_page.dart';
import 'search_text.dart';

/// The single navigation boundary for Search guide, tags and typed results.
/// Numeric input follows the beta56 routes: illust -> work, novel -> novel,
/// user -> profile. Non-numeric input always enters the shared result page.
void showSearchInput(BuildContext context, {String initialKeyword = ''}) {
  Navigator.of(context).push<void>(
    ReplicaPageRoute<void>(
      builder: (_) => SearchInputPage(initialKeyword: initialKeyword),
    ),
  );
}

void showSearchResults(BuildContext context, SearchQuery query) {
  final keyword = query.keyword.trim();
  if (keyword.isEmpty) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(searchText(context, 'searchInputEmpty'))),
    );
    return;
  }
  final id = _positiveNumericId(keyword);
  if (id != null) {
    switch (query.type) {
      case SearchResultType.illust:
        Navigator.of(context).push<void>(
          ReplicaPageRoute<void>(
            builder: (_) => IllustDetailPage(illustId: id),
          ),
        );
      case SearchResultType.novel:
        showNovelPage(context, id);
      case SearchResultType.user:
        showUserPage(context, id);
    }
    return;
  }
  Navigator.of(context).push<void>(
    ReplicaPageRoute<void>(builder: (_) => SearchResultPage(query: query)),
  );
}

int? _positiveNumericId(String value) {
  if (!RegExp(r'^\d+$').hasMatch(value)) return null;
  final parsed = int.tryParse(value);
  return parsed != null && parsed > 0 ? parsed : null;
}
