import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/bookmark/bookmark_models.dart';
import '../../core/entity/illust_store.dart';
import '../../core/novel/novel_store.dart';
import '../../l10n/context.dart';
import '../haptics/app_haptics.dart';
import '../theme/func_semantic_tokens.dart';
import 'app_choice_chip.dart';
import 'tag_chips.dart';

/// A cached tag on the work itself (illust or novel), used to offer one-tap
/// additions in the bookmark sheet without an extra network round trip.
typedef CachedWorkTag = ({String name, String? translated});

/// Reads deduplicated cached tags for [key] from the in-memory illust or novel
/// store. Returns empty if the work has not been cached yet.
List<CachedWorkTag> readCachedWorkTags(WidgetRef ref, BookmarkKey key) {
  final Iterable<CachedWorkTag> raw = switch (key.type) {
    BookmarkEntityType.illust =>
      ref
              .read(illustStoreProvider)
              .get(key.id)
              ?.tags
              .map((t) => (name: t.name, translated: t.translatedName)) ??
          const [],
    BookmarkEntityType.novel =>
      ref
              .read(novelStoreProvider)[key.id]
              ?.tags
              .map((t) => (name: t.name, translated: t.translatedName)) ??
          const [],
  };
  final result = <CachedWorkTag>[];
  final seen = <String>{};
  for (final tag in raw) {
    final name = tag.name.trim();
    if (name.isEmpty || !seen.add(name)) continue;
    final translated = tag.translated?.trim();
    result.add((
      name: name,
      translated: translated == null || translated.isEmpty ? null : translated,
    ));
  }
  return result;
}

/// Tag editor body inside the bookmark sheet: selected tag chips, free-text
/// entry, one-tap work tags (`THEME-07` neutral [TagChip] pills), and the
/// user's own bookmark tag suggestions.
class BookmarkTagEditorBody extends StatelessWidget {
  const BookmarkTagEditorBody({
    super.key,
    required this.selectedTags,
    required this.tagInput,
    required this.workTags,
    required this.suggestions,
    required this.onAddTag,
    required this.onRemoveTag,
  });

  final List<String> selectedTags;
  final TextEditingController tagInput;
  final List<CachedWorkTag> workTags;
  final AsyncValue<List<UserBookmarkTag>> suggestions;
  final ValueChanged<String> onAddTag;
  final ValueChanged<String> onRemoveTag;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tokens = FuncSemanticTokens.of(context);
    final atLimit = selectedTags.length >= kMaxBookmarkTags;
    final availableWorkTags = [
      for (final tag in workTags)
        if (!selectedTags.contains(tag.name)) tag,
    ];
    final availableSuggestions = switch (suggestions) {
      AsyncData(:final value) => [
        for (final suggestion in value)
          if (!selectedTags.contains(suggestion.name)) suggestion,
      ],
      _ => const <UserBookmarkTag>[],
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (selectedTags.isNotEmpty)
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final tag in selectedTags)
                InputChip(label: Text(tag), onDeleted: () => onRemoveTag(tag)),
            ],
          ),
        TextField(
          controller: tagInput,
          enabled: !atLimit,
          decoration: InputDecoration(
            hintText: atLimit
                ? l10n.bookmarkTagLimitReached
                : l10n.bookmarkTagNewHint,
            isDense: true,
          ),
          textInputAction: TextInputAction.done,
          onSubmitted: onAddTag,
        ),
        if (availableWorkTags.isNotEmpty && !atLimit) ...[
          const SizedBox(height: FuncSpacing.md),
          Text(l10n.bookmarkWorkTags, style: tokens.caption),
          const SizedBox(height: FuncSpacing.xs),
          Wrap(
            children: [
              for (final tag in availableWorkTags)
                TagChip(
                  label: tag.name,
                  translated: tag.translated,
                  onTap: () {
                    AppHaptics.toggleOn();
                    onAddTag(tag.name);
                  },
                ),
            ],
          ),
        ],
        if (availableSuggestions.isNotEmpty && !atLimit) ...[
          const SizedBox(height: FuncSpacing.md),
          Text(l10n.bookmarkTagSuggestions, style: tokens.caption),
          const SizedBox(height: FuncSpacing.xs),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final suggestion in availableSuggestions)
                AppChoiceChip.toggle(
                  label: Text(suggestion.name),
                  selected: false,
                  onChanged: (_) => onAddTag(suggestion.name),
                ),
            ],
          ),
        ],
      ],
    );
  }
}
