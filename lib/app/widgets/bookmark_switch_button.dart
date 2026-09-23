import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/bookmark/bookmark_actions.dart';
import '../../core/bookmark/bookmark_models.dart';
import '../../core/bookmark/bookmark_store.dart';
import '../../core/bookmark/bookmark_tag_providers.dart';
import '../layout/app_breakpoints.dart';
import '../layout/content_widths.dart';
import '../motion/app_overlays.dart';
import '../theme/func_semantic_tokens.dart';
import '../theme/func_tokens.dart';
import '../widgets/app_snack_bar.dart';
import '../../l10n/context.dart';
import '../../l10n/lookup.dart';

String _bookmarkText(BuildContext context, String key) =>
    l10nLookup(context.l10n, key);

/// Beta56 BookmarkSwitchButton replica driven entirely by the shared
/// BookmarkStore: heart icon (isButton app-bar/row variant), pending
/// CupertinoActivityIndicator (24px, R4), short-press toggle and
/// long-press public/private sheet (suppressed while pending or already
/// bookmarked, R6).
class BookmarkSwitchButton extends ConsumerWidget {
  const BookmarkSwitchButton({
    super.key,
    required this.illustId,
    required this.title,
    this.isNovel = false,
    this.isButton = true,
    this.isPlaceholder = false,
  });

  final int illustId;
  final String title;
  final bool isNovel;
  final bool isButton;
  final bool isPlaceholder;

  BookmarkKey get _key => BookmarkKey(
    isNovel ? BookmarkEntityType.novel : BookmarkEntityType.illust,
    illustId,
  );

  void _showBookmarkSheet(BuildContext context, {required bool bookmarked}) {
    showAppBottomSheet<void>(
      context: context,
      backgroundColor: FuncTokens.transparent,
      isScrollControlled: true,
      builder: (sheetContext) => _BookmarkEditSheet(
        bookmarkKey: _key,
        title: title,
        isNovel: isNovel,
        initiallyBookmarked: bookmarked,
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (isPlaceholder) return const SizedBox.shrink();
    final colorScheme = Theme.of(context).colorScheme;
    final entry = ref.watch(bookmarkStoreProvider.select((s) => s[_key]));
    final bookmarked = entry?.bookmarked ?? false;
    final pending = entry?.isPending ?? false;
    final semanticLabel =
        '${_bookmarkText(context, isNovel ? 'bookmarkNovel' : 'bookmarkIllust')}: $title';

    // R5: failures restore the confirmed icon (non-optimistic means it never
    // moved) and surface an observable error.
    ref.listen<Object?>(bookmarkStoreProvider.select((s) => s[_key]?.error), (
      previous,
      next,
    ) {
      if (next != null && previous != next) {
        showAppSnackBar(
          context,
          context.l10n.bookmarkOperationFailed(next.toString()),
        );
      }
    });

    if (pending) {
      return Semantics(
        container: true,
        button: true,
        enabled: false,
        label: semanticLabel,
        liveRegion: true,
        child: Padding(
          padding: EdgeInsets.all(isButton ? 12 : 8),
          child: SizedBox(
            width: 24,
            height: 24,
            child: Center(
              child: CupertinoActivityIndicator(color: colorScheme.onSurface),
            ),
          ),
        ),
      );
    }

    // Long-press opens the sheet in both directions: create for a fresh work,
    // edit (prefilled from bookmark detail) for an already-bookmarked one.
    final onLongPress = pending
        ? null
        : () => _showBookmarkSheet(context, bookmarked: bookmarked);

    if (isButton) {
      return Semantics(
        container: true,
        button: true,
        toggled: bookmarked,
        label: semanticLabel,
        onTap: () => ref.read(bookmarkActionsProvider).toggle(_key),
        onLongPress: onLongPress,
        child: GestureDetector(
          excludeFromSemantics: true,
          onLongPress: onLongPress,
          child: ExcludeSemantics(
            child: IconButton(
              splashRadius: 24,
              iconSize: 24,
              onPressed: () => ref.read(bookmarkActionsProvider).toggle(_key),
              icon: bookmarked
                  ? Icon(Icons.favorite_sharp, color: colorScheme.primary)
                  : const Icon(Icons.favorite_outline_sharp),
            ),
          ),
        ),
      );
    }
    return Semantics(
      container: true,
      button: true,
      toggled: bookmarked,
      label: semanticLabel,
      onTap: () => ref.read(bookmarkActionsProvider).toggle(_key),
      onLongPress: onLongPress,
      child: GestureDetector(
        excludeFromSemantics: true,
        onLongPress: onLongPress,
        onTap: () => ref.read(bookmarkActionsProvider).toggle(_key),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: bookmarked
              ? Icon(Icons.favorite_sharp, color: colorScheme.primary, size: 24)
              : const Icon(Icons.favorite_outline_sharp, size: 24),
        ),
      ),
    );
  }
}

/// Bookmark create/edit sheet: restrict selector plus a tag editor — selected
/// chips, a free-text input for new tags, and suggestion chips from the
/// user's own tag collection. For an already-bookmarked work the sheet
/// prefills from `bookmark_detail` once it arrives.
class _BookmarkEditSheet extends ConsumerStatefulWidget {
  const _BookmarkEditSheet({
    required this.bookmarkKey,
    required this.title,
    required this.isNovel,
    required this.initiallyBookmarked,
  });

