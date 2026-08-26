import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/auth/token_refresh_gate.dart';

void main() {
  test('20 concurrent callers share exactly one refresh per account',
      () async {
    final gate = TokenRefreshGate();
    var performCalls = 0;
    final completer = Completer<void>();

    Future<RefreshOutcome> perform() async {
      performCalls += 1;
      await completer.future;
      return const Refreshed('new-token');
    }

    // The first caller starts the refresh; everyone else joins it.
    final futures = <Future<RefreshOutcome>>[];
    for (var i = 0; i < 20; i++) {
      futures.add(
        i == 0
            ? gate.refresh(
                accountId: '100',
                staleToken: 'old-token',
                currentToken: 'old-token',
                perform: perform,
              )
            : Future<void>.delayed(Duration.zero).then(
                (_) => gate.refresh(
                  accountId: '100',
                  staleToken: 'old-token',
                  currentToken: 'old-token',
                  perform: () async {
                    fail('must join the in-flight refresh');
                  },
                ),
              ),
      );
    }

    await Future<void>.delayed(Duration.zero);
    completer.complete();
    final outcomes = await futures.wait;

    expect(performCalls, 1);
    for (final outcome in outcomes) {
      expect(outcome, isA<Refreshed>());
      expect((outcome as Refreshed).accessToken, 'new-token');
    }
  });

  test('a caller whose token is already fresh never triggers a refresh',
      () async {
    final gate = TokenRefreshGate();
    final outcome = await gate.refresh(
      accountId: '100',
      staleToken: 'stale-token',
      currentToken: 'current-token',
      perform: () async => fail('must not refresh'),
    );
    expect(outcome, isA<AlreadyRefreshed>());
    expect((outcome as AlreadyRefreshed).accessToken, 'current-token');
  });

  test('different accounts refresh independently', () async {
    final gate = TokenRefreshGate();
    final release = Completer<void>();
    var calls = 0;

    Future<RefreshOutcome> perform() async {
      final index = ++calls;
      await release.future;
      return Refreshed('new-$index');
    }

    final first = gate.refresh(
      accountId: '100',
      staleToken: 'old-1',
      currentToken: 'old-1',
      perform: perform,
    );
    final second = gate.refresh(
      accountId: '200',
      staleToken: 'old-2',
      currentToken: 'old-2',
      perform: perform,
    );

    await Future<void>.delayed(Duration.zero);
    expect(gate.isRefreshing, isTrue);
    release.complete();

    final firstOutcome = await first;
    final secondOutcome = await second;
    expect(calls, 2);
    expect((firstOutcome as Refreshed).accessToken, 'new-1');
    expect((secondOutcome as Refreshed).accessToken, 'new-2');
  });

  test('a failed refresh is shared by all waiting callers', () async {
    final gate = TokenRefreshGate();
    final error = Exception('invalid grant');
    final futures = List.generate(5, (_) {
      return gate.refresh(
        accountId: '100',
        staleToken: 'old',
        currentToken: 'old',
        perform: () async => RefreshFailed(error),
      );
    });
    final outcomes = await futures.wait;
    for (final outcome in outcomes) {
      expect((outcome as RefreshFailed).error, same(error));
    }
  });

  test('gate allows a new refresh after the previous one completed',
      () async {
    final gate = TokenRefreshGate();
    var calls = 0;
    Future<RefreshOutcome> perform() async {
      calls += 1;
      return Refreshed('new-$calls');
    }

    final first = await gate.refresh(
      accountId: '100',
      staleToken: 'old',
      currentToken: 'old',
      perform: perform,
    );
    final second = await gate.refresh(
      accountId: '100',
      staleToken: 'old',
      currentToken: 'old',
      perform: perform,
    );

    expect(calls, 2);
    expect((first as Refreshed).accessToken, 'new-1');
    expect((second as Refreshed).accessToken, 'new-2');
  });
}
