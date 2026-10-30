import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:parfait/core/reverse_image/image_input.dart';
import 'package:parfait/core/reverse_image/reverse_image_engine.dart';
import 'package:parfait/core/reverse_image/reverse_image_platform.dart';
import 'package:parfait/core/reverse_image/reverse_image_provider.dart';
import 'package:parfait/core/settings/settings_repository.dart';
import 'package:parfait/features/search/reverse_image_search_page.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';
import 'package:parfait/l10n/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/connectivity_channels.dart';
import 'helpers/reverse_image_world.dart';
import 'helpers/test_preferences.dart';
import 'helpers/localized_app.dart';
import 'helpers/image_headers.dart';
import 'helpers/prompt_host.dart';

void main() {
  late Directory directory;
  late File image;
  late FakeReverseImagePlatform platform;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('reverse-image-page-');
    image = writeTinyPng(directory);
    platform = FakeReverseImagePlatform(image);
    SharedPreferencesAsyncPlatform.instance = memoryPreferences();
    InAppWebViewPlatform.instance = FakeInAppWebViewPlatform();
    answerConnectivityChannels();
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  testWidgets(
    'picker shows privacy and preview then a visible provider failure',
    (tester) async {
      await _pumpPage(
        tester,
        platform: platform,
        providers: {
          ReverseImageEngine.sauceNao: UnavailableReverseImageProvider(
            reason: 'structured service is unavailable',
          ),
        },
      );
      await tester.pumpAndSettle();

      expect(find.text('选择图片'), findsOneWidget);
      await tester.tap(find.text('选择图片'));
      await pumpUntilVisible(tester, find.text('图片已准备好'));
      expect(find.text('开始反向搜图'), findsOneWidget);

      await tester.tap(find.text('开始反向搜图'));
      await pumpUntilVisible(tester, find.text('SauceNAO 暂时无法使用'));
      // The failure keeps the prepared image so another engine can retry it.
      expect(platform.deletedPaths, isEmpty);
    },
  );

  testWidgets('ACTION_SEND reference enters the same prepared flow', (
    tester,
  ) async {
    const reference = ReverseImageInputReference(
      contentUri: 'content://share/42',
      mimeType: 'image/png',
      sizeBytes: 128,
      hasReadUriPermission: true,
      source: ReverseImageInputSource.androidSend,
    );
    await _pumpPage(
      tester,
      platform: platform,
      providers: {
        ReverseImageEngine.sauceNao: UnavailableReverseImageProvider(
          reason: 'structured service is unavailable',
        ),
      },
      initialReference: reference,
    );
    await pumpUntilVisible(tester, find.text('图片已准备好'));

    expect(find.text('图片已准备好'), findsWidgets);
    expect(find.text('开始反向搜图'), findsOneWidget);
  });

  testWidgets('rate limited search shows the wait seconds', (tester) async {
    await _pumpPage(
      tester,
      platform: platform,
      providers: {
        ReverseImageEngine.sauceNao: OutcomeReverseImageProvider(
          ReverseImageSearchFailure(
            code: ReverseImageProviderFailureCode.rateLimited,
            message: 'provider is rate limited',
            retryable: true,
            retryAfter: Duration(seconds: 27),
          ),
        ),
      },
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择图片'));
    await pumpUntilVisible(tester, find.text('开始反向搜图'));
    await tester.ensureVisible(find.text('开始反向搜图'));
    await tester.tap(find.text('开始反向搜图'));
    await pumpUntilVisible(tester, find.textContaining('27'));

    expect(find.text('约 27 秒后可重试'), findsOneWidget);
    // The big failure icon plus the error avatar on the failed engine's chip.
    expect(find.byIcon(Icons.error_outline), findsWidgets);
  });

  testWidgets('a challenge offers the engine web page with the image armed', (
    tester,
  ) async {
    final armer = _FakeArmer('content://armed/1');
    await _pumpPage(
      tester,
      platform: platform,
      uploadArmer: armer,
      providers: {
        ReverseImageEngine.sauceNao: OutcomeReverseImageProvider(
          ReverseImageSearchFailure(
            code: ReverseImageProviderFailureCode.challenge,
            message: 'SauceNAO returned a challenge page',
          ),
        ),
      },
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择图片'));
    await pumpUntilVisible(tester, find.text('开始反向搜图'));
    await tester.ensureVisible(find.text('开始反向搜图'));
    await tester.tap(find.text('开始反向搜图'));
    const challenge = 'SauceNAO 要求人机验证；可以在网页中完成验证后搜索';
    await pumpUntilVisible(tester, find.text(challenge));

    // The way out is the engine's own upload form, image armed.
    await tester.tap(find.text('在网页中搜索'));
    await pumpUntilVisible(tester, find.text('点按页面中的上传按钮开始搜索，已选图片会自动填入。'));
    expect(armer.armedPaths, hasLength(1));
  });

  testWidgets('engine chips switch the selection and persist it', (
    tester,
  ) async {
    await _pumpPage(
      tester,
      platform: platform,
      providers: {
        ReverseImageEngine.sauceNao: OutcomeReverseImageProvider(
          ReverseImageSearchSuccess(),
        ),
        ReverseImageEngine.iqdb: OutcomeReverseImageProvider(
          ReverseImageSearchSuccess(),
        ),
      },
    );
    await tester.pumpAndSettle();

    // All four engines are offered in idle state; SauceNAO is the default.
    expect(find.byType(ChoiceChip), findsNWidgets(4));
    expect(
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'SauceNAO'))
          .selected,
      isTrue,
    );

    await tester.tap(find.widgetWithText(ChoiceChip, 'IQDB'));
    await tester.pump();

    expect(
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'IQDB'))
          .selected,
      isTrue,
    );

    // Selection is durable — read the versioned settings blob back.
    final stored = await tester.runAsync(() async {
      final raw = await SharedPreferencesAsync().getString(
        PreferencesSettingsRepository.settingsKey,
      );
      return raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
    });
    expect(stored?['reverseImageEngine'], 'iqdb');
  });

  testWidgets('an engine choice that fails to save says so', (tester) async {
    SharedPreferencesAsyncPlatform.instance = StringWriteFailingPreferences();
    await _pumpPage(
      tester,
      platform: platform,
      providers: {
        ReverseImageEngine.sauceNao: OutcomeReverseImageProvider(
          ReverseImageSearchSuccess(),
        ),
      },
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ChoiceChip, 'IQDB'));
    await tester.pump();
    await tester.pump();

    // This visit keeps the choice; the next one starts from the old default.
    expect(
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'IQDB'))
          .selected,
      isTrue,
    );
    expect(find.textContaining('设置保存失败'), findsOneWidget);
  });

  testWidgets('an input outside engine constraints disables the search', (
    tester,
  ) async {
    final webp = File('${directory.path}/image.webp')
      ..writeAsBytesSync(webpHeader(64, 64));
    final webpPlatform = FakeReverseImagePlatform(webp, mimeType: 'image/webp');
    await _pumpPage(
      tester,
      platform: webpPlatform,
      providers: {
        ReverseImageEngine.sauceNao: OutcomeReverseImageProvider(
          ReverseImageSearchSuccess(),
        ),
      },
      initialEngine: ReverseImageEngine.iqdb,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择图片'));
    await pumpUntilVisible(tester, find.text('图片已准备好'));

    // IQDB only takes JPEG/PNG/GIF and is the restored selection: the
    // search stays disabled with a reason.
    expect(find.text('当前图片不满足该引擎的输入限制'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '开始反向搜图'))
          .onPressed,
      isNull,
    );
  });

  testWidgets('a WebUpload outcome arms the file and shows the tap hint', (
    tester,
  ) async {
    final armer = _FakeArmer('content://armed/1');
    await _pumpPage(
      tester,
      platform: platform,
      providers: {
        ReverseImageEngine.ascii2d: OutcomeReverseImageProvider(
          ReverseImageSearchWebUpload(
            engine: ReverseImageEngine.ascii2d,
            uploadPageUrl: Uri.parse('https://ascii2d.net/'),
            imagePath: image.path,
            imageMimeType: 'image/png',
            observedAt: 'test',
          ),
        ),
      },
      initialEngine: ReverseImageEngine.ascii2d,
      uploadArmer: armer,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择图片'));
    await pumpUntilVisible(tester, find.text('开始反向搜图'));
    await tester.ensureVisible(find.text('开始反向搜图'));
    await tester.tap(find.text('开始反向搜图'));
    await pumpUntilVisible(tester, find.text('点按页面中的上传按钮开始搜索，已选图片会自动填入。'));

    expect(armer.armedPaths, [image.path]);
    expect(find.text('点按页面中的上传按钮开始搜索，已选图片会自动填入。'), findsOneWidget);
    expect(find.text('请在页面的文件选择框中重新选择同一张图片。'), findsNothing);
    // The owned file stays alive for the whole upload flow.
    expect(platform.deletedPaths, isEmpty);
  });

  testWidgets('a failure offers the same-engine retry and the next engine', (
    tester,
  ) async {
    await _pumpPage(
      tester,
      platform: platform,
      providers: {
        ReverseImageEngine.sauceNao: UnavailableReverseImageProvider(
          reason: 'structured service is unavailable',
        ),
      },
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择图片'));
    await pumpUntilVisible(tester, find.text('开始反向搜图'));
    await tester.ensureVisible(find.text('开始反向搜图'));
    await tester.tap(find.text('开始反向搜图'));
    await pumpUntilVisible(tester, find.text('重试当前引擎'));

    // The header's engine chip is the one picker, marked as failed.
    expect(find.byType(ChoiceChip), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('reverseTaskHeader')),
        matching: find.byIcon(Icons.error_outline),
      ),
      findsWidgets,
    );
    expect(find.text('SauceNAO 暂时无法使用'), findsOneWidget);
    expect(find.text('重试当前引擎'), findsOneWidget);
    // The next engine that takes the image is one tap away.
    expect(find.text('换用 IQDB 搜索'), findsOneWidget);
    expect(find.text('重新选择'), findsOneWidget);
  });

  testWidgets('no match leads to the next engine, then to another image', (
    tester,
  ) async {
    // A WebP: IQDB cannot take it, so after SauceNAO comes Ascii2D's turn.
    final webp = File('${directory.path}/image.webp')
      ..writeAsBytesSync(webpHeader(64, 64));
    await _pumpPage(
      tester,
      platform: FakeReverseImagePlatform(webp, mimeType: 'image/webp'),
      providers: {
        for (final engine in ReverseImageEngine.values)
          engine: OutcomeReverseImageProvider(ReverseImageSearchSuccess()),
      },
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择图片'));
    await pumpUntilVisible(tester, find.text('开始反向搜图'));
    await tester.tap(find.text('开始反向搜图'));
    await pumpUntilVisible(tester, find.text('换用 Ascii2D 搜索'));

    // One way on, and the image is still there to take it.
    expect(find.byType(FilledButton), findsOneWidget);
    expect(find.byType(OutlinedButton), findsNothing);
    await tester.tap(find.text('换用 Ascii2D 搜索'));
    await pumpUntilVisible(tester, find.text('换用 TinEye 搜索'));
    await tester.tap(find.text('换用 TinEye 搜索'));
    await pumpUntilVisible(tester, find.text('所有引擎都没有找到匹配结果'));
    expect(find.widgetWithText(FilledButton, '重新选择'), findsOneWidget);
  });

  testWidgets('progress cancel stops the search but stays on the page', (
    tester,
  ) async {
    final provider = OutcomeReverseImageProvider.blocking();
    await _pumpPushedPage(
      tester,
      platform: platform,
      providers: {ReverseImageEngine.sauceNao: provider},
    );

    await tester.tap(find.text('选择图片'));
    await pumpUntilVisible(tester, find.text('开始反向搜图'));
    await tester.ensureVisible(find.text('开始反向搜图'));
    await tester.tap(find.text('开始反向搜图'));
    await pumpUntilVisible(tester, find.text('正在搜索…'));

    // Cancelling the in-flight search is not leaving: the prepared image
    // comes back on the ready screen.
    await tester.tap(find.text('取消'));
    await pumpUntilVisible(tester, find.text('图片已准备好'));

    expect(find.byType(ReverseImageSearchPage), findsOneWidget);
    expect(find.text('图片已准备好'), findsWidgets);
    expect(find.text('开始反向搜图'), findsOneWidget);
    expect(platform.deletedPaths, isEmpty);
  });

  group('task header', () {
    final header = find.byKey(const ValueKey('reverseTaskHeader'));
    Finder headerText(String text) =>
        find.descendant(of: header, matching: find.text(text));
    Finder thumb() => find.descendant(of: header, matching: find.byType(Image));

    testWidgets('ready/searching/failure keep image, engine and phase', (
      tester,
    ) async {
      final provider = OutcomeReverseImageProvider.blocking();
      await _pumpPage(
        tester,
        platform: platform,
        providers: {ReverseImageEngine.sauceNao: provider},
      );
      await tester.pumpAndSettle();

      // No image context yet — the strip stays out of the idle picker.
      expect(header, findsNothing);

      await tester.tap(find.text('选择图片'));
      await pumpUntilVisible(tester, find.text('图片已准备好'));
      expect(header, findsOneWidget);
      expect(thumb(), findsOneWidget);
      expect(headerText('SauceNAO'), findsOneWidget);
      expect(headerText('图片已准备好'), findsOneWidget);

      await tester.ensureVisible(find.text('开始反向搜图'));
      await tester.tap(find.text('开始反向搜图'));
      await pumpUntilVisible(tester, find.text('正在搜索…'));
      // In-flight: same image, same engine, searching phase.
      expect(header, findsOneWidget);
      expect(thumb(), findsOneWidget);
      expect(headerText('SauceNAO'), findsOneWidget);
      expect(headerText('正在搜索…'), findsOneWidget);
      // The chip is inert while a search owns the engine slot — bounded
      // pumps only, the in-flight spinner never lets the tree settle.
      await tester.tap(headerText('SauceNAO'), warnIfMissed: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('IQDB'), findsNothing);

      provider.blocker!.complete(
        const ReverseImageSearchFailure(
          code: ReverseImageProviderFailureCode.providerUnavailable,
          message: 'unavailable',
        ),
      );
      await pumpUntilVisible(tester, find.text('搜索失败'));
      expect(header, findsOneWidget);
      expect(thumb(), findsOneWidget);
      expect(headerText('SauceNAO'), findsOneWidget);
      expect(headerText('搜索失败'), findsOneWidget);
    });
  });
}

