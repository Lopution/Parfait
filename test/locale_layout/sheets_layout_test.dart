import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:parfait/app/widgets/bookmark_switch_button.dart';
import 'package:parfait/app/widgets/feed/illust_card.dart';
import 'package:parfait/app/widgets/follow_switch_button.dart';
import 'package:parfait/core/auth/account_store.dart';
import 'package:parfait/core/bookmark/bookmark_models.dart';
import 'package:parfait/core/bookmark/bookmark_repository.dart';
import 'package:parfait/core/download/author_works_enumerator.dart';
import 'package:parfait/core/search/search_models.dart';
import 'package:parfait/features/profile/author_works_download_dialog.dart';
import 'package:parfait/features/search/search_filter_sheet.dart';

import '../helpers/bookmark_world.dart';
import '../helpers/card_world.dart';
import '../helpers/download_world.dart';
import '../helpers/fake_account.dart';
import '../helpers/illust_fixtures.dart';
import '../helpers/locale_layout.dart';
import '../helpers/profile_world.dart';
import '../helpers/test_preferences.dart';

/// A page whose button calls [open]: the sheet lays out over a real route,
/// the way the app shows it.
class _Opener extends ConsumerWidget {
  const _Opener(this.open);

  final Future<void> Function(BuildContext context, WidgetRef ref) open;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    body: Center(
      child: TextButton(
        onPressed: () => unawaited(open(context, ref)),
        child: const Text('open'),
      ),
    ),
  );
}

Future<void> _expectOpened(
  WidgetTester tester,
  Locale locale,
  LayoutProfile profile,
  Finder trigger, {
  bool longPress = false,
}) async {
  if (longPress) {
    await tester.longPress(trigger);
  } else {
    await tester.tap(trigger);
  }
  await settleLayout(tester);
  await expectPageLayoutIntact(tester, locale: locale, profile: profile);
}

void main() {
  installMemoryPreferences();

  localeLayoutMatrix('sheets: bookmark', (tester, locale, profile) async {
    final repository = RecordingBookmarkRepository()
      ..tagPage = const UserBookmarkTagPage(
        tags: [
          UserBookmarkTag(name: 'procreate', count: 5),
          UserBookmarkTag(name: 'オリジナル', count: 1234),
        ],
        nextUrl: null,
      );
    final container = ProviderContainer(
      overrides: [
        accountStoreProvider.overrideWith(StubAccountStore.new),
        bookmarkRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);
    await container.read(accountStoreProvider.future);
    await tester.pumpWidget(
      localeLayoutApp(
        locale: locale,
        container: container,
        home: const Scaffold(
          body: Center(
            child: BookmarkSwitchButton(illustId: 1, title: 'work 1'),
          ),
        ),
      ),
    );
    await _expectOpened(
      tester,
      locale,
      profile,
      find.byType(BookmarkSwitchButton),
      longPress: true,
    );
  });

  localeLayoutMatrix('sheets: follow', (tester, locale, profile) async {
    final container = await makeProfileWorld();
    await tester.pumpWidget(
      localeLayoutApp(
        locale: locale,
        container: container,
        home: _Opener(
          (context, ref) => showFollowActionsSheet(
            context,
            ref,
            userId: 42,
            userName: 'sample user',
            userAccount: 'sample',
          ),
        ),
      ),
    );
    await _expectOpened(tester, locale, profile, find.text('open'));
  });

  localeLayoutMatrix('sheets: card actions', (tester, locale, profile) async {
    final (container, _, _) = await makeCardWorld();
    await mockNetworkImagesFor(() async {
      await tester.pumpWidget(
        localeLayoutApp(
          locale: locale,
          container: container,
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 200,
                child: IllustCard(entity: parseIllust(illustJson(7))),
              ),
            ),
          ),
        ),
      );
      await _expectOpened(
        tester,
        locale,
        profile,
        find.byType(IllustCard),
        longPress: true,
      );
    });
  });

  for (final type in const [SearchResultType.illust, SearchResultType.novel]) {
    localeLayoutMatrix('sheets: search filters (${type.name})', (
      tester,
      locale,
      profile,
    ) async {
      await tester.pumpWidget(
        localeLayoutApp(
          locale: locale,
          overrides: [accountStoreProvider.overrideWith(StubAccountStore.new)],
          home: _Opener(
            (context, ref) => showSearchFilterSheet(
              context,
              initial: SearchFilters.defaults,
              type: type,
            ),
          ),
        ),
      );
      await _expectOpened(tester, locale, profile, find.text('open'));
    });
  }

  // Each outcome of the author works dialog: still counting, a capped
  // count to confirm, nothing to download, and a failed count.
  final authorOutcomes = <String, FakeUserRepository Function()>{
    'counting': () => FakeUserRepository()..worksGate = Completer<void>(),
    'capped': () => FakeUserRepository(
      works: [
        for (var id = 1; id <= AuthorWorksEnumerator.maxWorks + 1; id++)
          parseIllust(illustJson(id)),
      ],
    ),
    'empty': FakeUserRepository.new,
    'failed': () => FakeUserRepository(worksFailure: StateError('boom')),
  };
  for (final MapEntry(key: name, value: repository) in authorOutcomes.entries) {
    localeLayoutMatrix('sheets: author works download ($name)', (
      tester,
      locale,
      profile,
    ) async {
      final (container, _, _) = await makeDownloadWorld(responses: const []);
      await tester.pumpWidget(
        localeLayoutApp(
          locale: locale,
          container: container,
          home: AuthorWorksDownloadDialog(
            userId: 42,
            enumerator: AuthorWorksEnumerator(repository()),
          ),
        ),
      );
      await settleLayout(tester);
      expectLocaleLayoutIntact(tester, locale: locale, profile: profile);
    });
  }
}