  final BookmarkKey bookmarkKey;
  final String title;
  final bool isNovel;
  final bool initiallyBookmarked;

  @override
  ConsumerState<_BookmarkEditSheet> createState() => _BookmarkEditSheetState();
}

class _BookmarkEditSheetState extends ConsumerState<_BookmarkEditSheet> {
  final TextEditingController _tagInput = TextEditingController();
  BookmarkRestrict _restrict = BookmarkRestrict.public;
  List<String> _tags = const [];
  bool _prefilled = false;

  /// Draft baseline: the persisted bookmark state (public+empty for a fresh
  /// work, the prefilled detail for an existing one). Closing the sheet
  /// while [ _isDirty ] asks before discarding.
  BookmarkRestrict _initialRestrict = BookmarkRestrict.public;
  List<String> _initialTags = const [];

  bool _submitting = false;
  Object? _submitError;

  @override
  void dispose() {
    _tagInput.dispose();
    super.dispose();
  }

  bool get _isDirty =>
      _restrict != _initialRestrict || !listEquals(_tags, _initialTags);

  /// Closing is safe without a prompt when the draft matches the baseline or
  /// a submit is already in flight — the in-flight mutation keeps running
  /// and the store entry still reports its outcome.
  bool get _closableFreely => _submitting || !_isDirty;

