import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart' as share_plus;

/// Typed share payload for one Pixiv destination. `text` follows the format
/// proven by Shaft's `ACTION_SEND` body: `"{title} | {author} #Pixiv {url}"`.
class SharePayload {
  const SharePayload({
    required this.title,
    required this.author,
    required this.url,
  });

  factory SharePayload.illust({
    required int id,
    required String title,
    required String author,
  }) => SharePayload(
    title: title,
    author: author,
    url: 'https://www.pixiv.net/artworks/$id',
  );

  factory SharePayload.novel({
    required int id,
    required String title,
    required String author,
  }) => SharePayload(
    title: title,
    author: author,
    url: 'https://www.pixiv.net/novel/show.php?id=$id',
  );

  factory SharePayload.user({required int id, required String name}) =>
      SharePayload(
        title: name,
        author: name,
        url: 'https://www.pixiv.net/users/$id',
      );

  final String title;
  final String author;
  final String url;

  String get text => '$title | $author #Pixiv $url';
}

/// What a share attempt ended up doing.
enum ShareOutcome {
  /// The platform share sheet took the payload.
  openedSheet,

  /// The sheet was unavailable/failed, so the payload went to the clipboard
  /// instead — the caller should surface the copy confirmation.
  copiedToClipboard,
}

/// Platform share boundary. The system sheet is tried first; when it throws
/// (desktop builds without a sharesheet, plugin missing) the payload falls
/// back to the clipboard so the action never dead-ends.
abstract interface class ShareService {
  Future<ShareOutcome> share(SharePayload payload, {Rect? sharePositionOrigin});
}

class SystemShareService implements ShareService {
  const SystemShareService();

  @override
  Future<ShareOutcome> share(
    SharePayload payload, {
    Rect? sharePositionOrigin,
  }) async {
    try {
      await share_plus.SharePlus.instance.share(
        share_plus.ShareParams(
          text: payload.text,
          sharePositionOrigin: sharePositionOrigin,
        ),
      );
      return ShareOutcome.openedSheet;
    } on Object {
      await Clipboard.setData(ClipboardData(text: payload.text));
      return ShareOutcome.copiedToClipboard;
    }
  }
}

final shareServiceProvider = Provider<ShareService>(
  (ref) => const SystemShareService(),
);

/// Origin rect for the sharesheet popover on large screens (iPad requires
/// it). Resolves the widget's global bounds; `null` when the context is not
/// laid out yet, which share_plus treats as a centered anchor.
Rect? shareOriginOf(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.hasSize) return null;
  return box.localToGlobal(Offset.zero) & box.size;
}
