import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/physics.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/bookmark/bookmark_actions.dart';
import '../../core/bookmark/bookmark_models.dart';
import '../../core/bookmark/bookmark_store.dart';
import '../../core/bookmark/bookmark_tag_providers.dart';
import '../../core/errors/error_category.dart';
import '../haptics/app_haptics.dart';
import '../layout/app_breakpoints.dart';
import '../layout/content_widths.dart';
import '../motion/app_overlays.dart';
import '../motion/motion_tokens.dart';
import '../theme/func_semantic_tokens.dart';
import '../theme/func_tokens.dart';
import '../widgets/errors/error_details.dart';
import '../../l10n/context.dart';
import '../../l10n/lookup.dart';
import 'settings/settings_control.dart';
import 'app_choice_chip.dart';
import 'undo_snack_bar.dart';

String _bookmarkText(BuildContext context, String key) =>
    l10nLookup(context.l10n, key);

/// Toggles the bookmark of [key]. The heart flips on this frame
/// (optimistic), so the haptic plays now too: add → success, remove →
/// select. A failure rolls the heart back with an error haptic; the button
/// reports the cause. A confirmed removal offers Undo, which restores the
/// old visibility and tags.
Future<void> toggleBookmarkWithUndo(
  BuildContext context,
  BookmarkKey key,
) async {
  // Read up front: the toggle may outlive the widget that started it.
  final container = ProviderScope.containerOf(context, listen: false);
  final store = container.read(bookmarkStoreProvider.notifier);
  final wish = !(store.entryOf(key)?.shown ?? false);
  wish ? AppHaptics.success() : AppHaptics.select();
  final removed = await container.read(bookmarkActionsProvider).toggle(key);
  if (store.entryOf(key)?.error != null) {
    AppHaptics.error();
    return;
  }
  if (removed != null && context.mounted) {
    showUndoSnackBar(
      context,
      context.l10n.bookmarkRemoved,
      onUndo: (container) => container
          .read(bookmarkActionsProvider)
          .addWithRestrict(removed.key, removed.restrict, tags: removed.tags),
    );
  }
}

/// Peak overshoot of the heart pop above its rest scale of 1.
const _heartPopPeak = 0.25;

/// The particle burst around a heart that was just added.
const _burstDuration = Duration(milliseconds: 450);

/// Initial velocity that carries an underdamped spring released at rest
/// position up to [_heartPopPeak]. For x(t) = v/ωd · e^(−ζωt) · sin(ωd t)
/// the first peak is v/ω · e^(−ζθ/√(1−ζ²)) with θ = atan(√(1−ζ²)/ζ).
double _heartPopVelocity(SpringDescription spring) {
  final omega = math.sqrt(spring.stiffness / spring.mass);
  final zeta = spring.damping / (2 * math.sqrt(spring.stiffness * spring.mass));
  final root = math.sqrt(1 - zeta * zeta);
  final theta = math.atan(root / zeta);
  return _heartPopPeak * omega * math.exp(zeta * theta / root);
}

/// Beta56 BookmarkSwitchButton replica driven entirely by the shared
/// BookmarkStore: heart icon (isButton app-bar/row variant), short-press
/// toggle and long-press create/edit sheet (suppressed while a request is
/// unsettled, R6). The heart shows the user's wish at once
/// ([BookmarkEntry.shown]); an add pops it to 1.25× on the
/// [MotionSpring.expressiveSpatialFast] spring with a particle burst — only
/// for the user's own tap or sheet here, never for a refresh, a replay or a
/// first build.
class BookmarkSwitchButton extends ConsumerStatefulWidget {
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

  @override
  ConsumerState<BookmarkSwitchButton> createState() =>
      _BookmarkSwitchButtonState();
}

