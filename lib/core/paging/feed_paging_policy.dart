/// Pace and budget of a feed's automatic paging. See
/// `frontend/state-management.md` (feed paging).
library;

/// How fast and how far a feed pages on its own.
///
/// Scroll-ahead prefetch has no gap: when local filters leave a page with
/// one or two visible items, those land in the prefetch zone at once and
/// ask for the next page, and so on — a runaway that pages to the server's
/// offset limit with nobody reading. People who read pause between pages
/// (12–20s a page under heavy use); a runaway does not (≤2.4s). Two gates
/// bring it back to a reader's pace:
///
/// - [minPageInterval]: the least time between two automatic page requests
///   (each refill hop included), counted from the previous page's return.
///   The tail keeps spinning meanwhile; the request is not dropped. The
///   first load, a refresh and the first page after either are never held.
/// - [maxAutoPages]: pages fetched back to back. A pause longer than
///   [burstIdleReset] between pages counts as reading and starts a new
///   budget, so a reader never meets it; a runaway stops after this many
///   pages and the tail offers "continue", which grants a fresh budget.
class FeedPagingPolicy {
  const FeedPagingPolicy({
    this.maxAutoPages = 30,
    this.minPageInterval = const Duration(seconds: 1),
    this.burstIdleReset = const Duration(seconds: 5),
  }) : assert(maxAutoPages >= 1);

  /// Network feeds.
  static const standard = FeedPagingPolicy();

  /// Feeds read from local storage, where a page costs no request.
  static const unlimited = FeedPagingPolicy(
    maxAutoPages: 1 << 30,
    minPageInterval: Duration.zero,
  );

  final int maxAutoPages;
  final Duration minPageInterval;
  final Duration burstIdleReset;
}
