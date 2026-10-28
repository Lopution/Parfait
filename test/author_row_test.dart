import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/app/widgets/author_row.dart';
import 'package:parfait/app/widgets/person_card.dart';
import 'package:parfait/core/auth/account.dart';

import 'helpers/fake_account.dart';
import 'helpers/localized_app.dart';
import 'helpers/pixiv_router.dart';

/// The real router with [row] on a plain pushed route, so a tap goes
/// through the `openUser` facade.
Future<GoRouter> _pumpOnRouter(WidgetTester tester, Widget row) async {
  final router = pixivRouter('/recommended');
  await tester.pumpWidget(
    localizedRouterApp(
      router,
      overrides: signedInAccountOverrides(
        const Account(id: '100', userId: 100, name: 't'),
      ),
    ),
  );
  await tester.pump();
  router.routerDelegate.navigatorKey.currentState!.push(
    PageRouteBuilder<void>(
      pageBuilder: (context, _, _) => Scaffold(
        body: Center(child: SizedBox(width: 300, child: row)),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  return router;
}

void main() {
  testWidgets('the whole row is one 48dp target that opens the profile', (
    tester,
  ) async {
    final router = await _pumpOnRouter(
      tester,
      const AuthorRow(userId: 42, name: 'author'),
    );

    final target = find.byType(InkWell);
    expect(target, findsOneWidget);
    expect(
      tester.getSize(target).height,
      greaterThanOrEqualTo(AuthorRow.minHeight),
    );
    // The target spans the row, not just the name text.
    expect(tester.getSize(target).width, 300);
    // The chevron follows the name, inside the one target.
    final chevron = find.descendant(
      of: target,
      matching: find.byIcon(Icons.chevron_right),
    );
    expect(
      tester.getTopLeft(chevron).dx,
      moreOrLessEquals(tester.getTopRight(find.text('author')).dx),
    );

    // A tap well right of the name still lands.
    await tester.tapAt(tester.getRect(target).centerRight - const Offset(8, 0));
    await tester.pump();
    expect(router.state.uri.path, '/recommended/user/42');
  });

  testWidgets('a person card is one target; its trailing button is its own', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    var opened = 0;
    var followed = 0;
    await tester.pumpWidget(
      localizedApp(
        body: Center(
          child: SizedBox(
            width: 300,
            child: PersonCard(
              onTap: () => opened++,
              tapHint: 'open',
              trailing: TextButton(
                onPressed: () => followed++,
                child: const Text('follow'),
              ),
              child: const Text('name'),
            ),
          ),
        ),
      ),
    );

    final card = find.byType(PersonCard);
    expect(
      tester.getSize(card).height,
      greaterThanOrEqualTo(kMinInteractiveDimension),
    );
    // One button node for the card; the trailing button is not in it.
    expect(
      tester.getSemantics(
        find.descendant(of: card, matching: find.byType(InkWell)).first,
      ),
      isSemantics(
        label: 'name',
        isButton: true,
        hasTapAction: true,
        onTapHint: 'open',
      ),
    );

    await tester.tapAt(tester.getRect(card).centerLeft + const Offset(8, 0));
    await tester.tap(find.text('follow'));
    expect((opened, followed), (1, 1));
    semantics.dispose();
  });
}
