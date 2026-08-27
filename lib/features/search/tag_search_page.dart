import 'package:flutter/material.dart';

import '../../core/search/search_models.dart';
import 'search_result_page.dart';
import 'search_router.dart';

/// Compatibility wrapper for callers that still construct the old tag page.
/// Rendering is delegated to the shared typed Search result page.
class TagSearchPage extends StatelessWidget {
  const TagSearchPage({super.key, required this.keyword});

  final String keyword;

  @override
  Widget build(BuildContext context) {
    return SearchResultPage(
      query: IllustSearchQuery(
        keyword: keyword,
        filters: const SearchFilters(
          target: SearchTarget.partialMatchForTags,
          sort: SearchSort.dateDesc,
        ),
      ),
    );
  }
}

/// Convenience push helper with the Replica right-in rhythm.
void showTagSearch(BuildContext context, String keyword) {
  showSearchResults(
    context,
    IllustSearchQuery(
      keyword: keyword,
      filters: const SearchFilters(
        target: SearchTarget.partialMatchForTags,
        sort: SearchSort.dateDesc,
      ),
    ),
  );
}
