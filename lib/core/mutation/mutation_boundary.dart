import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/account_store.dart';
import '../network/compat/network_providers.dart';
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
    networkRevision: ref.read(networkAccessPolicyProvider).revision,
  );
}

bool sameMutationBoundary(
  MutationBoundary? left,
  MutationBoundary? right, {
  bool includeNetwork = true,
}) {
  if (left == null || right == null) return left == null && right == null;
  return left.accountId == right.accountId &&
      left.credentialRevision == right.credentialRevision &&
      (!includeNetwork ||
          (left.networkRevision.value == right.networkRevision.value &&
              left.networkRevision.networkIdentity ==
                  right.networkRevision.networkIdentity));
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
  if (envelope.networkRevision.value != current.networkRevision.value ||
      envelope.networkRevision.networkIdentity !=
          current.networkRevision.networkIdentity) {
    return MutationDiscardReason.networkChanged;
  }
  return null;
}
