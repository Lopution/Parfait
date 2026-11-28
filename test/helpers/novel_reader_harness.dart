import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'package:parfait/app/layout/input_modality.dart';
import 'package:parfait/core/network/pixiv_http_client.dart';
import 'package:parfait/core/novel/novel_entity.dart';
import 'package:parfait/core/novel/reader_settings.dart';
import 'package:parfait/core/settings/shared_preferences.dart';
import 'package:parfait/core/translation/translation_service.dart';
import 'package:parfait/core/user/user_entity.dart';
import 'package:parfait/features/novel/novel_layout.dart';
import 'package:parfait/features/novel/novel_reader.dart';
import 'package:parfait/features/novel/novel_reader_stage.dart';

import 'localized_app.dart';
import 'prompt_host.dart';
import 'test_preferences.dart';

const novelPageModeSettings = NovelReaderSettings(
  pageTurn: NovelPageTurn.pages,
);

NovelEntity testNovel(
  String text, {
  int id = 77,
  String title = 'A novel',
  String caption = 'caption',
}) => NovelEntity(
  id: id,
  title: title,
  caption: caption,
  user: const UserEntity(id: 8, name: 'author', account: 'author'),
  tags: const [],
  textLength: text.length,
  contentVersion: text,
  paragraphs: NovelContentMapper.fromText(text),
  contentAvailable: true,
);

/// A webview body with one uploaded image and one work's pages.
NovelEntity illustratedTestNovel(String text) => testNovel('').withWebContent(
  text,
  embeddedImages: const {
    '5': (
      large: 'https://i.pximg.net/u5.png',
      original: 'https://i.pximg.net/u5-original.png',
    ),
  },
  embeddedIllustThumbs: const {
    '9-2': 'https://i.pximg.net/9-2.jpg',
    '9': 'https://i.pximg.net/9.jpg',
  },
);

SharedPreferencesAsyncPlatform novelReaderSettingsPrefs(
  NovelReaderSettings settings,
) => memoryPreferences({
  'parfait.novel.reader_settings.v1': jsonEncode(settings.toJson()),
});

Future<NovelLayout> layoutTestNovel(
  NovelEntity novel, {
  NovelLayoutEngine? engine,
  Size viewport = const Size(360, 640),
  NovelLayoutStyle style = const NovelLayoutStyle(),
  Color textColor = Colors.black,
  Brightness brightness = Brightness.light,
  NovelTitleBlock? titleBlock,
  CancelToken? cancelToken,
}) => (engine ?? NovelLayoutEngine()).layoutDocumentCancellable(
  document: novel.markup!,
  contentVersion: novel.contentVersion,
  viewport: viewport,
  style: style,
  textColor: textColor,
  brightness: brightness,
  titleBlock: titleBlock,
  cancelToken: cancelToken,
);

Future<void> pumpNovelLayout(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> pumpNovelReader(
  WidgetTester tester, {
  Key? readerKey,
  required NovelEntity novel,
  NovelReaderSettings settings = const NovelReaderSettings(),
  NovelAnchor? initialAnchor,
  NovelReaderHandle? handle,
  NovelLayoutEngine? layoutEngine,
  NovelLayoutBudget budget = const NovelLayoutBudget(),
  double scrollTopPadding = 0,
  Map<String, String> translations = const {},
  VoidCallback? onCenterTap,
  void Function(int page, int pageCount)? onProgressChanged,
  void Function(NovelAnchor anchor, NovelAnchorCause cause)? onAnchorChanged,
  ValueChanged<NovelImageLoadRequest>? onImageTap,
  void Function(Uri uri)? onLinkTap,
  List<Override>? overrides,
  bool wrapProviderScope = false,
}) async {
  Widget app = localizedApp(
    overrides: overrides,
    body: NovelReader(
      key: readerKey,
      novel: novel,
      settings: settings,
      initialAnchor: initialAnchor,
      handle: handle,
      layoutEngine: layoutEngine,
      budget: budget,
      scrollTopPadding: scrollTopPadding,
      translations: translations,
      onCenterTap: onCenterTap,
      onProgressChanged: onProgressChanged,
      onAnchorChanged: onAnchorChanged,
      onImageTap: onImageTap,
      onLinkTap: onLinkTap,
    ),
  );
  if (wrapProviderScope) {
    app = ProviderScope(child: app);
  }
  await tester.pumpWidget(app);
  await pumpNovelLayout(tester);
}

Widget buildNovelStageApp(
  ReaderProgressBinding binding, {
  required NovelEntity novel,
  SharedPreferencesAsync? preferences,
  ThemeData? theme,
  TranslationTransport? translation,
  NovelPageTurn pageTurn = NovelPageTurn.pages,
  NovelSpreadMode spreadMode = NovelSpreadMode.auto,
  InputModality? inputModality,
  NovelMarkerBinding? marker,
  ProviderContainer? container,
}) {
  installPreferencesForTest(
    novelReaderSettingsPrefs(
      NovelReaderSettings(pageTurn: pageTurn, spreadMode: spreadMode),
    ),
  );
  final stage = NovelReaderStage(
    spec: NovelReaderStageSpec(
      novel: novel,
      infoTooltip: 'info',
      infoSheet: (context) => const Text('info sheet'),
      progress: binding,
      marker: marker,
    ),
  );
  return localizedApp(
    container: container,
    overrides: container != null
        ? null
        : [
            if (preferences != null)
              sharedPreferencesProvider.overrideWithValue(preferences),
            if (translation != null)
              translationServiceProvider.overrideWithValue(translation),
          ],
    builder: promptHostBuilder,
    theme: theme,
    body: inputModality == null
        ? stage
        : InputModalityScope(initialModality: inputModality, child: stage),
  );
}
