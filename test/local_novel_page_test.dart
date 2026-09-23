import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pixiv_func/core/localnovel/local_novel_database.dart';
import 'package:pixiv_func/core/localnovel/local_novel_repository.dart';
import 'package:pixiv_func/core/localnovel/local_novel_store.dart';
import 'package:pixiv_func/features/novel/local_novel_reader_page.dart';
import 'package:pixiv_func/features/localnovel/local_novels_page.dart';
import 'package:pixiv_func/l10n/app_localizations.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/test_preferences.dart';

Widget _app(Widget child) => MaterialApp(
  localizationsDelegates: appLocalizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: child,
);

/// Alternates real-async waits (file/db IO) with frames until [finder]
/// appears — `pumpAndSettle` cannot be used because the loading spinner
/// animates while real futures resolve.
Future<void> _pumpUntil(
  WidgetTester tester,
  Finder finder, {
  int attempts = 60,
}) async {
  for (var i = 0; i < attempts && finder.evaluate().isEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Reads a row back without crossing the async boundary twice: the sqflite
/// call is issued inside the fake-async zone (same zone the reader's
/// unawaited cursor writes run in) so its lock queue advances on `pump`,
/// while `runAsync` only buys real time. Awaiting a db future inside
/// `runAsync` deadlocks when a fake-zone write still holds the lock —
/// the real zone waits, the fake zone never runs again.
Future<LocalNovel?> _readStored(
  WidgetTester tester,
  ProviderContainer container,
  int id,
) async {
  LocalNovel? result;
  var done = false;
  unawaited(
    container.read(localNovelRepositoryProvider).get(id).then((value) {
      result = value;
      done = true;
    }),
  );
  for (var i = 0; i < 120 && !done; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  if (!done) {
    fail('timed out waiting for local novel $id to be readable');
  }
  return result;
}

void main() {
  sqfliteFfiInit();
  // The shared stage loads reader settings from SharedPreferencesAsync —
  // back it with the in-memory platform.
  installMemoryPreferences();

  late Directory dir;
  late LocalNovelDatabase database;
  late ProviderContainer container;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('local-novels-page');
    database = LocalNovelDatabase(
      factory: databaseFactoryFfiNoIsolate,
      databasePath: '${dir.path}/local_novels.db',
    );
    container = ProviderContainer(
      overrides: [
        localNovelDatabaseProvider.overrideWithValue(database),
        localNovelDirectoryProvider.overrideWithValue(() async => dir),
        localNovelFilePickerProvider.overrideWithValue(
          () async => (
            'My Story.txt',
            Uint8List.fromList(utf8.encode('First line.\n\nSecond line.')),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  /// A database first opened inside the fake-async zone binds sqflite's
  /// internal lock to that zone; later real-async operations (import,
  /// close) then deadlock on it. Warming the connection inside `runAsync`
  /// keeps every zone-crossing operation resolvable.
  Future<void> warmDatabase(WidgetTester tester) async {
    await tester.runAsync(
      () => container.read(localNovelRepositoryProvider).list(),
    );
  }

  testWidgets('library page lists imported novels', (tester) async {
    await warmDatabase(tester);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: _app(const LocalNovelsPage()),
      ),
    );
    await _pumpUntil(tester, find.text('No imported local novels yet'));
    expect(find.text('No imported local novels yet'), findsOneWidget);

    await tester.runAsync(
      () => container.read(localNovelStoreProvider.notifier).importPicked(),
    );
    await _pumpUntil(tester, find.text('My Story'));
    expect(find.text('My Story'), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('reader mounts the shared stage: chrome, settings, footer', (
    tester,
  ) async {
    await warmDatabase(tester);
    final novel = await tester.runAsync(
      () => container
          .read(localNovelRepositoryProvider)
          .importBytes(
            fileName: 'Read Me.txt',
            bytes: Uint8List.fromList(utf8.encode('Opening paragraph.')),
            targetDir: dir,
          ),
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: _app(LocalNovelReaderPage(localId: novel!.id)),
      ),
    );
    await _pumpUntil(tester, find.byType(PageView));
    expect(find.byType(LocalNovelReaderPage), findsOneWidget);

    // No library AppBar and no ListTile header — the file name shows up
    // in the always-on footer tip instead.
    expect(find.byType(AppBar), findsNothing);
    expect(find.byType(ListTile), findsNothing);
    expect(find.text('Local novels'), findsNothing);
    expect(find.textContaining('Read Me'), findsOneWidget);

    // Center tap opens the reader chrome with the book title in the top
    // bar; the settings sheet is reachable from the bottom bar.
    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();
    expect(find.text('Read Me'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);
    await tester.tap(find.byIcon(Icons.tune_outlined));
    await tester.pumpAndSettle();
    expect(find.byType(Slider), findsNWidgets(2));

    // The shared NovelReader lays out asynchronously across several frames;
    // extra pumps also drain Riverpod's zero-duration vsync timers before
    // the pending-timer invariant check.
    await tester.tapAt(const Offset(400, 100));
    await tester.pumpAndSettle();
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  });

  testWidgets(
    'read_offset stays null until a real page turn, then stores the page start',
    (tester) async {
      await warmDatabase(tester);
      final text = [
        'opening paragraph',
        for (var i = 0; i < 200; i++) 'filler line $i',
        'closing paragraph',
      ].join('\n');
      final novel = await tester.runAsync(
        () => container
            .read(localNovelRepositoryProvider)
            .importBytes(
              fileName: 'Cursor Book.txt',
              bytes: Uint8List.fromList(utf8.encode(text)),
              targetDir: dir,
            ),
      );
      expect(novel!.readOffset, isNull);

      // Push the reader over a host so the page can actually pop back out.
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: _app(_ReaderHost(localId: novel.id)),
        ),
      );
      await tester.tap(find.text('open'));
      // Push lands on a loading spinner first — pumpUntil waits the real
      // async load out instead of pumpAndSettle, which never settles while
      // the indicator animates.
      await _pumpUntil(tester, find.byType(PageView));

      // Open, reveal the chrome and leave — nothing was read, so the
      // cursor must stay null (W6's "unread" signal).
      await tester.tapAt(const Offset(400, 300));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      var stored = await _readStored(tester, container, novel.id);
      expect(stored!.readOffset, isNull);
      // System back closed the chrome first; a second one leaves.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(LocalNovelReaderPage), findsNothing);
      stored = await _readStored(tester, container, novel.id);
      expect(stored!.readOffset, isNull);

      // Reopen, turn one page and the cursor lands on that page's first
      // line — a newline boundary in the stored text.
      await tester.tap(find.text('open'));
      await _pumpUntil(tester, find.byType(PageView));
      await tester.tapAt(const Offset(780, 300));
      await tester.pumpAndSettle();
      stored = await _readStored(tester, container, novel.id);
      final offset = stored!.readOffset;
      expect(offset, isNotNull);
      expect(offset, greaterThan(0));
      expect(offset, lessThan(text.length));
      expect(text[offset! - 1], '\n');
    },
  );

  testWidgets('reader restores the persisted read offset on open', (
    tester,
  ) async {
    await warmDatabase(tester);
    // Enough short paragraphs to span several pages at the default
    // viewport, bracketed by unique marker lines.
    final text = [
      'opening paragraph',
      for (var i = 0; i < 200; i++) 'filler line $i',
      'closing paragraph',
    ].join('\n');
    final novel = await tester.runAsync(
      () => container
          .read(localNovelRepositoryProvider)
          .importBytes(
            fileName: 'Long Read.txt',
            bytes: Uint8List.fromList(utf8.encode(text)),
            targetDir: dir,
          ),
    );
    // The cursor sits on the last paragraph of the document.
    final storedOffset = text.indexOf('closing paragraph');
    await tester.runAsync(
      () => container
          .read(localNovelRepositoryProvider)
          .updateReadOffset(novel!.id, storedOffset),
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: _app(LocalNovelReaderPage(localId: novel!.id)),
      ),
    );
    // Asserting the rendered page instead of re-reading the database
    // avoids racing the reader's unawaited cursor writes, which are issued
    // inside the fake-async zone and can hold sqflite's lock across a
    // real-zone `runAsync` call.
    await _pumpUntil(tester, find.text('closing paragraph'), attempts: 240);
    expect(find.text('closing paragraph'), findsOneWidget);
    expect(find.text('opening paragraph'), findsNothing);
  });

  testWidgets('reader opens on the first page without a stored cursor', (
    tester,
  ) async {
    await warmDatabase(tester);
    final text = [
      'opening paragraph',
      for (var i = 0; i < 200; i++) 'filler line $i',
      'closing paragraph',
    ].join('\n');
    final novel = await tester.runAsync(
      () => container
          .read(localNovelRepositoryProvider)
          .importBytes(
            fileName: 'Fresh Read.txt',
            bytes: Uint8List.fromList(utf8.encode(text)),
            targetDir: dir,
          ),
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: _app(LocalNovelReaderPage(localId: novel!.id)),
      ),
    );
    await _pumpUntil(tester, find.text('opening paragraph'), attempts: 240);
    expect(find.text('opening paragraph'), findsOneWidget);
    // A spurious deep restore would swap the visible page away from the
    // document start.
    expect(find.text('closing paragraph'), findsNothing);
  });
}

/// Host page that pushes [LocalNovelReaderPage], so a system back has a
/// route to land on.
class _ReaderHost extends StatelessWidget {
  const _ReaderHost({required this.localId});

  final int localId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () => Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => LocalNovelReaderPage(localId: localId),
            ),
          ),
          child: const Text('open'),
        ),
      ),
    );
  }
}
