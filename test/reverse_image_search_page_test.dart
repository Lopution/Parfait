import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:pixiv_func/core/reverse_image/image_input.dart';
import 'package:pixiv_func/core/reverse_image/reverse_image_engine.dart';
import 'package:pixiv_func/core/reverse_image/reverse_image_platform.dart';
import 'package:pixiv_func/core/reverse_image/reverse_image_provider.dart';
import 'package:pixiv_func/core/settings/settings_repository.dart';
import 'package:pixiv_func/features/search/reverse_image_search_page.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';
import 'package:pixiv_func/l10n/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'helpers/test_preferences.dart';

void main() {
  late Directory directory;
  late File image;
  late _FakePlatform platform;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('reverse-image-page-');
    image = File('${directory.path}/image.png')
      ..writeAsBytesSync(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
        ),
      );
    platform = _FakePlatform(image);
    SharedPreferencesAsyncPlatform.instance = memoryPreferences();
    InAppWebViewPlatform.instance = _FakeInAppWebViewPlatform();
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

      expect(find.text('隐私提示'), findsOneWidget);
      expect(find.text('选择图片'), findsOneWidget);
      await tester.tap(find.text('选择图片'));
      await _pumpUntilVisible(tester, find.text('图片已准备好'));
      expect(find.text('图片已准备好'), findsOneWidget);
      expect(find.text('开始反向搜图'), findsOneWidget);

      await tester.ensureVisible(find.text('开始反向搜图'));
      await tester.tap(find.text('开始反向搜图'));
      await _pumpUntilVisible(
        tester,
        find.text('当前没有通过凭据、服务条款和隐私审查的结构化服务；不会上传图片或执行网页抓取。'),
      );
      expect(find.text('反向搜图暂不可用'), findsNothing);
      expect(
        find.text('当前没有通过凭据、服务条款和隐私审查的结构化服务；不会上传图片或执行网页抓取。'),
        findsOneWidget,
      );
      // The failure keeps the prepared image so another engine can retry it.
      expect(platform.deletedPaths, isEmpty);
    },
  );

  testWidgets('ready state can repick or clear the selected image', (
    tester,
  ) async {
    await _pumpPage(tester, platform: platform, providers: const {});
    await tester.pumpAndSettle();

    await tester.tap(find.text('选择图片'));
    await _pumpUntilVisible(tester, find.text('图片已准备好'));

    // Repick replaces the prepared input and stays on the ready screen.
    await tester.ensureVisible(find.text('重新选择'));
    await tester.tap(find.text('重新选择'));
    await _pumpUntilVisible(tester, find.text('图片已准备好'));
    expect(platform.pickCount, 2);

    // Clear releases the input and returns to the idle picker.
    await tester.ensureVisible(find.text('取消'));
    await tester.tap(find.text('取消'));
    await _pumpUntilVisible(tester, find.text('选择图片'));
    expect(find.text('图片已准备好'), findsNothing);
    expect(platform.deletedPaths, isNotEmpty);
  });

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
    await _pumpUntilVisible(tester, find.text('图片已准备好'));

    expect(find.text('图片已准备好'), findsOneWidget);
    expect(find.text('开始反向搜图'), findsOneWidget);
  });

  testWidgets('rate limited search shows the wait seconds', (tester) async {
    await _pumpPage(
      tester,
      platform: platform,
      providers: {
        ReverseImageEngine.sauceNao: const _OutcomeProvider(
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
    await _pumpUntilVisible(tester, find.text('开始反向搜图'));
    await tester.ensureVisible(find.text('开始反向搜图'));
    await tester.tap(find.text('开始反向搜图'));
    await _pumpUntilVisible(tester, find.textContaining('27'));

    expect(find.text('约 27 秒后可重试'), findsOneWidget);
    // The big failure icon plus the error avatar on the failed engine's chip.
    expect(find.byIcon(Icons.error_outline), findsWidgets);
  });

  testWidgets('no-match success shows the empty-results copy', (tester) async {
    await _pumpPage(
      tester,
      platform: platform,
      providers: {
        ReverseImageEngine.sauceNao: const _OutcomeProvider(
          ReverseImageSearchSuccess([]),
        ),
      },
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择图片'));
    await _pumpUntilVisible(tester, find.text('开始反向搜图'));
    await tester.ensureVisible(find.text('开始反向搜图'));
    await tester.tap(find.text('开始反向搜图'));
    await _pumpUntilVisible(tester, find.text('没有找到匹配结果'));

    expect(find.text('没有找到匹配结果'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsNothing);
  });

  testWidgets('daily-limit failure shows the quota copy without countdown', (
    tester,
  ) async {
    await _pumpPage(
      tester,
      platform: platform,
      providers: {
        ReverseImageEngine.sauceNao: const _OutcomeProvider(
          ReverseImageSearchFailure(
            code: ReverseImageProviderFailureCode.dailyLimit,
            message: 'SauceNAO daily search limit reached',
            retryable: true,
          ),
        ),
      },
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择图片'));
    await _pumpUntilVisible(tester, find.text('开始反向搜图'));
    await tester.ensureVisible(find.text('开始反向搜图'));
    await tester.tap(find.text('开始反向搜图'));
    await _pumpUntilVisible(tester, find.text('今日匿名搜索额度已用完，明天再试'));

    expect(find.text('今日匿名搜索额度已用完，明天再试'), findsOneWidget);
    expect(find.textContaining('秒后可重试'), findsNothing);
  });

  testWidgets('challenge failure shows the human-verification copy', (
    tester,
  ) async {
    await _pumpPage(
      tester,
      platform: platform,
      providers: {
        ReverseImageEngine.sauceNao: const _OutcomeProvider(
          ReverseImageSearchFailure(
            code: ReverseImageProviderFailureCode.challenge,
            message: 'SauceNAO returned a challenge page',
          ),
        ),
      },
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择图片'));
    await _pumpUntilVisible(tester, find.text('开始反向搜图'));
    await tester.ensureVisible(find.text('开始反向搜图'));
    await tester.tap(find.text('开始反向搜图'));
    await _pumpUntilVisible(tester, find.text('SauceNAO 要求人机验证，本次搜索未完成，请稍后再试'));

    expect(find.text('SauceNAO 要求人机验证，本次搜索未完成，请稍后再试'), findsOneWidget);
    expect(find.text('当前没有通过凭据、服务条款和隐私审查的结构化服务；不会上传图片或执行网页抓取。'), findsNothing);
  });

  testWidgets('engine chips switch the selection and persist it', (
    tester,
  ) async {
    await _pumpPage(
      tester,
      platform: platform,
      providers: {
        ReverseImageEngine.sauceNao: const _OutcomeProvider(
          ReverseImageSearchSuccess([]),
        ),
        ReverseImageEngine.iqdb: const _OutcomeProvider(
          ReverseImageSearchSuccess([]),
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

  testWidgets('an input outside engine constraints disables that chip', (
    tester,
  ) async {
    final webp = File('${directory.path}/image.webp')
      ..writeAsBytesSync(_webpHeader(64, 64));
    final webpPlatform = _FakePlatform(webp, mimeType: 'image/webp');
    await _pumpPage(
      tester,
      platform: webpPlatform,
      providers: {
        ReverseImageEngine.sauceNao: const _OutcomeProvider(
          ReverseImageSearchSuccess([]),
        ),
      },
      initialEngine: ReverseImageEngine.iqdb,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择图片'));
    await _pumpUntilVisible(tester, find.text('图片已准备好'));

    // IQDB only takes JPEG/PNG/GIF: its chip is disabled and, because it is
    // the restored selection, the search button stays disabled with a reason.
    expect(
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'IQDB'))
          .onSelected,
      isNull,
    );
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
        ReverseImageEngine.ascii2d: _OutcomeProvider(
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
    await _pumpUntilVisible(tester, find.text('开始反向搜图'));
    await tester.ensureVisible(find.text('开始反向搜图'));
    await tester.tap(find.text('开始反向搜图'));
    await _pumpUntilVisible(tester, find.text('点按页面中的上传按钮开始搜索，已选图片会自动填入。'));

    expect(armer.armedPaths, [image.path]);
    expect(find.text('点按页面中的上传按钮开始搜索，已选图片会自动填入。'), findsOneWidget);
    expect(find.text('请在页面的文件选择框中重新选择同一张图片。'), findsNothing);
    // The owned file stays alive for the whole upload flow.
    expect(platform.deletedPaths, isEmpty);
  });

  testWidgets('a noop armer surfaces the desktop re-pick hint', (tester) async {
    await _pumpPage(
      tester,
      platform: platform,
      providers: {
        ReverseImageEngine.ascii2d: _OutcomeProvider(
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
      uploadArmer: const NoopReverseImageUploadArmer(),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择图片'));
    await _pumpUntilVisible(tester, find.text('开始反向搜图'));
    await tester.ensureVisible(find.text('开始反向搜图'));
    await tester.tap(find.text('开始反向搜图'));
    await _pumpUntilVisible(tester, find.text('请在页面的文件选择框中重新选择同一张图片。'));

    expect(find.text('请在页面的文件选择框中重新选择同一张图片。'), findsOneWidget);
  });

  testWidgets('a failure keeps the engine chips and the same-engine retry', (
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
    await _pumpUntilVisible(tester, find.text('开始反向搜图'));
    await tester.ensureVisible(find.text('开始反向搜图'));
    await tester.tap(find.text('开始反向搜图'));
    await _pumpUntilVisible(tester, find.text('重试当前引擎'));

    expect(find.byType(ChoiceChip), findsNWidgets(4));
    // The failed engine is marked on its chip.
    expect(
      find.descendant(
        of: find.widgetWithText(ChoiceChip, 'SauceNAO'),
        matching: find.byIcon(Icons.error_outline),
      ),
      findsOneWidget,
    );
    expect(find.text('重试当前引擎'), findsOneWidget);
    expect(find.text('重新选择'), findsOneWidget);
  });

  testWidgets('progress cancel stops the search but stays on the page', (
    tester,
  ) async {
    final provider = _BlockingProvider();
    await _pumpPushedPage(
      tester,
      platform: platform,
      providers: {ReverseImageEngine.sauceNao: provider},
    );

    await tester.tap(find.text('选择图片'));
    await _pumpUntilVisible(tester, find.text('开始反向搜图'));
    await tester.ensureVisible(find.text('开始反向搜图'));
    await tester.tap(find.text('开始反向搜图'));
    await _pumpUntilVisible(tester, find.text('正在搜索…'));

    // Cancelling the in-flight search is not leaving: the prepared image
    // comes back on the ready screen.
    await tester.tap(find.text('取消'));
    await _pumpUntilVisible(tester, find.text('图片已准备好'));

    expect(find.byType(ReverseImageSearchPage), findsOneWidget);
    expect(find.text('图片已准备好'), findsOneWidget);
    expect(find.text('开始反向搜图'), findsOneWidget);
    expect(platform.deletedPaths, isEmpty);
  });

  testWidgets('the app bar back button cancels the search and pops', (
    tester,
  ) async {
    final provider = _BlockingProvider();
    await _pumpPushedPage(
      tester,
      platform: platform,
      providers: {ReverseImageEngine.sauceNao: provider},
    );

    await tester.tap(find.text('选择图片'));
    await _pumpUntilVisible(tester, find.text('开始反向搜图'));
    await tester.ensureVisible(find.text('开始反向搜图'));
    await tester.tap(find.text('开始反向搜图'));
    await _pumpUntilVisible(tester, find.text('正在搜索…'));

    await tester.tap(find.byIcon(Icons.arrow_back));
    // The pop transition outlives the ~300ms default — give it real frames.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));

    // The route is gone and the owned image was released by cancel().
    expect(find.text('open reverse search'), findsOneWidget);
    expect(find.byType(ReverseImageSearchPage), findsNothing);
    expect(platform.deletedPaths, isNotEmpty);
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
      child: MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh', 'CN'),
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
}) {
  return tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh', 'CN'),

        home: ReverseImageSearchPage(
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

Future<void> _pumpUntilVisible(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 40 && finder.evaluate().isEmpty; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

class _FakePlatform implements ReverseImageInputPlatform {
  _FakePlatform(this.file, {this.mimeType = 'image/png'});

  final File file;
  final String mimeType;
  final deletedPaths = <String>[];
  var pickCount = 0;

  @override
  Future<String> copyToOwnedFile(ReverseImageInputReference reference) async =>
      file.path;

  @override
  Future<void> deleteOwnedFile(String path) async => deletedPaths.add(path);

  @override
  Future<ReverseImageInputReference?> pickImage() async {
    pickCount++;
    return ReverseImageInputReference(
      contentUri: 'content://picker/1',
      mimeType: mimeType,
      sizeBytes: 128,
      hasReadUriPermission: true,
      source: ReverseImageInputSource.picker,
    );
  }
}

/// Minimal InAppWebView platform stub — the real implementations are
/// Android/iOS/macOS/Windows only, so the widget cannot build in a Linux
/// widget test without one.
class _FakeInAppWebViewPlatform extends InAppWebViewPlatform {
  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) => _FakeInAppWebViewWidget(params);
}

class _FakeInAppWebViewWidget extends PlatformInAppWebViewWidget {
  _FakeInAppWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.expand();

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
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

// Same minimal RIFF/WEBP (VP8 lossy) fixture the IQDB provider test uses.
List<int> _webpHeader(int width, int height) => [
  0x52,
  0x49,
  0x46,
  0x46,
  14 & 0xff,
  0,
  0,
  0,
  0x57,
  0x45,
  0x42,
  0x50,
  0x56,
  0x50,
  0x38,
  0x20,
  14 & 0xff,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0x9d,
  0x01,
  0x2a,
  0,
  width & 0xff,
  (width >> 8) & 0xff,
  height & 0xff,
  (height >> 8) & 0xff,
];

class _OutcomeProvider implements ReverseImageProvider {
  const _OutcomeProvider(this.outcome);

  final ReverseImageSearchOutcome outcome;

  @override
  ReverseImageProviderCapability get capability =>
      const ReverseImageProviderCapability(
        name: 'test-provider',
        kind: ReverseImageProviderKind.structuredApi,
        enabled: true,
        observedAt: 'test',
        reason: 'test-only provider',
      );

  @override
  Future<ReverseImageSearchOutcome> search(
    OwnedReverseImageInput input, {
    CancelToken? cancelToken,
  }) async => outcome;
}

/// A provider whose search never finishes on its own — [blocker] lets a
/// test decide when (or whether) the in-flight search resolves.
class _BlockingProvider implements ReverseImageProvider {
  final blocker = Completer<ReverseImageSearchOutcome>();

  @override
  ReverseImageProviderCapability get capability =>
      const ReverseImageProviderCapability(
        name: 'blocking-provider',
        kind: ReverseImageProviderKind.structuredApi,
        enabled: true,
        observedAt: 'test',
        reason: 'test-only provider',
      );

  @override
  Future<ReverseImageSearchOutcome> search(
    OwnedReverseImageInput input, {
    CancelToken? cancelToken,
  }) => blocker.future;
}
