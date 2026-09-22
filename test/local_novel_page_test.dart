import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
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

void main() {
  sqfliteFfiInit();

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

  testWidgets('reader page renders the imported text via the shared reader', (
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
    await _pumpUntil(tester, find.text('Read Me'));
    expect(find.text('Read Me'), findsOneWidget);
    expect(find.byType(LocalNovelReaderPage), findsOneWidget);
    // The shared NovelReader lays out asynchronously across several frames;
    // extra pumps also drain Riverpod's zero-duration vsync timers before
    // the pending-timer invariant check.
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  });

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
