import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/motion/removal.dart';
import 'package:parfait/core/mute/mute_store.dart';
import 'package:network_image_mock/network_image_mock.dart';
import 'package:parfait/features/settings/pages/muted_items_page.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/fake_account.dart';
import 'helpers/test_preferences.dart';
import 'helpers/prompt_host.dart';
import 'helpers/localized_app.dart';

/// Mute API transport: one muted tag on the server; every `/v1/mute/edit`
/// is recorded and answered with [editStatus].
class _MuteApi {
  _MuteApi({this.users = const []});

  /// `muted_users` of the list response.
  final List<Object> users;
  final List<Map<String, String>> edits = [];
  int editStatus = 200;

  http.Client build() => MockClient((request) async {
    if (request.url.path.endsWith('/v1/mute/list')) {
      return http.Response(
        jsonEncode({
          'muted_tags': [
            {'tag': 'bad-tag', 'tag_translation': ''},
          ],
          'muted_users': users,
          'mute_limit_count': 500,
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    if (request.url.path.endsWith('/v1/mute/edit')) {
      edits.add(Uri.splitQueryString(request.body));
      return http.Response(
        jsonEncode({'error': editStatus == 200 ? null : 'x'}),
        editStatus,
        headers: {'content-type': 'application/json'},
      );
    }
    fail('unexpected ${request.method} ${request.url}');
  });
}

Future<(ProviderContainer, _MuteApi)> _pump(
  WidgetTester tester, {
  List<Object> users = const [],
}) async {
  SharedPreferencesAsyncPlatform.instance = memoryPreferences();
  final api = _MuteApi(users: users);
  final container = await signedInApiContainer(api.build());
  await mockNetworkImagesFor(
    () => tester.pumpWidget(
      localizedApp(
        container: container,
        builder: promptHostBuilder,
        home: MutedItemsPage(),
      ),
    ),
  );
  // The page's watch starts the hydrate; the transport answers in
  // microtasks, so frames drive it home.
  for (var i = 0; i < 50; i++) {
    if (container.read(muteStoreProvider).serverSynced) break;
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(container.read(muteStoreProvider).tags, {'bad-tag'});
  await tester.pumpAndSettle();
  return (container, api);
}

/// Lets the exit land and the edit round-trip (the transport answers in
/// microtasks).
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  Finder row() =>
      find.ancestor(of: find.text('bad-tag'), matching: find.byType(Removable));

  testWidgets('unmuting plays the row exit before the edit is sent', (
    tester,
  ) async {
    final (container, api) = await _pump(tester);
    expect(row(), findsOneWidget);

    await tester.tap(find.byIcon(Icons.visibility_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(api.edits, isEmpty, reason: 'the exit plays first');
    expect(find.text('bad-tag'), findsOneWidget);

    await _settle(tester);
    expect(api.edits.single['delete_tags[]'], 'bad-tag');
    expect(container.read(muteStoreProvider).tags, isEmpty);
    expect(find.text('bad-tag'), findsNothing);
  });

  testWidgets('a failed unmute brings the row back with an error', (
    tester,
  ) async {
    final (container, api) = await _pump(tester);
    api.editStatus = 500;

    await tester.tap(find.byIcon(Icons.visibility_outlined));
    await _settle(tester);
    await tester.pumpAndSettle();

    expect(api.edits, hasLength(1));
    expect(container.read(muteStoreProvider).tags, {'bad-tag'});
    final fade = tester.widget<FadeTransition>(
      find.descendant(of: row(), matching: find.byType(FadeTransition)).first,
    );
    expect(fade.opacity.value, 1);
    expect(shownPrompt, findsOneWidget);
  });

  testWidgets('a landed unmute offers Undo, which mutes the tag again', (
    tester,
  ) async {
    final (container, api) = await _pump(tester);

    await tester.tap(find.byIcon(Icons.visibility_outlined));
    await _settle(tester);
    expect(find.text('已解除屏蔽'), findsOneWidget);
    // No confirmation step: the unmute already landed (D5).
    expect(find.byType(AlertDialog), findsNothing);
    expect(container.read(muteStoreProvider).tags, isEmpty);

    await tester.tap(promptAction('撤销'));
    await _settle(tester);
    expect(api.edits.last['add_tags[]'], 'bad-tag');
    expect(container.read(muteStoreProvider).tags, {'bad-tag'});
    await tester.pumpAndSettle();
    expect(find.text('bad-tag'), findsOneWidget);
  });
}
