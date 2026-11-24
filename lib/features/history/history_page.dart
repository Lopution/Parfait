import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/services.dart'
    show HardwareKeyboard, KeyDownEvent, KeyEvent, LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/haptics/app_haptics.dart';
import '../../app/icons/app_icons.dart';
import '../../app/icons/ui_icons.dart';
import '../../app/layout/input_modality.dart';
import '../../app/motion/app_overlays.dart';
import '../../app/motion/removal.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../app/widgets/app_menu_button.dart';
import '../../app/widgets/app_snack_bar.dart';
import '../../app/widgets/app_top_bar.dart';
import '../../app/widgets/errors/error_details.dart';
import '../../app/widgets/feed/desktop_gallery_controls.dart';
import '../../app/widgets/feed/desktop_inspectable_gallery.dart';
import '../../app/widgets/selection_app_bar.dart';
import '../../app/widgets/settings/persist_settings.dart';
import '../../core/history/history_feed_controller.dart';
import '../../core/history/history_models.dart';
import '../../core/history/history_repository.dart';
import '../../core/settings/settings_controller.dart';
import '../../l10n/context.dart';
import 'history_body.dart';
import 'history_filter_bar.dart';

/// The three rows of the history page's overflow menu.
enum _HistoryMenuAction { recordLocal, recordPixiv, deleteAll }

class HistoryPage extends ConsumerStatefulWidget {
  const HistoryPage({super.key});

