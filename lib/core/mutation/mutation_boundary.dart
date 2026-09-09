/// Account identity boundary shared by authenticated mutation stores.
/// [MutationBoundary] and [MutationLedger] own operation identity and stale
/// result handling, not feature presentation. See `frontend/state-management.md`.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_store.dart';
import 'mutation_models.dart';

/// Reads the current authenticated write boundary without exposing secrets.
/// A mutation cannot begin while account hydration has not produced a usable
/// account; callers surface the normal authentication error instead.
MutationBoundary? readMutationBoundary(Ref ref) {
  final accountState = ref.read(accountStoreProvider).asData?.value;
  final account = accountState?.usableCurrent;
  if (accountState == null || account == null) return null;
  return MutationBoundary(accountId: account.id);
}

bool sameMutationBoundary(MutationBoundary? left, MutationBoundary? right) {
  if (left == null || right == null) return left == null && right == null;
  // C1: the boundary is the stable account; a token refresh or profile edit
  // inside the same account never invalidates an in-flight write.
  return left.accountId == right.accountId;
}

MutationDiscardReason? mutationBoundaryReason(
  MutationEnvelope envelope,
  MutationBoundary? current,
) {
  if (current == null || envelope.accountId != current.accountId) {
    return MutationDiscardReason.accountChanged;
  }
  return null;
}
