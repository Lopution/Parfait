import '../entity/illust_entity.dart';
import '../network/pixiv_http_client.dart';
import '../user/user_repository.dart';

/// Result of walking every author-work page for a bulk download
/// (implement.md step 4 — ugoira excluded, hard cap enforced).
class AuthorWorksResult {
  const AuthorWorksResult({required this.works, required this.truncated});

  /// Illust+manga works in enumeration order, ugoira filtered out.
  final List<IllustEntity> works;

  /// True when enumeration stopped at [AuthorWorksEnumerator.maxWorks]
  /// before reaching the last page.
  final bool truncated;
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

  /// Enumerates every illust and manga work of [userId]. [onProgress] fires
  /// after each page with the number of downloadable works found so far.
  /// Cancellation travels through [cancelToken] to the in-flight request.
  Future<AuthorWorksResult> enumerate(
    int userId, {
    CancelToken? cancelToken,
    void Function(int works)? onProgress,
  }) async {
    final works = <IllustEntity>[];
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
          // Ugoira pages need the ugoira metadata pipeline, not plain image
          // URLs — they are out of scope for bulk image download.
          if (illust.isUgoira) continue;
          works.add(illust);
          if (works.length >= maxWorks) {
            truncated = true;
            break enumerate;
          }
        }
        onProgress?.call(works.length);
        cursor = page.nextUrl;
      } while (cursor != null);
    }
    return AuthorWorksResult(works: works, truncated: truncated);
  }
}
