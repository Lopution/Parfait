import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/logging/crash_log.dart';
import '../../core/translation/translation_service.dart';
import '../../l10n/context.dart';
import '../clipboard.dart';
import '../motion/spring_size.dart';
import '../motion/state_fade.dart';
import '../theme/func_semantic_tokens.dart';

/// Inline translation for the State that shows the original text: idle →
/// translating → translations or a failure, shown below the original by a
/// [TranslationPanel]. Asking again while a result is shown hides it.
mixin InlineTranslation<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  bool translating = false;
  List<String>? translations;
  TranslationFailureKind? translationFailure;

  bool get translationShown =>
      translations != null || translationFailure != null;

  /// Translates [sources] (non-blank, in order) into the app language, or
  /// hides the result already shown.
  Future<void> toggleTranslation(List<String> sources) async {
    if (translating) return;
    if (translationShown) {
      setState(() {
        translations = null;
        translationFailure = null;
      });
      return;
    }
    setState(() => translating = true);
    final target = Localizations.localeOf(context).languageCode;
    TranslationFailureKind? failure;
    List<String>? result;
    try {
      result = await ref
          .read(translationServiceProvider)
          .translateAll(sources, targetLanguage: target);
    } on TranslationUnavailable catch (error) {
      failure = error.kind;
    } on TranslationError catch (error) {
      failure = error.kind;
    } on Object catch (error, stack) {
      CrashLog.record(error, stack);
      failure = TranslationFailureKind.other;
    }
    if (!mounted) return;
    setState(() {
      translating = false;
      translations = result;
      translationFailure = failure;
    });
  }
}

/// The translate button of a heading row: the translate glyph, primary
/// while a result is shown (a second press hides it), disabled while a
/// request runs.
class TranslateIconButton extends StatelessWidget {
  const TranslateIconButton({
    super.key,
    required this.translating,
    required this.shown,
    required this.onPressed,
  });

  final bool translating;
  final bool shown;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return IconButton(
      tooltip: shown ? l10n.translationHide : l10n.translateAction,
      isSelected: shown,
      icon: const Icon(Icons.translate),
      selectedIcon: Icon(
        Icons.translate,
        color: Theme.of(context).colorScheme.primary,
      ),
      onPressed: translating ? null : onPressed,
    );
  }
}

/// What an [InlineTranslation] shows below the original: progress, the
/// translations, or the failure. It grows and shrinks on a spring instead
/// of popping in.
class TranslationPanel extends StatelessWidget {
  const TranslationPanel({
    super.key,
    required this.translating,
    required this.translations,
    required this.failure,
    this.emphasizeFirst = false,
    this.copyable = false,
  });

  final bool translating;
  final List<String>? translations;
  final TranslationFailureKind? failure;

  /// The first translation is a title.
  final bool emphasizeFirst;

  /// Adds a copy button for the translation (where the text itself is too
  /// short to select comfortably, such as a tag name).
  final bool copyable;

  @override
  Widget build(BuildContext context) {
    final translations = this.translations;
    final failure = this.failure;
    return SpringSize(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (translating)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: FuncSpacing.sm),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          if (translations != null)
            StateFade.onMount(child: _result(context, translations)),
          if (failure != null)
            StateFade.onMount(child: _TranslationFailure(kind: failure)),
        ],
      ),
    );
  }

  Widget _result(BuildContext context, List<String> translations) {
    final theme = Theme.of(context);
    final joined = translations.join('\n');
    return Container(
      margin: const EdgeInsets.only(top: FuncSpacing.xs),
      padding: const EdgeInsets.all(FuncSpacing.sm),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: FuncShape.control,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  context.l10n.translationResult,
                  style: TextStyle(color: theme.colorScheme.primary),
                ),
              ),
              if (copyable)
                IconButton(
                  tooltip: context.l10n.tagActionCopyTranslation,
                  icon: const Icon(Icons.copy_outlined, size: 20),
                  onPressed: () => unawaited(
                    copyToClipboard(
                      context,
                      joined,
                      message: context.l10n.translationCopied,
                    ),
                  ),
                ),
            ],
          ),
          const Divider(height: 12),
          for (final (index, text) in translations.indexed) ...[
            if (index > 0) const SizedBox(height: FuncSpacing.sm),
            SelectableText(
              text,
              style: emphasizeFirst && index == 0
                  ? theme.textTheme.titleSmall
                  : null,
            ),
          ],
        ],
      ),
    );
  }
}

/// A failed translation: what went wrong, and the way to the translation
/// settings when the engine is off or not set up.
class _TranslationFailure extends StatelessWidget {
  const _TranslationFailure({required this.kind});

  final TranslationFailureKind kind;

  @override
  Widget build(BuildContext context) {
    final text = Text(
      translationFailureText(context, kind),
      style: TextStyle(color: Theme.of(context).colorScheme.error),
    );
    return Padding(
      padding: const EdgeInsets.only(top: FuncSpacing.xs),
      child: translationNeedsSettings(kind)
          ? Row(
              children: [
                Expanded(child: text),
                TextButton(
                  onPressed: () => openTranslationSettings(context),
                  child: Text(context.l10n.translationOpenSettings),
                ),
              ],
            )
          : text,
    );
  }
}

/// The engine is off or not set up: the fix is in the translation settings.
bool translationNeedsSettings(TranslationFailureKind kind) =>
    kind == TranslationFailureKind.disabled ||
    kind == TranslationFailureKind.notConfigured ||
    kind == TranslationFailureKind.invalidCredentials;

/// Opens the translation settings. From inside a sheet or a dialog the popup
/// closes first, so the page is not pushed underneath it.
void openTranslationSettings(BuildContext context) {
  final router = GoRouter.of(context);
  if (ModalRoute.of(context) is PopupRoute) Navigator.of(context).pop();
  unawaited(router.push<void>('/settings/translate'));
}

String translationFailureText(
  BuildContext context,
  TranslationFailureKind kind,
) {
  final l10n = context.l10n;
  return switch (kind) {
    TranslationFailureKind.disabled => l10n.translationUnavailable,
    TranslationFailureKind.notConfigured => l10n.translationNotConfigured,
    TranslationFailureKind.invalidCredentials =>
      l10n.translationInvalidCredentials,
    TranslationFailureKind.rateLimited => l10n.translationRateLimited,
    TranslationFailureKind.rejected => l10n.translationRejected,
    TranslationFailureKind.network ||
    TranslationFailureKind.malformed ||
    TranslationFailureKind.unsupportedLanguage ||
    TranslationFailureKind.other => l10n.translationFailed,
  };
}
