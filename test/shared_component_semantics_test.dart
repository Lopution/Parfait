import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:pixiv_func/app/widgets/app_snack_bar.dart';
import 'package:pixiv_func/app/widgets/feed/feed_states.dart';
import 'package:pixiv_func/core/network/api_error.dart';
import 'package:pixiv_func/core/paging/paged_feed_controller.dart';

Widget _host(Widget child) {
  return MaterialApp(home: Scaffold(body: child));
}

void main() {
  testWidgets('feed status widgets expose labels and native actions', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const FeedTail(
          feed: PagedFeedState(loadMorePhase: FeedPhase.loading),
        ),
      ),
    );
    expect(
      tester.getSemantics(find.byType(CircularProgressIndicator)),
      isSemantics(role: ui.SemanticsRole.loadingSpinner),
    );

    await tester.pumpWidget(
      _host(
        const FeedTail(
          feed: PagedFeedState(
            initialPhase: FeedPhase.idle,
            loadMorePhase: FeedPhase.error,
            loadMoreError: ApiHttpError(503),
          ),
          errorTitle: 'More failed',
          retryLabel: 'Try again',
          onRetry: _noop,
        ),
      ),
    );
    expect(find.bySemanticsLabel('More failed'), findsOneWidget);
    expect(find.bySemanticsLabel('Try again'), findsOneWidget);
    expect(
      tester.getSemantics(find.text('Try again')),
      isSemantics(isButton: true, hasTapAction: true),
    );

    await tester.pumpWidget(
      _host(
        const FeedTail(
          feed: PagedFeedState(initialPhase: FeedPhase.idle, exhausted: true),
          endMessage: 'No more',
        ),
      ),
    );
    expect(find.bySemanticsLabel('No more'), findsOneWidget);

    await tester.pumpWidget(
      _host(
        const FeedEmpty(
          title: 'Nothing here',
          retryLabel: 'Refresh',
          onRefresh: _refresh,
        ),
      ),
    );
    expect(find.bySemanticsLabel('Nothing here'), findsOneWidget);
    expect(find.bySemanticsLabel('Refresh'), findsOneWidget);
    expect(
      tester.getSemantics(find.text('Refresh')),
      isSemantics(isButton: true, hasTapAction: true),
    );

    await tester.pumpWidget(
      _host(
        const FeedError(
          title: 'Could not load',
          error: ApiHttpError(500),
          retryLabel: 'Retry now',
          onRetry: _noop,
        ),
      ),
    );
    expect(find.bySemanticsLabel('Could not load'), findsOneWidget);
    expect(find.bySemanticsLabel('Retry now'), findsOneWidget);
    expect(
      tester.getSemantics(find.text('Retry now')),
      isSemantics(isButton: true, hasTapAction: true),
    );
  });

  testWidgets('app snackbars are exposed as live regions', (tester) async {
    await tester.pumpWidget(
      _host(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showAppSnackBar(context, 'Saved'),
            child: const Text('Show'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Show'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.bySemanticsLabel('Saved'), findsOneWidget);
    expect(
      tester.getSemantics(find.bySemanticsLabel('Saved')),
      isSemantics(label: 'Saved', isLiveRegion: true),
    );
  });
}

void _noop() {}

Future<void> _refresh() async {}
