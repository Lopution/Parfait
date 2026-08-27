import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_store.dart';
import '../network/api_error.dart';
import '../network/pixiv_http_client.dart';
import 'search_repository.dart';

@immutable
class SearchAutocompleteState {
  const SearchAutocompleteState({
    this.keyword = '',
    this.suggestions = const [],
    this.loading = false,
    this.error,
  });

  final String keyword;
  final List<SearchSuggestion> suggestions;
  final bool loading;
  final ApiError? error;

  SearchAutocompleteState copyWith({
    String? keyword,
    List<SearchSuggestion>? suggestions,
    bool? loading,
    Object? error = _unset,
  }) {
    return SearchAutocompleteState(
      keyword: keyword ?? this.keyword,
      suggestions: suggestions ?? this.suggestions,
      loading: loading ?? this.loading,
      error: identical(error, _unset) ? this.error : error as ApiError?,
    );
  }

  static const _unset = Object();
}

/// Debounces autocomplete at the feature boundary. The generation and token
/// checks make both stale responses and disposed-page responses observable as
/// no-ops instead of allowing old suggestions to flash over a new query.
class SearchAutocompleteController extends Notifier<SearchAutocompleteState> {
  static const debounceDuration = Duration(milliseconds: 260);

  Timer? _timer;
  CancelToken? _token;
  int _generation = 0;
  bool _disposed = false;

  @override
  SearchAutocompleteState build() {
    ref.watch(accountStoreProvider.select((async) => async.value?.current?.id));
    _disposed = false;
    _generation++;
    _timer?.cancel();
    _timer = null;
    _token?.cancel();
    _token = null;
    ref.onDispose(() {
      _disposed = true;
      _generation++;
      _timer?.cancel();
      _token?.cancel();
    });
    return const SearchAutocompleteState();
  }

  void update(String rawKeyword) {
    final keyword = rawKeyword.trim();
    _generation++;
    final generation = _generation;
    _timer?.cancel();
    _timer = null;
    _token?.cancel();
    _token = null;
    if (keyword.isEmpty) {
      state = const SearchAutocompleteState();
      return;
    }
    state = SearchAutocompleteState(keyword: keyword, loading: true);
    _timer = Timer(debounceDuration, () => _fetch(keyword, generation));
  }

  void cancel() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    _token?.cancel();
    _token = null;
    if (!_disposed) state = state.copyWith(loading: false, error: null);
  }

  Future<void> _fetch(String keyword, int generation) async {
    if (_disposed || generation != _generation) return;
    final token = CancelToken();
    _token = token;
    try {
      final suggestions = await ref
          .read(searchRepositoryProvider)
          .autocomplete(keyword, cancelToken: token);
      if (!_isCurrent(generation, token)) return;
      state = SearchAutocompleteState(
        keyword: keyword,
        suggestions: suggestions,
      );
    } on ApiCancelled {
      if (_isCurrent(generation, token)) {
        state = state.copyWith(loading: false);
      }
    } on ApiError catch (error) {
      if (_isCurrent(generation, token)) {
        state = SearchAutocompleteState(keyword: keyword, error: error);
      }
    } catch (error) {
      if (_isCurrent(generation, token)) {
        state = SearchAutocompleteState(
          keyword: keyword,
          error: ApiParseError(error),
        );
      }
    } finally {
      if (identical(_token, token)) _token = null;
    }
  }

  bool _isCurrent(int generation, CancelToken token) =>
      !_disposed &&
      generation == _generation &&
      identical(_token, token) &&
      !token.isCancelled;
}

final searchAutocompleteProvider =
    NotifierProvider.autoDispose<
      SearchAutocompleteController,
      SearchAutocompleteState
    >(SearchAutocompleteController.new);