class _BookmarkSwitchButtonState extends ConsumerState<BookmarkSwitchButton>
    with TickerProviderStateMixin {
  /// The heart's scale; unbounded so the pop may pass 1.
  late final AnimationController _pop = AnimationController.unbounded(
    vsync: this,
    value: 1,
  );

  /// The particle burst; at rest (1) it paints nothing.
  late final AnimationController _burst = AnimationController(
    vsync: this,
    value: 1,
  );

  BookmarkKey get _key => BookmarkKey(
    widget.isNovel ? BookmarkEntityType.novel : BookmarkEntityType.illust,
    widget.illustId,
  );

  @override
  void didUpdateWidget(BookmarkSwitchButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A recycled list slot now shows another work: drop the old pop.
    if (oldWidget.illustId != widget.illustId ||
        oldWidget.isNovel != widget.isNovel) {
      _pop.value = 1;
      _burst.value = 1;
    }
  }

  @override
  void dispose() {
    _pop.dispose();
    _burst.dispose();
    super.dispose();
  }

  /// Pops the heart and bursts particles when [added] for the work still
  /// shown.
  void _popIfAdded(bool added, BookmarkKey key) {
    if (!added || !mounted || key != _key) return;
    final spring = MotionTokens.spring(
      context,
      MotionSpring.expressiveSpatialFast,
    );
    if (spring == null) return;
    _pop.animateWith(
      SpringSimulation(
        spring,
        1,
        1,
        _heartPopVelocity(spring),
        snapToEnd: true,
      ),
    );
    _burst.duration = MotionTokens.resolve(context, _burstDuration);
    _burst.forward(from: 0);
  }

  void _toggle() {
    final key = _key;
    final shown = ref.read(bookmarkStoreProvider)[key]?.shown ?? false;
    _popIfAdded(!shown, key);
    unawaited(toggleBookmarkWithUndo(context, key));
  }

  Future<void> _showBookmarkSheet({required bool bookmarked}) async {
    AppHaptics.longPress();
    final key = _key;
    final added = await showAppBottomSheet<bool>(
      context: context,
      backgroundColor: FuncTokens.transparent,
      isScrollControlled: true,
      builder: (sheetContext) => _BookmarkEditSheet(
        bookmarkKey: key,
        title: widget.title,
        isNovel: widget.isNovel,
        initiallyBookmarked: bookmarked,
      ),
    );
    _popIfAdded(added ?? false, key);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isPlaceholder) return const SizedBox.shrink();
    final colorScheme = Theme.of(context).colorScheme;
    final entry = ref.watch(bookmarkStoreProvider.select((s) => s[_key]));
    final bookmarked = entry?.shown ?? false;
    final unsettled = entry?.isUnsettled ?? false;
    final semanticLabel =
        '${_bookmarkText(context, widget.isNovel ? 'bookmarkNovel' : 'bookmarkIllust')}: ${widget.title}';

    // R5: a failure rolls the heart back to the confirmed value and
    // surfaces an observable error.
    ref.listen<Object?>(bookmarkStoreProvider.select((s) => s[_key]?.error), (
      previous,
      next,
    ) {
      if (next != null && previous != next) {
        showErrorSnackBar(
          context,
          action: context.l10n.bookmarkOperationFailed,
          error: next,
        );
      }
    });

    // Long-press opens the sheet in both directions: create for a fresh work,
    // edit (prefilled from bookmark detail) for an already-bookmarked one.
    final onLongPress = unsettled
        ? null
        : () => _showBookmarkSheet(bookmarked: bookmarked);
    final heart = Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _BurstPainter(
                progress: _burst,
                colors: [colorScheme.primary, colorScheme.tertiary],
              ),
            ),
          ),
        ),
        ScaleTransition(
          scale: _pop,
          child: bookmarked
              ? Icon(Icons.favorite_sharp, color: colorScheme.primary, size: 24)
              : const Icon(Icons.favorite_outline_sharp, size: 24),
        ),
      ],
    );

    if (widget.isButton) {
      return Semantics(
        container: true,
        button: true,
        toggled: bookmarked,
        label: semanticLabel,
        onTap: _toggle,
        onLongPress: onLongPress,
        child: GestureDetector(
          excludeFromSemantics: true,
          onLongPress: onLongPress,
          child: ExcludeSemantics(
            child: IconButton(
              splashRadius: 24,
              iconSize: 24,
              onPressed: _toggle,
              icon: heart,
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
      onTap: _toggle,
      onLongPress: onLongPress,
      child: GestureDetector(
        excludeFromSemantics: true,
        onLongPress: onLongPress,
        onTap: _toggle,
        child: Padding(
          padding: const EdgeInsets.all(FuncSpacing.sm),
          child: heart,
        ),
      ),
    );
  }
}

/// A ring of dots flying out of the heart and shrinking away, painted around
/// its 24px box without taking layout space.
class _BurstPainter extends CustomPainter {
  _BurstPainter({required this.progress, required this.colors})
    : super(repaint: progress);

  final Animation<double> progress;
  final List<Color> colors;

  static const _count = 8;
  static const _startRadius = 8.0;
  static const _endRadius = 20.0;
  static const _dotRadius = 2.5;

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress.value;
    if (t >= 1) return;
    final travel = Curves.easeOutCubic.transform(t);
    final distance = _startRadius + (_endRadius - _startRadius) * travel;
    final dot = _dotRadius * (1 - t);
    final center = size.center(Offset.zero);
    final paint = Paint();
    for (var i = 0; i < _count; i++) {
      final angle = (i + 0.5) * 2 * math.pi / _count;
      paint.color = colors[i % colors.length];
      canvas.drawCircle(
        center + Offset(math.cos(angle), math.sin(angle)) * distance,
        dot,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_BurstPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      !listEquals(oldDelegate.colors, colors);
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

  /// [_tagInput] text not yet added counts as draft content: `_confirm`
  /// folds it into the submitted tags, so closing over pending text must
  /// go through the same discard prompt as an added tag.
  bool get _isDirty =>
      _restrict != _initialRestrict ||
      !listEquals(_tags, _initialTags) ||
      _tagInput.text.trim().isNotEmpty;

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
    final before =
        ref.read(bookmarkStoreProvider)[widget.bookmarkKey]?.bookmarked ??
        false;
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
    final entry = ref.read(bookmarkStoreProvider)[widget.bookmarkKey];
    // Same rule as [toggleBookmark]: a queued submit stays silent.
    if (entry != null && !entry.isPending) {
      entry.error != null ? AppHaptics.error() : AppHaptics.success();
    }
    if (!mounted) return;
    final error = entry?.error;
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
    // either way the draft is accepted and the sheet closes (D6). The
    // result tells the button whether a new bookmark landed (heart pop).
    final added =
        entry != null && !entry.isPending && entry.bookmarked && !before;
    Navigator.of(context).pop(added);
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
    // The modal route does not consume viewInsets: the sheet lifts above
    // the IME via a transparent bottom margin and its height band is
    // measured against the remaining visible height, so the field and the
    // confirm row stay reachable instead of sliding under the keyboard.
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    final availableHeight = MediaQuery.heightOf(context) - keyboardInset;
    Widget sheet = Align(
      // heightFactor shrink-wraps vertically: a bare Center would expand to
      // the sheet slot's max height. On expanded surfaces the form column
      // caps at ContentWidths.form and stays centered (parent §5.5).
      alignment: Alignment.topCenter,
      heightFactor: 1.0,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: contentMaxWidth),
        child: Container(
          margin: EdgeInsets.only(bottom: keyboardInset),
          decoration: BoxDecoration(
            borderRadius: FuncShape.sheet,
            color: colorScheme.surfaceContainer,
          ),
          child: SafeArea(
            top: false,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: availableHeight * 0.35,
                maxHeight: availableHeight * 0.75,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: FuncSpacing.lg),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: FuncSpacing.xl,
                    ),
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
                        const SizedBox(height: FuncSpacing.sm),
                        Text(
                          widget.title,
                          style: FuncSemanticTokens.of(context).title,
                        ),
                        Text(
                          '${widget.bookmarkKey.id}',
                          style: FuncSemanticTokens.of(context).caption,
                        ),
                        const SizedBox(height: FuncSpacing.lg),
                        // The sheet paints its colour on a DecoratedBox; the
                        // row needs its own Material for the ink.
                        Material(
                          type: MaterialType.transparency,
                          child: SettingsControl(
                            contentPadding: EdgeInsets.zero,
                            title: Text(l10n.restrictPrivate),
                            value: _restrict == BookmarkRestrict.private,
                            // The whole edit area is inert while an existing
                            // bookmark's detail is still in flight: the tag
                            // editor is replaced by the spinner and the
                            // switch locks too — a mid-load restrict change
                            // would dirty the draft so the arriving prefill
                            // kept the empty tag list and overwrote the
                            // persisted tags.
                            onChanged: (awaitingPrefill && !prefillFailed)
                                ? null
                                : (private) => setState(
                                    () => _restrict = private
                                        ? BookmarkRestrict.private
                                        : BookmarkRestrict.public,
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: FuncSpacing.lg),
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(
                        horizontal: FuncSpacing.xl,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.bookmarkTags,
                            style: FuncSemanticTokens.of(context).body,
                          ),
                          const SizedBox(height: FuncSpacing.sm),
                          if (awaitingPrefill)
                            if (prefillFailed)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: FuncSpacing.sm,
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
                                padding: EdgeInsets.symmetric(
                                  vertical: FuncSpacing.md,
                                ),
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
                                    const SizedBox(height: FuncSpacing.md),
                                    Text(
                                      l10n.bookmarkTagSuggestions,
                                      style: FuncSemanticTokens.of(
                                        context,
                                      ).caption,
                                    ),
                                    const SizedBox(height: FuncSpacing.xs),
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 4,
                                      children: [
                                        for (final suggestion in value)
                                          if (!_tags.contains(suggestion.name))
                                            AppChoiceChip.toggle(
                                              label: Text(suggestion.name),
                                              selected: false,
                                              onChanged: (_) =>
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
                  const SizedBox(height: FuncSpacing.lg),
                  if (_submitError != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        FuncSpacing.xl,
                        0,
                        FuncSpacing.xl,
                        FuncSpacing.md,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.errorWithReason(
                              l10n.bookmarkOperationFailed,
                              errorCategoryText(
                                context,
                                categorizeError(_submitError!),
                              ),
                            ),
                            style: FuncSemanticTokens.of(
                              context,
                            ).caption.copyWith(color: colorScheme.error),
                          ),
                          ErrorDetails(error: _submitError!),
                        ],
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: FuncSpacing.xl,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => unawaited(_attemptClose()),
                            child: Text(l10n.cancel),
                          ),
                        ),
                        const SizedBox(width: FuncSpacing.md),
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
                  const SizedBox(height: FuncSpacing.lg),
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
