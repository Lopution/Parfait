import 'package:material_ui/material_ui.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/search/search_models.dart';
import '../../core/settings/settings_controller.dart';
import 'search_result_page.dart';

/// Compatibility wrapper for callers that still construct the old tag page.
/// Rendering is delegated to the shared typed Search result page; like
/// every search entry, the query starts from the persisted illust defaults.
class TagSearchPage extends ConsumerWidget {
  const TagSearchPage({super.key, required this.keyword});

  final String keyword;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SearchResultPage(
      query: IllustSearchQuery(
        keyword: keyword,
        filters: ref.read(searchIllustFiltersProvider),
      ),
    );
  }
}