  Future<void> _attemptClose() async {
    if (_closableFreely) {
      Navigator.of(context).pop();
      return;
    }
    final leave = await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.l10n.profileEditLeaveTitle),
        content: Text(context.l10n.profileEditLeaveDetail),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(context.l10n.profileEditLeaveConfirm),
          ),
        ],
      ),
    );
    if (leave == true && mounted) Navigator.of(context).pop();
  }

  Future<void> _confirm() async {
    final pending = _tagInput.text.trim();
    final tags = pending.isEmpty ? _tags : [..._tags, pending];
    setState(() {
      _submitting = true;
      _submitError = null;
    });
    try {
      await ref
          .read(bookmarkActionsProvider)
          .addWithRestrict(widget.bookmarkKey, _restrict, tags: tags);
    } on Object catch (error) {
      // Thrown before the store even saw the op (e.g. no session): same
      // keep-open + inline-error handling as a store-level failure.
      if (mounted) {
        setState(() {
          _submitting = false;
          _submitError = error;
        });
      }
      return;
    }
    if (!mounted) return;
    final error = ref.read(bookmarkStoreProvider)[widget.bookmarkKey]?.error;
    if (error != null) {
      // Non-connectivity failure: keep the sheet open, keep the draft
      // untouched, show the error inline (D6).
      setState(() {
        _submitting = false;
        _submitError = error;
      });
      return;
    }
    // Committed, or a connectivity failure already queued for replay —
    // either way the draft is accepted and the sheet closes (D6).
    Navigator.of(context).pop();
  }

  void _addTag(String raw) {
    final tag = raw.trim();
    if (tag.isEmpty || _tags.contains(tag)) return;
    setState(() => _tags = [..._tags, tag]);
    _tagInput.clear();
  }

  void _removeTag(String tag) {
    setState(
      () => _tags = [
        for (final item in _tags)
          if (item != tag) item,
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;

    if (widget.initiallyBookmarked) {
      ref.listen(bookmarkDetailProvider(widget.bookmarkKey), (previous, next) {
        final detail = next.value;
        if (detail != null && !_prefilled) {
          setState(() {
            _prefilled = true;
            // The persisted state is the draft baseline. Values typed
            // while the detail was still in flight are kept — late-arriving
            // prefill must not clobber a user's edits. Dirtiness is judged
            // against the old baseline before it moves.
            final stillPristine = !_isDirty;
            _initialRestrict = detail.restrict ?? BookmarkRestrict.public;
            _initialTags = detail.tagNames;
            if (stillPristine) {
              _restrict = _initialRestrict;
              _tags = _initialTags;
            }
          });
        }
      });
    }
    // Watched separately from the prefill listener so the failure branch is
    // visible: an errored detail leaves _prefilled false forever, which used
    // to pin the sheet to an endless spinner with a live confirm button.
    final detailState = widget.initiallyBookmarked
        ? ref.watch(bookmarkDetailProvider(widget.bookmarkKey))
        : null;

    final suggestions = ref.watch(
      userBookmarkTagSuggestionsProvider((widget.bookmarkKey.type, _restrict)),
    );

    final awaitingPrefill = widget.initiallyBookmarked && !_prefilled;
    final prefillFailed = awaitingPrefill && (detailState?.hasError ?? false);

    final contentMaxWidth =
        MediaQuery.widthOf(context) >= AppBreakpoints.expanded
        ? ContentWidths.form
        : double.infinity;
    Widget sheet = Align(
      // heightFactor shrink-wraps vertically: a bare Center would expand to
      // the sheet slot's max height. On expanded surfaces the form column
      // caps at ContentWidths.form and stays centered (parent §5.5).
      alignment: Alignment.topCenter,
      heightFactor: 1.0,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: contentMaxWidth),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(24),
              topRight: Radius.circular(24),
            ),
            color: colorScheme.surface,
          ),
          child: SafeArea(
            top: false,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: MediaQuery.heightOf(context) * 0.35,
                maxHeight: MediaQuery.heightOf(context) * 0.75,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 20),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.initiallyBookmarked
                              ? l10n.bookmarkEditTitle
                              : _bookmarkText(
                                  context,
                                  widget.isNovel
                                      ? 'bookmarkNovel'
                                      : 'bookmarkIllust',
                                ),
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          widget.title,
                          style: FuncSemanticTokens.of(context).title,
                        ),
                        Text(
                          '${widget.bookmarkKey.id}',
                          style: FuncSemanticTokens.of(context).caption,
                        ),
                        const SizedBox(height: 16),
                        SegmentedButton<BookmarkRestrict>(
                          segments: [
                            ButtonSegment(
                              value: BookmarkRestrict.public,
                              label: Text(l10n.restrictPublic),
                            ),
                            ButtonSegment(
                              value: BookmarkRestrict.private,
                              label: Text(l10n.restrictPrivate),
                            ),
                          ],
                          selected: {_restrict},
                          onSelectionChanged: (selection) =>
                              setState(() => _restrict = selection.first),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.bookmarkTags,
                            style: FuncSemanticTokens.of(context).body,
                          ),
                          const SizedBox(height: 8),
                          if (awaitingPrefill)
                            if (prefillFailed)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8,
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        l10n.bookmarkTagsLoadFailed,
                                        style: FuncSemanticTokens.of(context)
                                            .caption
                                            .copyWith(color: colorScheme.error),
                                      ),
                                    ),
                                    TextButton(
                                      onPressed: () => ref.invalidate(
                                        bookmarkDetailProvider(
                                          widget.bookmarkKey,
                                        ),
                                      ),
                                      child: Text(l10n.retry),
                                    ),
                                  ],
                                ),
                              )
                            else
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 12),
                                child: Center(
                                  child: SizedBox(
                                    width: 24,
                                    height: 24,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                ),
                              )
                          else ...[
                            if (_tags.isNotEmpty)
                              Wrap(
                                spacing: 8,
                                runSpacing: 4,
                                children: [
                                  for (final tag in _tags)
                                    InputChip(
                                      label: Text(tag),
                                      onDeleted: () => _removeTag(tag),
                                    ),
                                ],
                              ),
                            TextField(
                              controller: _tagInput,
                              decoration: InputDecoration(
                                hintText: l10n.bookmarkTagNewHint,
                                isDense: true,
                              ),
                              textInputAction: TextInputAction.done,
                              onSubmitted: _addTag,
                            ),
                            switch (suggestions) {
                              AsyncData(:final value) when value.isNotEmpty =>
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const SizedBox(height: 12),
                                    Text(
                                      l10n.bookmarkTagSuggestions,
                                      style: FuncSemanticTokens.of(
                                        context,
                                      ).caption,
                                    ),
                                    const SizedBox(height: 4),
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 4,
                                      children: [
                                        for (final suggestion in value)
                                          if (!_tags.contains(suggestion.name))
                                            FilterChip(
                                              label: Text(suggestion.name),
                                              selected: false,
                                              onSelected: (_) =>
                                                  _addTag(suggestion.name),
                                            ),
                                      ],
                                    ),
                                  ],
                                ),
                              _ => const SizedBox.shrink(),
                            },
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (_submitError != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
                      child: Text(
                        l10n.bookmarkOperationFailed('$_submitError'),
                        style: FuncSemanticTokens.of(
                          context,
                        ).caption.copyWith(color: colorScheme.error),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => unawaited(_attemptClose()),
                            child: Text(l10n.cancel),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          // Disabled until the existing bookmark's detail has
                          // prefilled: confirming earlier would overwrite a
                          // private/tagged bookmark with the default
                          // public+empty-tags values. Also disabled while a
                          // submit is in flight to dedupe taps.
                          child: FilledButton(
                            onPressed: (awaitingPrefill || _submitting)
                                ? null
                                : () => unawaited(_confirm()),
                            child: Text(l10n.confirm),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (!_closableFreely) {
      // Drag-to-dismiss bypasses PopScope entirely: BottomSheet.onClosing
      // calls Navigator.pop() directly, and imperative pops never consult
      // popDisposition. While dirty the sheet content claims vertical
      // drags itself and routes a downward release through the same
      // _attemptClose confirmation. The inner scroll view still wins
      // drags that start inside it, so scrolling is unaffected.
      sheet = GestureDetector(
        behavior: HitTestBehavior.translucent,
        onVerticalDragEnd: (details) {
          if ((details.primaryVelocity ?? 0) > 0) unawaited(_attemptClose());
        },
        child: sheet,
      );
    }
    return PopScope(
      canPop: _closableFreely,
      onPopInvokedWithResult: (didPop, _) {
        // Only maybePop paths (system back, barrier tap) deliver
        // didPop:false here; our own Navigator.pop() calls bypass the
        // scope, so confirmed closes cannot recurse back in.
        if (!didPop) unawaited(_attemptClose());
      },
      child: sheet,
    );
  }
}
