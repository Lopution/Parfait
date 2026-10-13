/// The `retry` of a provider whose page shows its failure (spec STORE-01).
/// Riverpod's default retry backs off ten times, about 38 s, and holds the
/// value in loading meanwhile, so the page spins instead of showing the
/// error and its retry button.
Duration? noRetry(int retryCount, Object error) => null;
