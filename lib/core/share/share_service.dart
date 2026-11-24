import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart' as share_plus;

/// Typed share payload for one Pixiv destination. `text` follows the format
/// `"{title} | {author} #Pixiv {url}"`.
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
/// (desktop builds without a sharesheet, plugin missing) [share] falls back to
/// the clipboard so the action never dead-ends.
abstract interface class ShareService {
  Future<ShareOutcome> share(SharePayload payload, {Rect? sharePositionOrigin});

  Future<void> shareFiles(
    List<share_plus.XFile> files, {
    String? subject,
    String? text,
    Rect? sharePositionOrigin,
  });
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

  @override
  Future<void> shareFiles(
    List<share_plus.XFile> files, {
    String? subject,
    String? text,
    Rect? sharePositionOrigin,
  }) async {
    await share_plus.SharePlus.instance.share(
      share_plus.ShareParams(
        files: files,
        subject: subject,
        text: text,
        sharePositionOrigin: sharePositionOrigin,
      ),
    );
  }
}

final shareServiceProvider = Provider<ShareService>(
  (ref) => const SystemShareService(),
);

Rect? _viewportRectOf(BuildContext context) {
  final size = MediaQuery.maybeSizeOf(context);
  if (size == null || size.isEmpty) return null;
  return Offset.zero & size;
}

Rect _centeredFallback(Rect viewport) =>
    Rect.fromCenter(center: viewport.center, width: 1, height: 1);

/// Clamps [rect] into the active viewport so iPadOS `UIPopoverPresentationController`
/// always receives a finite, non-empty, on-screen anchor (passing `null` or an
/// out-of-bounds rect causes `share_plus` to throw on iPad).
Rect? clampShareOrigin(BuildContext context, Rect? rect) {
  final viewport = _viewportRectOf(context);
  if (rect != null &&
      rect.left.isFinite &&
      rect.top.isFinite &&
      rect.width.isFinite &&
      rect.height.isFinite &&
      !rect.isEmpty) {
    if (viewport == null) return rect;
    final clipped = rect.intersect(viewport);
    if (!clipped.isEmpty) return clipped;
  }
  return viewport == null ? null : _centeredFallback(viewport);
}

/// Origin rect for the sharesheet popover on iPadOS. Resolves [context]'s
/// global bounds clipped to the active viewport, falling back to a 1x1 center
/// anchor when [context] is detached, unlaid-out, or scrolled off-screen.
Rect? shareOriginOf(BuildContext context) {
  final box = context.findRenderObject();
  if (box is RenderBox && box.attached && box.hasSize && !box.size.isEmpty) {
    final origin = box.localToGlobal(Offset.zero);
    if (origin.dx.isFinite && origin.dy.isFinite) {
      return clampShareOrigin(context, origin & box.size);
    }
  }
  return clampShareOrigin(context, null);
}

/// Origin rect anchored at a pointer/tap [globalPosition], clamped inside the
/// active viewport for context-menu share actions on iPadOS.
Rect? shareOriginAt(BuildContext context, Offset globalPosition) {
  final viewport = _viewportRectOf(context);
  if (viewport == null) {
    if (!globalPosition.dx.isFinite || !globalPosition.dy.isFinite) return null;
    return Rect.fromCenter(center: globalPosition, width: 1, height: 1);
  }
  if (!globalPosition.dx.isFinite || !globalPosition.dy.isFinite) {
    return _centeredFallback(viewport);
  }
  final maxX = viewport.width > 1 ? viewport.width - 1 : 0.0;
  final maxY = viewport.height > 1 ? viewport.height - 1 : 0.0;
  final x = globalPosition.dx.clamp(0.0, maxX).toDouble();
  final y = globalPosition.dy.clamp(0.0, maxY).toDouble();
  return Rect.fromLTWH(x, y, 1, 1);
}
