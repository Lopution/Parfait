import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:parfait/core/platform/app_storage_paths.dart';
import 'package:parfait/core/platform/desktop_file_drop.dart';
import 'package:parfait/core/platform/image_clipboard.dart';
import 'package:parfait/core/platform/platform_caps.dart';
import 'package:parfait/core/reverse_image/image_input.dart';
import 'package:parfait/core/reverse_image/reverse_image_engine.dart';
import 'package:parfait/core/reverse_image/reverse_image_external.dart';
import 'package:parfait/core/reverse_image/reverse_image_platform.dart';
import 'package:parfait/core/reverse_image/reverse_image_provider.dart';
import 'package:parfait/features/search/reverse_image_html_results_view.dart';
import 'package:parfait/features/search/reverse_image_search_page.dart';
import 'package:parfait/l10n/app_localizations_delegates.dart';
import 'package:parfait/l10n/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'helpers/connectivity_channels.dart';
import 'helpers/reverse_image_world.dart';
import 'helpers/localized_app.dart';
import 'helpers/image_headers.dart';
import 'helpers/prompt_host.dart';
import 'package:parfait/app/icons/ui_icons.dart';

void main() {
  late Directory directory;
  late File image;
  late FakeReverseImagePlatform platform;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('reverse-image-page-');
    image = writeTinyPng(directory);
    platform = FakeReverseImagePlatform(image);
    InAppWebViewPlatform.instance = FakeInAppWebViewPlatform();
    answerConnectivityChannels();
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
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
    expect(find.byIcon(UiIcons.errorOutline), findsWidgets);
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

  testWidgets('reads platformCapsProvider instead of static host platform', (
    tester,
  ) async {
    const channel = MethodChannel('parfait/reverse_image_input');
    final methods = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      methods.add(call.method);
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    await tester.pumpWidget(
      localizedApp(
        overrides: [
          platformCapsProvider.overrideWithValue(
            const PlatformCaps(isAndroid: true),
          ),
        ],
        home: ReverseImageSearchPage(
          providers: {
            ReverseImageEngine.sauceNao: UnavailableReverseImageProvider(
              reason: 'unused',
            ),
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择图片'));
    await tester.pump();
    expect(methods, ['pickImage']);
  });

  testWidgets(
    'shows browser fallback for resultUrl and parsed clickable matches for HTML on Linux',
    (tester) async {
      await _pumpPage(
        tester,
        platform: platform,
        caps: const PlatformCaps(isLinux: true),
        providers: {
          ReverseImageEngine.sauceNao: OutcomeReverseImageProvider(
            ReverseImageSearchWebView(
              resultUrl: Uri.parse('https://saucenao.com/search.php?url=x'),
              observedAt: 'test',
            ),
          ),
        },
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择图片'));
      await pumpUntilVisible(tester, find.text('开始反向搜图'));
      await tester.tap(find.text('开始反向搜图'));
      await pumpUntilVisible(tester, find.text('在浏览器打开'));
      expect(find.byType(InAppWebView), findsNothing);

      // Linux HTTP 200 HTML response renders clickable matches instead of a
      // blank engine homepage fallback.
      final openedExternal = <Uri>[];
      final pushedLocations = <String>[];
      const html = '''
        <div class="result">
          <table><tr><td class="resulttablecontent">
            <div class="resultsimilarityinfo">96.4%</div>
            <div class="resulttitle"><strong>Moonlit Harbor</strong></div>
            <a href="https://www.pixiv.net/artworks/424242">424242</a>
          </td></tr></table>
        </div>
        <div class="result">
          <table><tr><td class="resulttablecontent">
            <div class="resultsimilarityinfo">87.2%</div>
            <div class="resulttitle"><strong>External Mirror</strong></div>
            <a href="https://danbooru.donmai.us/posts/777">post</a>
          </td></tr></table>
        </div>
      ''';
      final router = GoRouter(
        initialLocation: '/reverse-image',
        routes: [
          GoRoute(
            path: '/reverse-image',
            builder: (_, _) => ReverseImageSearchPage(
              platform: platform,
              externalLauncher: _RecordingExternalLauncher(openedExternal),
              providers: {
                ReverseImageEngine.sauceNao: OutcomeReverseImageProvider(
                  ReverseImageSearchWebView(html: html, observedAt: 'test'),
                ),
              },
            ),
            routes: [
              GoRoute(
                path: 'illust/:id',
                builder: (_, state) {
                  pushedLocations.add(state.uri.toString());
                  return Scaffold(
                    body: Text('illust-${state.pathParameters['id']}'),
                  );
                },
              ),
            ],
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            platformCapsProvider.overrideWithValue(
              const PlatformCaps(isLinux: true),
            ),
          ],
          child: MaterialApp.router(
            routerConfig: router,
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh', 'CN'),
            builder: promptHostBuilder,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择图片'));
      await pumpUntilVisible(tester, find.text('开始反向搜图'));
      await tester.tap(find.text('开始反向搜图'));
      await pumpUntilVisible(tester, find.text('Moonlit Harbor'));

      expect(find.byType(InAppWebView), findsNothing);
      expect(find.byType(ReverseImageHtmlResultsView), findsOneWidget);
      expect(find.text('96.4%'), findsOneWidget);
      expect(find.text('External Mirror'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('reverse-html-match-1')));
      await tester.pump();
      expect(openedExternal, [
        Uri.parse('https://danbooru.donmai.us/posts/777'),
      ]);

      await tester.tap(find.byKey(const ValueKey('reverse-html-match-0')));
      await tester.pumpAndSettle();
      expect(pushedLocations, ['/reverse-image/illust/424242']);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets(
    'desktop Ctrl+V pastes clipboard image, reports empty clipboard, and handles file drop',
    (tester) async {
      final previousPaths = AppStoragePaths.active;
      AppStoragePaths.setActive(
        AppStoragePaths.dev(directory, profileName: 'rev-test'),
      );
      addTearDown(() => AppStoragePaths.setActive(previousPaths));

      Uint8List? clipboardImage;
      final dropEvents = StreamController<DesktopFileDropEvent>.broadcast();
      addTearDown(dropEvents.close);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            platformCapsProvider.overrideWithValue(
              const PlatformCaps(isWindows: true),
            ),
            desktopImageClipboardReaderProvider.overrideWithValue((
              targetPath,
            ) async {
              final bytes = clipboardImage;
              if (bytes == null || bytes.isEmpty) return false;
              await File(targetPath).writeAsBytes(bytes, flush: true);
              return true;
            }),
            desktopFileDropSourceProvider.overrideWithValue(
              _StreamDropSource(dropEvents.stream),
            ),
          ],
          child: MaterialApp(
            localizationsDelegates: appLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh', 'CN'),
            builder: promptHostBuilder,
            home: ReverseImageSearchPage(
              platform: platform,
              providers: {
                ReverseImageEngine.sauceNao: UnavailableReverseImageProvider(
                  reason: 'unused',
                ),
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Empty clipboard via Ctrl+V shows prompt.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await pumpUntilVisible(tester, find.text('剪贴板中没有图片'));

      // Paste valid PNG bytes via button -> ready state.
      clipboardImage = image.readAsBytesSync();
      await tester.tap(find.text('粘贴图片'));
      await pumpUntilVisible(tester, find.text('开始反向搜图'));

      // Drag enter shows highlight overlay; drop prepares the dropped image.
      dropEvents.add(const DesktopFileDropEntered());
      await tester.pump();
      expect(
        find.byKey(const ValueKey('desktop-file-drop-overlay')),
        findsOneWidget,
      );
      dropEvents.add(DesktopFileDropped([image.path]));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('desktop-file-drop-overlay')),
        findsNothing,
      );
      await pumpUntilVisible(tester, find.text('开始反向搜图'));
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}

class _StreamDropSource implements DesktopFileDropSource {
  const _StreamDropSource(this.events);

  @override
  final Stream<DesktopFileDropEvent> events;
}

class _RecordingExternalLauncher implements ReverseImageExternalLauncher {
  _RecordingExternalLauncher(this.opened);

  final List<Uri> opened;

  @override
  Future<void> open(Uri uri) async {
    validateExternalResultUrl(uri);
    opened.add(uri);
  }
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
  PlatformCaps? caps,
  Key? pageKey,
}) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: [
        platformCapsProvider.overrideWithValue(
          caps ?? const PlatformCaps(isAndroid: true),
        ),
      ],
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
  Future<String?> armUpload(
    String path, {
    Set<String> allowedHosts = const {},
  }) async {
    armedPaths.add(path);
    return result;
  }

  @override
  Future<void> disarmUpload() async {
    disarmCount++;
  }
}
