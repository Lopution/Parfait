import 'package:material_ui/material_ui.dart';

import '../../core/search/search_models.dart';
import 'search_result_page.dart';

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

