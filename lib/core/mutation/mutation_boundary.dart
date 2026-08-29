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
  return MutationBoundary(
    accountId: account.id,
    credentialRevision: accountState.credentialRevision,
  );
}

bool sameMutationBoundary(MutationBoundary? left, MutationBoundary? right) {
  if (left == null || right == null) return left == null && right == null;
  return left.accountId == right.accountId &&
      left.credentialRevision == right.credentialRevision;
}

MutationDiscardReason? mutationBoundaryReason(
  MutationEnvelope envelope,
  MutationBoundary? current,
) {
  if (current == null || envelope.accountId != current.accountId) {
    return MutationDiscardReason.accountChanged;
  }
  if (envelope.credentialRevision != current.credentialRevision) {
    return MutationDiscardReason.credentialChanged;
  }
  return null;
}
