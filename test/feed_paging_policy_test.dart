import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parfait/core/auth/account.dart';
import 'package:parfait/core/auth/account_store.dart';
import 'package:parfait/core/entity/illust_entity.dart';
import 'package:parfait/core/paging/paged_feed_controller.dart';
import 'package:parfait/core/settings/app_settings.dart';
import 'package:parfait/core/settings/settings_controller.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/illust_fixtures.dart';
import 'helpers/test_preferences.dart';

class _StubAccountStore extends AccountStore {
  @override
  Future<AccountState> build() async => const AccountState(
    status: AccountStatus.ready,
    accounts: [Account(id: 'account-a', userId: 1, name: 'tester')],
    currentId: 'account-a',
  );
}

class _BlockR18Settings extends SettingsController {
  @override
  Future<AppSettings> build() async =>
      AppSettings.defaults().copyWith(enableLocalBlockR18: true);
}

/// A feed that never ends. With [r18From] set, every page from that index
/// on holds only R-18 works, so a filtering feed refills behind it.
class _EndlessFeed extends PagedFeedController {
  _EndlessFeed({this.r18From});

  final int? r18From;

  /// When each page request went out, in fake time.
  final requests = <DateTime>[];

  @override
  String get feedKey => 'endless';

  @override
  bool get localFilterEnabled => r18From != null;

  @override
  int get filterMinVisible => 1;

  @override
  Future<FeedPage> fetchPageForContext(FeedRequestContext context) async {
    requests.add(clock.now());
    final id = requests.length;
    final from = r18From;
    final illust = parseIllust(
      illustJson(id, xRestrict: from != null && id >= from ? 1 : 0),
    );
    return FeedPage(
      ids: [id],
      nextCursor: 'page-${id + 1}',
      incomingIllusts: <int, IllustEntity>{id: illust},
    );
  }
}

final _feed = AsyncNotifierProvider<_EndlessFeed, PagedFeedState>(
  _EndlessFeed.new,
);

final _filteredFeed = AsyncNotifierProvider<_EndlessFeed, PagedFeedState>(
  () => _EndlessFeed(r18From: 3),
);

const _policy = FeedPagingPolicy.standard;

/// Runs [body] in fake time against a loaded feed.
void _withFeed(
  void Function(FakeAsync async, ProviderContainer container, _EndlessFeed feed)
  body, {
  AsyncNotifierProvider<_EndlessFeed, PagedFeedState>? provider,
  bool blockR18 = false,
}) {
  fakeAsync((async) {
    SharedPreferencesAsyncPlatform.instance = memoryPreferences();
    final container = ProviderContainer(
      overrides: [
        accountStoreProvider.overrideWith(_StubAccountStore.new),
        if (blockR18) settingsProvider.overrideWith(_BlockR18Settings.new),
      ],
    );
    final target = provider ?? _feed;
    container.listen(target, (_, _) {});
    if (blockR18) container.listen(settingsProvider, (_, _) {});
    // Riverpod schedules rebuilds on zero-length timers.
    async.elapse(Duration.zero);
    final feed = container.read(target.notifier);
    expect(container.read(target).value?.ids, isNotEmpty);
    body(async, container, feed);
    container.dispose();
  });
}

/// Requests sent by the next load-more once its interval has passed.
int _pageOnce(FakeAsync async, _EndlessFeed feed) {
  final before = feed.requests.length;
  feed.loadMore();
  async.elapse(_policy.minPageInterval);
  return feed.requests.length - before;
}

void main() {
  test('pages wait out the interval; the first after a load goes at once', () {
    _withFeed((async, container, feed) {
      final loadedAt = feed.requests.length;
      feed.loadMore();
      async.flushMicrotasks();
      expect(feed.requests.length, loadedAt + 1);

      feed.loadMore();
      async.flushMicrotasks();
      // Held, with the tail spinning.
      expect(feed.requests.length, loadedAt + 1);
      expect(container.read(_feed).value!.showLoadMoreSpinner, isTrue);
      async.elapse(_policy.minPageInterval - const Duration(milliseconds: 1));
      expect(feed.requests.length, loadedAt + 1);
      async.elapse(const Duration(milliseconds: 1));
      expect(feed.requests.length, loadedAt + 2);
      expect(
        feed.requests.last.difference(feed.requests[loadedAt]),
        _policy.minPageInterval,
      );
    });
  });

  test('a run of pages pauses at the budget; continue grants a new one', () {
    _withFeed((async, container, feed) {
      for (var page = 0; page < _policy.maxAutoPages; page++) {
        expect(_pageOnce(async, feed), 1, reason: 'page $page');
      }
      expect(_pageOnce(async, feed), 0);
      final paused = container.read(_feed).value!;
      expect(paused.loadMorePaused, isTrue);
      expect(paused.showLoadMoreSpinner, isFalse);

      // Scrolling alone stays paused.
      expect(_pageOnce(async, feed), 0);

      feed.retryLoadMore();
      async.elapse(_policy.minPageInterval);
      expect(container.read(_feed).value!.loadMorePaused, isFalse);
      for (var page = 1; page < _policy.maxAutoPages; page++) {
        expect(_pageOnce(async, feed), 1, reason: 'page $page');
      }
      expect(_pageOnce(async, feed), 0);
    });
  });

  test('a pause in reading starts a new budget', () {
    _withFeed((async, container, feed) {
      for (var page = 0; page < _policy.maxAutoPages; page++) {
        _pageOnce(async, feed);
      }
      expect(_pageOnce(async, feed), 0);
      expect(container.read(_feed).value!.loadMorePaused, isTrue);

      async.elapse(_policy.burstIdleReset);
      feed.loadMore();
      async.flushMicrotasks();
      expect(container.read(_feed).value!.loadMorePaused, isFalse);
      for (var page = 1; page < _policy.maxAutoPages; page++) {
        expect(_pageOnce(async, feed), 1, reason: 'page $page');
      }
    });
  });

  test('a refresh during the wait takes over; its next page is not held', () {
    _withFeed((async, container, feed) {
      _pageOnce(async, feed);
      feed.loadMore();
      async.flushMicrotasks();
      final held = feed.requests.length;

      feed.refresh();
      async.flushMicrotasks();
      expect(feed.requests.length, held + 1, reason: 'refresh goes at once');
      async.elapse(_policy.minPageInterval);
      // The held load-more gave way to the refresh.
      expect(feed.requests.length, held + 1);
      expect(container.read(_feed).value!.ids, [held + 1]);

      feed.loadMore();
      async.flushMicrotasks();
      expect(feed.requests.length, held + 2);
    });
  });

  test('refill hops are paced like pages', () {
    _withFeed(provider: _filteredFeed, blockR18: true, (
      async,
      container,
      feed,
    ) {
      // Pages 1-2 are visible; from 3 on every page is filtered out, so
      // the load-more refills behind each one.
      feed.loadMore();
      async.flushMicrotasks();
      final start = feed.requests.length;
      feed.loadMore();
      async.elapse(const Duration(seconds: 10));
      final hops = feed.requests.sublist(start - 1);
      expect(hops.length, greaterThan(2));
      for (var i = 1; i < hops.length; i++) {
        expect(
          hops[i].difference(hops[i - 1]),
          greaterThanOrEqualTo(_policy.minPageInterval),
        );
      }
    });
  });
}
