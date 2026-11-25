import '../entity/illust_entity.dart';
import '../network/pixiv_http_client.dart';
import '../user/user_repository.dart';

/// Result of walking every author-work page for a bulk download
/// (static works and ugoira separated, hard cap enforced).
class AuthorWorksResult {
  const AuthorWorksResult({
    required this.works,
    this.ugoiraWorks = const [],
    required this.truncated,
  });

  /// Illust+manga static works in enumeration order.
  final List<IllustEntity> works;

  /// Ugoira works discovered during enumeration (opted into separately).
  final List<IllustEntity> ugoiraWorks;

  /// True when enumeration stopped at [AuthorWorksEnumerator.maxWorks]
  /// before reaching the last page.
  final bool truncated;

  bool get isEmpty => works.isEmpty && ugoiraWorks.isEmpty;
}

/// Walks `/v1/user/illusts` pages (illust then manga) so the author page can
/// offer a real "download everything" action. Enumeration is page-at-a-time
/// so a progress dialog can report counts and stay cancelable mid-flight.
class AuthorWorksEnumerator {
  AuthorWorksEnumerator(this._repository);

  /// Hard cap — keeps one bulk group from queueing tens of thousands of
  /// jobs when an author has an unusually large body of work.
  static const maxWorks = 2000;

  final UserRepository _repository;

  /// Enumerates every illust, manga, and ugoira work of [userId]. [onProgress]
  /// fires after each page with the total downloadable works found so far.
  /// Cancellation travels through [cancelToken] to the in-flight request.
  Future<AuthorWorksResult> enumerate(
    int userId, {
    CancelToken? cancelToken,
    void Function(int works)? onProgress,
  }) async {
    final works = <IllustEntity>[];
    final ugoiraWorks = <IllustEntity>[];
    var truncated = false;
    enumerate:
    for (final type in const [UserWorkType.illust, UserWorkType.manga]) {
      String? cursor;
      do {
        final page = await _repository.fetchWorks(
          userId,
          type: type,
          cursor: cursor,
          cancelToken: cancelToken,
        );
        for (final illust in page.illusts) {
          if (illust.isUgoira) {
            ugoiraWorks.add(illust);
          } else {
            works.add(illust);
          }
          if (works.length + ugoiraWorks.length >= maxWorks) {
            truncated = true;
            break enumerate;
          }
        }
        onProgress?.call(works.length + ugoiraWorks.length);
        cursor = page.nextUrl;
      } while (cursor != null);
    }
    return AuthorWorksResult(
      works: works,
      ugoiraWorks: ugoiraWorks,
      truncated: truncated,
    );
  }
}