  @override
  ConsumerState<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends ConsumerState<HistoryPage> {
  /// Bumped by a clear and by an out-of-sight catch-up: the body is built
  /// afresh, its scroll back at the top.
  int _bodyGeneration = 0;

  StreamSubscription<void>? _changes;
  ValueListenable<TickerModeData>? _tickerMode;
  ModalRoute<dynamic>? _route;
  bool _catchingUp = false;
  bool _catchUpAgain = false;

  /// Selection, search and filter states are page-local: nothing outside
  /// this page consumes them, so they never leave the widget tree.
  bool _managing = false;
  final Set<int> _selected = <int>{};
  int? _lastToggledKey;
  final _removals = RemovalController();

  HistoryContentType? _contentType;
  bool _searching = false;
  String _appliedQuery = '';
  bool _hadAnyContent = false;
  String? _lastAccountId;
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    _changes = ref
        .read(historyRepositoryProvider)
        .changes
        .listen((_) => _onHistoryChanged());
    HardwareKeyboard.instance.addHandler(_onKeyEvent);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerMode = TickerMode.getValuesNotifier(context);
    _route = ModalRoute.of(context);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKeyEvent);
    unawaited(_changes?.cancel());
    _searchDebounce?.cancel();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _removals.dispose();
    super.dispose();
  }

  HistoryFeedQuery _feedQueryFor(String accountId) => HistoryFeedQuery(
    accountId: accountId,
    contentType: _contentType,
    query: _appliedQuery,
  );

  bool get _hasActiveSearch => _searching || _appliedQuery.isNotEmpty;

  /// The page keeps its order while it shows, and under a page it opened:
  /// the image flying back lands on the card it left. Hidden on another
  /// tab with nothing over it, it catches up out of sight, so the tab
  /// comes back current.
  void _onHistoryChanged() {
    final accountId = ref.read(historyAccountIdProvider);
    if (!mounted ||
        accountId == null ||
        _managing ||
        (_tickerMode?.value.enabled ?? true) ||
        !(_route?.isCurrent ?? false)) {
      return;
    }
    unawaited(_catchUp(_feedQueryFor(accountId)));
  }

  Future<void> _catchUp(HistoryFeedQuery query) async {
    if (_catchingUp) {
      _catchUpAgain = true;
      return;
    }
    _catchingUp = true;
    try {
      final provider = historyFeedControllerProvider(query);
      do {
        _catchUpAgain = false;
        if (!ref.read(provider).hasValue) return;
        await ref.read(provider.notifier).refresh();
      } while (_catchUpAgain && mounted);
      if (mounted) setState(() => _bodyGeneration++);
    } finally {
      _catchingUp = false;
    }
  }

  bool _onKeyEvent(KeyEvent event) {
    if (!mounted || !_managing || event is! KeyDownEvent) return false;
    if (!(_tickerMode?.value.enabled ?? true) || !(_route?.isCurrent ?? true)) {
      return false;
    }
    if (isTextEditingFocused() || !isPointerInput(context)) return false;
    final kbd = HardwareKeyboard.instance;
    if (event.logicalKey == LogicalKeyboardKey.keyA &&
        (kbd.isControlPressed || kbd.isMetaPressed) &&
        !kbd.isAltPressed) {
      final accountId = ref.read(historyAccountIdProvider);
      if (accountId != null) {
        _selectAll(_feedQueryFor(accountId));
        return true;
      }
    }
    return false;
  }

  void _openNarrowSearch() {
    setState(() => _searching = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocusNode.requestFocus();
    });
  }

  void _focusWideSearch() {
    _searchFocusNode.requestFocus();
  }

  void _onQueryChanged(String value) {
    _searchDebounce?.cancel();
    final next = normalizeHistoryQuery(value);
    if (next == _appliedQuery) return;
    _searchDebounce = Timer(historySearchDebounce, () {
      if (!mounted) return;
      setState(() => _appliedQuery = next);
    });
  }

  void _onQuerySubmitted(String value) {
    _searchDebounce?.cancel();
    final next = normalizeHistoryQuery(value);
    if (next == _appliedQuery) return;
    setState(() => _appliedQuery = next);
  }

  void _clearQuery() {
    _searchDebounce?.cancel();
    _searchController.clear();
    if (_appliedQuery.isNotEmpty) {
      setState(() => _appliedQuery = '');
    } else {
      setState(() {});
    }
  }

  void _exitSearch() {
    _searchDebounce?.cancel();
    _searchController.clear();
    _searchFocusNode.unfocus();
    setState(() {
      _searching = false;
      _appliedQuery = '';
    });
  }

  void _clearAllFilters() {
    _searchDebounce?.cancel();
    _searchController.clear();
    _searchFocusNode.unfocus();
    setState(() {
      _contentType = null;
      _searching = false;
      _appliedQuery = '';
    });
  }

  void _setContentType(HistoryContentType? value) {
    if (value == _contentType) return;
    setState(() => _contentType = value);
  }

  void _enterManaging([int? recordKey]) {
    // Entering management mode is the explicit-vibration role (W4).
    AppHaptics.confirm();
    _searchFocusNode.unfocus();
    setState(() {
      _managing = true;
      if (recordKey != null) {
        _selected.add(recordKey);
        _lastToggledKey = recordKey;
      }
    });
  }

  void _toggleSelected(int recordKey) {
    AppHaptics.select();
    setState(() {
      if (!_selected.remove(recordKey)) _selected.add(recordKey);
      _lastToggledKey = recordKey;
    });
  }

  void _handleItemToggle(int recordKey, List<int> orderedKeys) {
    if (isPointerInput(context) &&
        HardwareKeyboard.instance.isShiftPressed &&
        _lastToggledKey != null) {
      final start = orderedKeys.indexOf(_lastToggledKey!);
      final end = orderedKeys.indexOf(recordKey);
      if (start >= 0 && end >= 0) {
        final lo = math.min(start, end);
        final hi = math.max(start, end);
        AppHaptics.select();
        setState(() {
          _selected.addAll(orderedKeys.sublist(lo, hi + 1));
          _lastToggledKey = recordKey;
        });
        return;
      }
    }
    _toggleSelected(recordKey);
  }

  void _exitManaging() {
    setState(() {
      _managing = false;
      _selected.clear();
      _lastToggledKey = null;
    });
  }

  void _selectAll(HistoryFeedQuery query) {
    AppHaptics.select();
    final ids = ref.read(historyFeedControllerProvider(query)).value?.ids;
    if (ids == null || ids.isEmpty) return;
    setState(() => _selected.addAll(ids));
  }

  @override
  Widget build(BuildContext context) {
    final accountId = ref.watch(historyAccountIdProvider);
    if (accountId != _lastAccountId) {
      _lastAccountId = accountId;
      _hadAnyContent = false;
    }
    final repository = ref.watch(historyRepositoryProvider);
    final settings = ref.watch(settingsProvider).value;
    final activeQuery = accountId == null ? null : _feedQueryFor(accountId);
    final feedAsync = activeQuery == null
        ? null
        : ref.watch(historyFeedControllerProvider(activeQuery));
    final feedValue = feedAsync?.value;
    final hasVisibleRecords =
        feedValue != null &&
        !feedValue.showInitialError &&
        feedValue.ids.isNotEmpty;
    if (hasVisibleRecords) {
      _hadAnyContent = true;
    } else if (accountId == null) {
      _hadAnyContent = false;
    }
    final canDeleteAll =
        activeQuery != null &&
        (hasVisibleRecords || (activeQuery.hasFilter && _hadAnyContent));
    final isInitialEmptyUnfiltered =
        activeQuery != null &&
        !activeQuery.hasFilter &&
        !_searching &&
        feedValue != null &&
        !feedValue.showInitialError &&
        feedValue.ids.isEmpty;
    final isInitialErrorUnfiltered =
        activeQuery != null &&
        !activeQuery.hasFilter &&
        !_searching &&
        ((feedAsync?.hasError ?? false) ||
            (feedValue?.showInitialError ?? false));
    final showFilterBar =
        accountId != null &&
        !_managing &&
        !isInitialEmptyUnfiltered &&
        !isInitialErrorUnfiltered &&
        (hasVisibleRecords ||
            _contentType != null ||
            _hasActiveSearch ||
            ((feedAsync?.isLoading ?? false) && _hadAnyContent));

    return PopScope(
      // System back exits selection mode, then search mode, before popping.
      canPop: !_managing && !_hasActiveSearch,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_managing) {
          _exitManaging();
        } else if (_hasActiveSearch) {
          _exitSearch();
        }
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth >= kHistoryWideFilterWidth;
          final narrowSearching =
              !isWide &&
              (_hasActiveSearch || _searchController.text.isNotEmpty);
          return Scaffold(
            // Keep history grid geometry stable when the IME opens (LAYOUT-10).
            resizeToAvoidBottomInset: false,
            appBar: _managing
                ? selectionAppBar(
                    context,
                    count: _selected.length,
                    onClose: _exitManaging,
                    actions: [
                      IconButton(
                        tooltip: context.l10n.selectAll,
                        onPressed: activeQuery == null
                            ? null
                            : () => _selectAll(activeQuery),
                        icon: const Icon(UiIcons.selectAll),
                      ),
                      IconButton(
                        tooltip: context.l10n.historyDelete,
                        onPressed: _selected.isEmpty || activeQuery == null
                            ? null
                            : () => _deleteSelected(activeQuery),
                        icon: const Icon(AppIcons.trash),
                      ),
                    ],
                  )
                : narrowSearching && accountId != null
                ? historySearchTopBar(
                    context,
                    controller: _searchController,
                    focusNode: _searchFocusNode,
                    onChanged: _onQueryChanged,
                    onSubmitted: _onQuerySubmitted,
                    onClear: _clearQuery,
                    onExit: _exitSearch,
                  )
                : AppTopBar(
                    title: Text(context.l10n.historySettings),
                    actions: [
                      DesktopGalleryControls(
                        visible: accountId != null && !_managing,
                      ),
                      // Spelled out like every list's manage entry: an icon
                      // alone did not read as "manage".
                      if (accountId != null)
                        TextButton(
                          // Nothing to manage in an empty list (L1).
                          onPressed: hasVisibleRecords ? _enterManaging : null,
                          child: Text(context.l10n.manage),
                        ),
                      // The overflow stays visible signed out: the record
                      // switches are global settings; only delete-all needs
                      // an account with records.
                      AppMenuButton<_HistoryMenuAction>(
                        onSelected: (menuContext, action) => _onMenuAction(
                          menuContext,
                          action,
                          repository,
                          accountId,
                        ),
                        entries: [
                          AppMenuEntry(
                            value: _HistoryMenuAction.recordLocal,
                            label: context.l10n.historyRecordLocal,
                            checked: settings?.enableHistory ?? false,
                            enabled: settings != null,
                          ),
                          AppMenuEntry(
                            value: _HistoryMenuAction.recordPixiv,
                            label: context.l10n.historyRecordPixiv,
                            checked: settings?.enablePixivHistory ?? false,
                            enabled: settings != null,
                          ),
                          AppMenuEntry(
                            value: _HistoryMenuAction.deleteAll,
                            label: context.l10n.historyDeleteAll,
                            enabled: canDeleteAll,
                          ),
                        ],
                      ),
                    ],
                  ),
            body: DesktopInspectableGallery(
              enabled: !_managing,
              active: accountId != null,
              child: activeQuery == null
                  ? Center(child: Text(context.l10n.signedOut))
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (showFilterBar)
                          HistoryFilterBar(
                            isWide: isWide,
                            contentType: _contentType,
                            onContentTypeChanged: _setContentType,
                            searchController: _searchController,
                            searchFocusNode: _searchFocusNode,
                            narrowSearching: narrowSearching,
                            onOpenNarrowSearch: _openNarrowSearch,
                            onFocusWideSearch: _focusWideSearch,
                            onQueryChanged: _onQueryChanged,
                            onQuerySubmitted: _onQuerySubmitted,
                            onClearQuery: _clearQuery,
                          ),
                        Expanded(
                          child: RemovalScope(
                            controller: _removals,
                            child: HistoryBody(
                              key: ValueKey(
                                '${activeQuery.accountId}-'
                                '${activeQuery.contentType?.storageValue ?? 'all'}-'
                                '${activeQuery.query}-$_bodyGeneration',
                              ),
                              generation: _bodyGeneration,
                              feedQuery: activeQuery,
                              managing: _managing,
                              selectedKeys: _selected,
                              onToggle: _handleItemToggle,
                              onEnterManaging: _enterManaging,
                              onClearFilter: _clearAllFilters,
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _deleteSelected(HistoryFeedQuery activeQuery) async {
    // Opening the destructive confirm surface is the explicit-vibration
    // role; the row-level toggles stay on the light tick.
    AppHaptics.confirm();
    final confirmed = await _confirmDelete(
      context,
      title: context.l10n.historyDelete,
    );
    if (confirmed != true || !mounted) return;
    final keys = List<int>.of(_selected);
    final controller = ref.read(
      historyFeedControllerProvider(activeQuery).notifier,
    );
    // The tiles leave first; the delete then drops them from the feed.
    await _removals.playExit(keys);
    try {
      for (final key in keys) {
        final record = controller.recordFor(key);
        if (record != null) await controller.removeRecord(record);
      }
      if (mounted) {
        setState(() {
          _managing = false;
          _selected.clear();
          _lastToggledKey = null;
        });
      }
    } on Object catch (error) {
      _removals.restore(keys);
      if (mounted) {
        showErrorSnackBar(
          context,
          action: context.l10n.historyDelete,
          error: error,
        );
      }
    }
  }

  void _onMenuAction(
    BuildContext menuContext,
    _HistoryMenuAction action,
    HistoryRepository repository,
    String? accountId,
  ) {
    final notifier = ref.read(settingsProvider.notifier);
    final settings = ref.read(settingsProvider).value;
    switch (action) {
      case _HistoryMenuAction.recordLocal:
        if (settings == null) return;
        unawaited(
          persistSettings(
            menuContext,
            () => notifier.setHistoryEnabled(!settings.enableHistory),
          ),
        );
      case _HistoryMenuAction.recordPixiv:
        if (settings == null) return;
        unawaited(
          persistSettings(
            menuContext,
            () => notifier.setPixivHistoryEnabled(!settings.enablePixivHistory),
          ),
        );
      case _HistoryMenuAction.deleteAll:
        if (accountId != null) {
          unawaited(_deleteAll(menuContext, repository, accountId));
        }
    }
  }

  Future<void> _deleteAll(
    BuildContext context,
    HistoryRepository repository,
    String accountId,
  ) async {
    final container = ProviderScope.containerOf(context, listen: false);
    final activeQuery = _feedQueryFor(accountId);
    final confirmed = await _confirmDelete(
      context,
      title: context.l10n.historyDeleteAll,
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await repository.clear(accountId);
      container.invalidate(historyFeedControllerProvider(activeQuery));
      if (activeQuery.hasFilter) {
        container.invalidate(
          historyFeedControllerProvider(HistoryFeedQuery(accountId: accountId)),
        );
      }
      if (context.mounted) {
        _searchDebounce?.cancel();
        _searchController.clear();
        _searchFocusNode.unfocus();
        setState(() {
          _managing = false;
          _selected.clear();
          _lastToggledKey = null;
          _contentType = null;
          _searching = false;
          _appliedQuery = '';
          _hadAnyContent = false;
          _bodyGeneration++;
        });
        showAppSnackBar(context, context.l10n.historyDeleteAll);
      }
    } on Object catch (error) {
      if (context.mounted) {
        showErrorSnackBar(
          context,
          action: context.l10n.historyDeleteAll,
          error: error,
        );
      }
    }
  }
}

Future<bool?> _confirmDelete(BuildContext context, {required String title}) {
  return showAppAdaptiveDialog<bool>(
    context: context,
    maxWidth: 420,
    isScrollControlled: true,
    builder: (sheetContext) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(FuncSpacing.xl),
          child: Column(
            // Wraps content: a fixed fraction of the sheet height overflowed
            // on short surfaces and left the buttons partially unhit-testable.
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: FuncSpacing.md),
              Text(context.l10n.historyDeleteHint),
              const SizedBox(height: FuncSpacing.xl),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(sheetContext).pop(false),
                      child: Text(context.l10n.cancel),
                    ),
                  ),
                  const SizedBox(width: FuncSpacing.md),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.of(sheetContext).pop(true),
                      child: Text(context.l10n.confirm),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
}
