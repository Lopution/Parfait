import 'package:material_ui/material_ui.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/search/search_models.dart';
import '../../core/settings/settings_controller.dart';
import 'search_result_page.dart';

/// Compatibility wrapper for callers that still construct the old tag page.
/// Rendering is delegated to the shared typed Search result page; like
/// every search entry, the query starts from the persisted illust defaults.
class TagSearchPage extends ConsumerStatefulWidget {
  const TagSearchPage({super.key, required this.keyword});

  final String keyword;

  @override
  ConsumerState<TagSearchPage> createState() => _TagSearchPageState();
}

class _TagSearchPageState extends ConsumerState<TagSearchPage> {
  late SearchQuery _query;

  @override
  void initState() {
    super.initState();
    _query = IllustSearchQuery(
      keyword: widget.keyword,
      filters: ref.read(searchIllustFiltersProvider),
    );
  }

  @override
  void didUpdateWidget(TagSearchPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.keyword != widget.keyword) {
      _query = searchQueryForType(
        _query.type,
        keyword: widget.keyword,
        illustFilters: ref.read(searchIllustFiltersProvider),
        novelFilters: ref.read(searchNovelFiltersProvider),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return SearchResultPage(
      query: _query,
      onTypeChanged: (next) => setState(() => _query = next),
    );
  }
}
