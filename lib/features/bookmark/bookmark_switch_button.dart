import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/bookmark/bookmark_actions.dart';
import '../../core/bookmark/bookmark_models.dart';
import '../../core/bookmark/bookmark_store.dart';

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

  void _showRestrictSheet(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    var restrict = BookmarkRestrict.public;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setState) => Container(
          decoration: BoxDecoration(
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(24),
              topRight: Radius.circular(24),
            ),
            color: colorScheme.surface,
          ),
          child: ConstrainedBox(
            // Beta56: fixed ~35% of screen height with the same spacer rhythm.
            constraints: BoxConstraints(
              minHeight: MediaQuery.heightOf(context) * 0.35,
              maxHeight: MediaQuery.heightOf(context) * 0.35,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Spacer(flex: 1),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 30),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          isNovel ? '收藏小说' : '收藏插画',
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      _RestrictSelect(
                        value: restrict,
                        onChanged: (value) {
                          if (value != null) {
                            setState(() => restrict = value);
                          }
                        },
                      ),
                    ],
                  ),
                ),
                const Spacer(flex: 1),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 30),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: const TextStyle(fontSize: 16)),
                      Text('$illustId', style: const TextStyle(fontSize: 12)),
                    ],
                  ),
                ),
                const Spacer(flex: 2),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  child: Row(
                    children: [
                      Expanded(
                        child: MaterialButton(
                          elevation: 0,
                          color: colorScheme.surfaceContainerHighest,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(40),
                            side: BorderSide.none,
                          ),
                          minWidth: double.infinity,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 20),
                            child: Text(
                              '取消',
                              style: TextStyle(
                                fontSize: 18,
                                color: colorScheme.onSurface,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          onPressed: () => Navigator.of(sheetContext).pop(),
                        ),
                      ),
                      const SizedBox(width: 15),
                      Expanded(
                        child: MaterialButton(
                          elevation: 0,
                          color: colorScheme.primary,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(40),
                          ),
                          minWidth: double.infinity,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 20),
                            child: Text(
                              '确定',
                              style: TextStyle(
                                fontSize: 18,
                                color: colorScheme.onPrimary,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          onPressed: () {
                            Navigator.of(sheetContext).pop();
                            ref
                                .read(bookmarkActionsProvider)
                                .addWithRestrict(_key, restrict);
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                const Spacer(flex: 1),
              ],
            ),
          ),
        ),
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

    // R5: failures restore the confirmed icon (non-optimistic means it never
    // moved) and surface an observable error.
    ref.listen<Object?>(bookmarkStoreProvider.select((s) => s[_key]?.error), (
      previous,
      next,
    ) {
      if (next != null && previous != next) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text('收藏操作失败: $next')));
      }
    });

    if (pending) {
      return Padding(
        padding: EdgeInsets.all(isButton ? 12 : 8),
        child: SizedBox(
          width: 24,
          height: 24,
          child: Center(
            child: CupertinoActivityIndicator(color: colorScheme.onSurface),
          ),
        ),
      );
    }

    final onLongPress = pending || bookmarked
        ? null
        : () => _showRestrictSheet(context, ref);

    if (isButton) {
      return GestureDetector(
        onLongPress: onLongPress,
        child: IconButton(
          splashRadius: 24,
          iconSize: 24,
          onPressed: () => ref.read(bookmarkActionsProvider).toggle(_key),
          icon: bookmarked
              ? Icon(Icons.favorite_sharp, color: colorScheme.primary)
              : const Icon(Icons.favorite_outline_sharp),
        ),
      );
    }
    return GestureDetector(
      onLongPress: onLongPress,
      onTap: () => ref.read(bookmarkActionsProvider).toggle(_key),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: bookmarked
            ? Icon(Icons.favorite_sharp, color: colorScheme.primary, size: 24)
            : const Icon(Icons.favorite_outline_sharp, size: 24),
      ),
    );
  }
}

/// Beta56 SelectButton replica: pill dropdown with toggle icon; the selected
/// value gets a primary border.
class _RestrictSelect extends StatelessWidget {
  const _RestrictSelect({required this.value, required this.onChanged});

  final BookmarkRestrict value;
  final ValueChanged<BookmarkRestrict?> onChanged;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(8),
      child: SizedBox(
        height: 35,
        child: DropdownButtonHideUnderline(
          child: DropdownButton<BookmarkRestrict>(
            elevation: 0,
            borderRadius: BorderRadius.circular(12),
            items: [
              for (final restrict in BookmarkRestrict.values)
                DropdownMenuItem<BookmarkRestrict>(
                  value: restrict,
                  child: Container(
                    height: 35,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(17),
                      border: value == restrict
                          ? Border.all(color: colorScheme.primary)
                          : null,
                      color: colorScheme.surfaceContainerHighest,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.toggle_off_outlined,
                          size: 12,
                          color: colorScheme.onSurface,
                        ),
                        const SizedBox(width: 10),
                        Text(
                          restrict == BookmarkRestrict.private ? '私密' : '公开',
                          style: const TextStyle(fontSize: 14),
                        ),
                        const SizedBox(width: 4),
                      ],
                    ),
                  ),
                ),
            ],
            value: value,
            onChanged: onChanged,
          ),
        ),
      ),
    );
  }
}
