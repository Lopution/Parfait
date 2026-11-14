import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/pixiv_image.dart';
import '../../app/theme/func_semantic_tokens.dart';
import '../../core/illust/illust_detail_controller.dart';
import '../../core/novel/novel_entity.dart';
import '../../core/settings/app_settings.dart';
import '../../core/settings/settings_controller.dart';
import '../../l10n/context.dart';
import 'novel_reader_stage.dart' show novelReaderHintAlpha;

/// A novel's image on its page, at the novel image quality. An uploaded
/// image comes from the novel's payload; a Pixiv work's page from the
/// work's detail, the payload's preview standing in while it loads. An
/// image that cannot be shown says so in its place.
class NovelIllustration extends ConsumerWidget {
  const NovelIllustration({
    super.key,
    required this.novel,
    required this.image,
    required this.color,
    required this.onTap,
  });

  final NovelEntity novel;
  final NovelImageLoadRequest image;

  /// The page's text colour, which the placeholder and notices take.
  final Color color;
  final ValueChanged<NovelImageLoadRequest>? onTap;

  static const _placeholderAlpha = 0.08;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final quality = ref.watch(novelImageQualityProvider);
    final illustId = image.illustId;
    if (illustId == null) {
      return switch (novel.uploadedImage(image)) {
        final urls? => _image(
          context,
          quality == DetailQuality.original ? urls.original : urls.large,
        ),
        null => _unavailable(context),
      };
    }
    final page = (image.page ?? 1) - 1;
    final thumb = novel.illustThumb(image);
    return switch (ref.watch(illustDetailControllerProvider(illustId))) {
      AsyncData(value: IllustDetailReady(:final entity))
          when page < entity.pageCount =>
        _image(context, entity.detailUrlAt(page, quality)),
      AsyncData(
        value: IllustDetailReady() ||
            IllustDetailRestricted() ||
            IllustDetailNotFound(),
      ) =>
        _unavailable(context),
      AsyncData(value: IllustDetailError()) || AsyncError() => switch (thumb) {
        final thumb? => _image(context, thumb),
        null => _notice(
          context,
          context.l10n.illustDetailLoadFailed,
          action: TextButton(
            onPressed: () => ref
                .read(illustDetailControllerProvider(illustId).notifier)
                .reload(),
            child: Text(context.l10n.retry),
          ),
        ),
      },
      _ => switch (thumb) {
        final thumb? => _image(context, thumb),
        null => Center(child: _placeholder()),
      },
    };
  }

  /// Contained and centred; only the image takes the tap, so the margins
  /// beside it keep the page's turn zones.
  Widget _image(BuildContext context, String url) {
    final onTap = this.onTap;
    final open = onTap == null ? null : () => onTap(image);
    return Center(
      child: Semantics(
        button: open != null,
        label: context.l10n.novelIllustration,
        onTap: open,
        child: GestureDetector(
          onTap: open,
          child: PixivImage(
            url: url,
            fit: BoxFit.contain,
            sizeToImage: true,
            memCacheWidth: PixivImage.screenDecodeWidthOf(context),
            placeholderWidget: _placeholder(),
          ),
        ),
      ),
    );
  }

  Widget _placeholder() => AspectRatio(
    aspectRatio: 1,
    child: ColoredBox(color: color.withValues(alpha: _placeholderAlpha)),
  );

  Widget _unavailable(BuildContext context) =>
      _notice(context, context.l10n.novelIllustrationUnavailable);

  Widget _notice(BuildContext context, String text, {Widget? action}) {
    final faint = color.withValues(alpha: novelReaderHintAlpha);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.image_not_supported_outlined, color: faint),
          const SizedBox(height: FuncSpacing.sm),
          Text(
            text,
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: faint),
          ),
          ?action,
        ],
      ),
    );
  }
}
