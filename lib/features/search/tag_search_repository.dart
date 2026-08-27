import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/search/search_feed_controller.dart';
import '../../core/search/search_models.dart';
import '../../core/paging/paged_feed_controller.dart';

/// Compatibility provider for existing detail tests and callers. Tag search
/// now uses the same typed repository/controller as the Search result page.
class TagSearchController extends SearchFeedController {
  TagSearchController(this.tag)
    : super(
        IllustSearchQuery(
          keyword: tag,
          filters: const SearchFilters(
            target: SearchTarget.partialMatchForTags,
            sort: SearchSort.dateDesc,
          ),
        ),
      );

  final String tag;
}

final tagSearchControllerProvider =
    AsyncNotifierProvider.family<TagSearchController, PagedFeedState, String>(
      TagSearchController.new,
    );
