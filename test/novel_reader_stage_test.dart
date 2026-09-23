import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pixiv_func/core/novel/novel_entity.dart';
import 'package:pixiv_func/core/user/user_entity.dart';
import 'package:pixiv_func/features/novel/novel_layout.dart';
import 'package:pixiv_func/features/novel/novel_reader_stage.dart';
import 'package:pixiv_func/l10n/app_localizations.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';

import 'helpers/test_preferences.dart';

/// Stage-level test with a recording progress binding: pins the D1 write
/// gate — only user-committed turns reach `save`.
void main() {
  // SharedPreferencesAsync reads through the platform instance — the
  // in-memory platform keeps reader-settings writes off the real plugin.
  installMemoryPreferences();

  testWidgets('open and sheet toggles never write; a page turn writes once', (
    tester,
  ) async {
    final binding = _RecordingBinding();
    await tester.pumpWidget(_stageApp(binding));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // First-layout echo and the restore jump do not persist anything.
    expect(binding.saves, isEmpty);
    expect(find.byType(PageView), findsOneWidget);

    // Open and close the info sheet — still no write.
    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.info_outline));
    await tester.pumpAndSettle();
    expect(find.text('info sheet'), findsOneWidget);
    await tester.tapAt(const Offset(400, 100));
    await tester.pumpAndSettle();
    expect(binding.saves, isEmpty);

    // A real page turn writes exactly one anchor.
    await tester.tapAt(const Offset(780, 300));
    await tester.pumpAndSettle();
    expect(binding.saves, hasLength(1));
  });

  testWidgets('a stored record restores without being rewritten', (
    tester,
  ) async {
    final text = List.generate(
      80,
      (index) => 'paragraph $index body text body text',
    ).join('\n\n');
    final binding = _RecordingBinding(
      restore: const NovelAnchor(paragraphId: 'p60', offset: 0),
    );
    await tester.pumpWidget(_stageApp(binding, text: text));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // The restore jump reports the position as a layout echo — the store
    // keeps the record untouched until the user actually turns a page.
    expect(binding.saves, isEmpty);
    expect(binding.loadCalls, 1);
  });
}

class _RecordingBinding implements ReaderProgressBinding {
  _RecordingBinding({this.restore});

  final NovelAnchor? restore;
  final List<NovelAnchor> saves = [];
  var loadCalls = 0;

  @override
  Future<NovelAnchor?> load() async {
    loadCalls += 1;
    return restore;
  }

  @override
  Future<void> save(NovelAnchor anchor) async {
    saves.add(anchor);
  }
}

Widget _stageApp(_RecordingBinding binding, {String? text}) {
  return ProviderScope(
    child: MaterialApp(
      localizationsDelegates: appLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh', 'CN'),
      home: Scaffold(
        body: NovelReaderStage(
          spec: NovelReaderStageSpec(
            novel: _novel(text ?? 'reader ' * 400),
            infoTooltip: 'info',
            infoSheet: (context) => const Text('info sheet'),
            progress: binding,
          ),
        ),
      ),
    ),
  );
}

NovelEntity _novel(String text) => NovelEntity(
  id: 77,
  title: 'A novel',
  caption: '',
  user: const UserEntity(id: 8, name: 'author', account: 'author'),
  tags: const [],
  textLength: text.length,
  contentVersion: text,
  paragraphs: NovelContentMapper.fromText(text),
  contentAvailable: true,
);
