/// The account a request must go out as. The offline action queue binds
/// each replay to the row's owner; any other request takes the account
/// current as it starts.
library;

import 'dart:async';

final _requestAccountKey = Object();

/// Runs [body] with every request it makes bound to [accountId]: one that
/// starts while another account is current fails as `ApiCancelled`, before
/// anything is sent.
Future<void> runAsAccount(String accountId, FutureOr<void> Function() body) =>
    runZoned(() async => body(), zoneValues: {_requestAccountKey: accountId});

/// The account [runAsAccount] bound the running code to; null outside it.
String? requestAccount() => Zone.current[_requestAccountKey] as String?;
