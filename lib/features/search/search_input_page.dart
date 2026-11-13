import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../app/layout/content_widths.dart';
import '../../app/navigation/routes.dart';
import '../../app/widgets/app_top_bar.dart';
import '../../core/search/search_models.dart';
import '../../l10n/context.dart';
import 'search_input_engine.dart';

/// The full-page search input: the engine in a page's own chrome.
class SearchInputPage extends StatelessWidget {
  const SearchInputPage({
    super.key,
    this.initialKeyword = '',
    this.initialType = SearchResultType.illust,
    this.initialIllustFilters,
    this.initialNovelFilters,
    this.onTypeChanged,
  });

  final String initialKeyword;
  final SearchResultType initialType;
  final IllustSearchFilters? initialIllustFilters;
  final NovelSearchFilters? initialNovelFilters;
  final void Function(String keyword, SearchResultType type)? onTypeChanged;

  @override
  Widget build(BuildContext context) {
    return SearchInputEngine(
      initialKeyword: initialKeyword,
      initialType: initialType,
      initialIllustFilters: initialIllustFilters,
      initialNovelFilters: initialNovelFilters,
      onTypeChanged: onTypeChanged,
      // Submitting replaces the input with the results (NAV-06).
      onSubmit: (query) =>
          unawaited(openSearchResults(context, query, replaceCurrent: true)),
      builder: (context, parts) => Scaffold(
        // The keyboard overlays the page instead of squeezing the body into
        // the strip above it; the suggestion list below gets a viewInsets
        // bottom pad so its tail can still scroll clear of the IME.
        resizeToAvoidBottomInset: false,
        appBar: AppTopBar(
          leading: IconButton(
            tooltip: context.l10n.searchCancel,
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.arrow_back),
          ),
          titleSpacing: 0,
          title: parts.field,
          // The same slot as the result page's filter button, so the field
          // keeps its place across the push.
          actions: [parts.filterButton],
          bottom: parts.tabs,
        ),
        body: ContentWidthCap(
          maxWidth: ContentWidths.management,
          child: parts.body,
        ),
      ),
    );
  }
}
