import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/widgets/app_snack_bar.dart';
import '../../app/widgets/inline_translation.dart';
import '../../core/logging/crash_log.dart';
import '../../core/novel/novel_entity.dart';
import '../../core/translation/translation_service.dart';
import '../../l10n/context.dart';
import 'novel_layout.dart';
import 'novel_reader.dart';

/// Bilingual reading for the reader stage, page by page with the in-app
/// engine: the paragraphs of the current page are translated in one batch
/// and each translation shows under its paragraph; the reader translates
/// on as it turns — the current page first, then the page ahead. One batch
/// runs at a time. Translations stay for the stage's life, also while
/// bilingual reading is off, so turning it back on costs nothing.
mixin BilingualReading<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  /// The document being read.
  NovelEntity get bilingualNovel;

  /// The reader whose pages are translated.
  NovelReaderHandle get bilingualReader;

  bool bilingual = false;

  /// A batch is being translated.
  bool translatingPage = false;

  Map<String, String> _translations = const {};
  Map<String, String> _sources = const {};
  String? _sourcesVersion;

  /// What the reader shows under its paragraphs.
  Map<String, String> get pageTranslations =>
      bilingual ? _translations : const {};

  void toggleBilingual() {
    setState(() => bilingual = !bilingual);
    bilingualPageSettled();
  }

  /// The reader settled on a page — a turn or a relayout: translate what
  /// it shows, then the page after it.
  void bilingualPageSettled() {
    if (bilingual && !translatingPage) unawaited(_translateAhead());
  }

  /// The way out of a failure the translation settings can fix.
  void showTranslationSettings() => openTranslationSettings(context);

  Future<void> _translateAhead() async {
    final layout = bilingualReader.layout?.call();
    final page = bilingualReader.currentPage?.call();
    if (layout == null || page == null) return;
    _syncSources();
    var ids = _untranslated(layout, page);
    if (ids.isEmpty) ids = _untranslated(layout, page + 1);
    if (ids.isEmpty) return;
    final version = _sourcesVersion;
    final sources = [for (final id in ids) _sources[id]!];
    final target = Localizations.localeOf(context).languageCode;
    setState(() => translatingPage = true);
    List<String> results = const [];
    TranslationFailureKind? failure;
    try {
      results = await ref
          .read(translationServiceProvider)
          .translateAll(sources, targetLanguage: target);
      if (results.length != sources.length) {
        failure = TranslationFailureKind.malformed;
      }
    } on TranslationUnavailable catch (error) {
      failure = error.kind;
    } on TranslationError catch (error) {
      failure = error.kind;
    } on Object catch (error, stack) {
      CrashLog.record(error, stack);
      failure = TranslationFailureKind.other;
    }
    if (!mounted) return;
    if (failure != null) {
      final shown = bilingual;
      setState(() {
        translatingPage = false;
        bilingual = false;
      });
      if (shown) _showFailure(failure);
      return;
    }
    if (version != bilingualNovel.contentVersion) {
      // The body was replaced while the batch ran; none of it applies.
      setState(() => translatingPage = false);
      bilingualPageSettled();
      return;
    }
    // The reader relayouts with the new map and reports its page again,
    // which translates the next batch.
    setState(() {
      translatingPage = false;
      _translations = Map.unmodifiable({
        ..._translations,
        for (final (index, id) in ids.indexed)
          id: _shown(sources[index], results[index]),
      });
    });
  }

  /// Paragraph texts by id, rebuilt when the body changes; translations
  /// of the old body go with them.
  void _syncSources() {
    final novel = bilingualNovel;
    if (_sourcesVersion == novel.contentVersion) return;
    _sourcesVersion = novel.contentVersion;
    final blocks = novel.markup?.blocks ?? novel.paragraphs;
    _sources = {for (final block in blocks) block.id: block.plainText};
    _translations = const {};
  }

  /// Paragraphs on [page] with text and no translation yet, in order.
  List<String> _untranslated(NovelLayout layout, int page) {
    if (page < 0 || page >= layout.pages.length) return const [];
    final ids = <String>{};
    for (final line in layout.pages[page].lines) {
      final id = line.paragraphId;
      if (line.isTranslation || _translations.containsKey(id)) continue;
      if ((_sources[id] ?? '').trim().isEmpty) continue;
      ids.add(id);
    }
    return ids.toList();
  }

  void _showFailure(TranslationFailureKind kind) {
    showAppSnackBar(
      context,
      translationFailureText(context, kind),
      action: translationNeedsSettings(kind)
          ? PromptAction(
              label: context.l10n.translationOpenSettings,
              onPressed: showTranslationSettings,
            )
          : null,
    );
  }
}

final _lineBreaks = RegExp(r'\s*\n\s*');

/// What shows under [source]: nothing when the engine handed it back
/// unchanged (it is already in the target language), otherwise the
/// translation as one run of text.
String _shown(String source, String translation) {
  final text = translation.trim().replaceAll(_lineBreaks, ' ');
  return text == source.trim() ? '' : text;
}