class _PushedHost extends StatelessWidget {
  const _PushedHost({required this.platform, required this.providers});

  final ReverseImageInputPlatform platform;
  final Map<ReverseImageEngine, ReverseImageProvider> providers;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () => Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => ReverseImageSearchPage(
                platform: platform,
                providers: providers,
              ),
            ),
          ),
          child: const Text('open reverse search'),
        ),
      ),
    );
  }
}

Future<void> _pumpPushedPage(
  WidgetTester tester, {
  required ReverseImageInputPlatform platform,
  required Map<ReverseImageEngine, ReverseImageProvider> providers,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      child: localizedApp(
        home: _PushedHost(platform: platform, providers: providers),
      ),
    ),
  );
  await tester.pump();
  await tester.tap(find.text('open reverse search'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 800));
}

Future<void> _pumpPage(
  WidgetTester tester, {
  required ReverseImageInputPlatform platform,
  required Map<ReverseImageEngine, ReverseImageProvider> providers,
  ReverseImageInputReference? initialReference,
  ReverseImageEngine? initialEngine,
  ReverseImageUploadArmer? uploadArmer,
  Key? pageKey,
}) {
  return tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh', 'CN'),
        builder: promptHostBuilder,
        home: ReverseImageSearchPage(
          // A distinct key forces a fresh State+session — re-pumping the
          // same runtimeType otherwise lands in didUpdateWidget and the
          // old flow survives.
          key: pageKey,
          initialReference: initialReference,
          platform: platform,
          providers: providers,
          initialEngine: initialEngine,
          uploadArmer: uploadArmer,
        ),
      ),
    ),
  );
}

class _FakeArmer implements ReverseImageUploadArmer {
  _FakeArmer(this.result);

  final String? result;
  final armedPaths = <String>[];
  int disarmCount = 0;

  @override
  Future<String?> armUpload(String path) async {
    armedPaths.add(path);
    return result;
  }

  @override
  Future<void> disarmUpload() async {
    disarmCount++;
  }
}
