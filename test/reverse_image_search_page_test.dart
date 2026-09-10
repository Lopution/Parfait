import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/network/pixiv_http_client.dart';
import 'package:pixiv_func/core/reverse_image/image_input.dart';
import 'package:pixiv_func/core/reverse_image/reverse_image_platform.dart';
import 'package:pixiv_func/core/reverse_image/reverse_image_provider.dart';
import 'package:pixiv_func/features/search/reverse_image_search_page.dart';
import 'package:pixiv_func/l10n/app_localizations_delegates.dart';
import 'package:pixiv_func/l10n/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
        provider: UnavailableReverseImageProvider(
          reason: 'structured service is unavailable',
        ),
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
      expect(platform.deletedPaths, [image.path]);
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
      provider: UnavailableReverseImageProvider(
        reason: 'structured service is unavailable',
      ),
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
      provider: const _OutcomeProvider(
        ReverseImageSearchFailure(
          code: ReverseImageProviderFailureCode.rateLimited,
          message: 'provider is rate limited',
          retryable: true,
          retryAfter: Duration(seconds: 27),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择图片'));
    await _pumpUntilVisible(tester, find.text('开始反向搜图'));
    await tester.ensureVisible(find.text('开始反向搜图'));
    await tester.tap(find.text('开始反向搜图'));
    await _pumpUntilVisible(tester, find.textContaining('27'));

    expect(find.text('约 27 秒后可重试'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
  });

  testWidgets('no-match success shows the empty-results copy', (tester) async {
    await _pumpPage(
      tester,
      platform: platform,
      provider: const _OutcomeProvider(ReverseImageSearchSuccess([])),
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
      provider: const _OutcomeProvider(
        ReverseImageSearchFailure(
          code: ReverseImageProviderFailureCode.dailyLimit,
          message: 'SauceNAO daily search limit reached',
          retryable: true,
        ),
      ),
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
      provider: const _OutcomeProvider(
        ReverseImageSearchFailure(
          code: ReverseImageProviderFailureCode.challenge,
          message: 'SauceNAO returned a challenge page',
        ),
      ),
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
}

Future<void> _pumpPage(
  WidgetTester tester, {
  required ReverseImageInputPlatform platform,
  required ReverseImageProvider provider,
  ReverseImageInputReference? initialReference,
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
          provider: provider,
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
  _FakePlatform(this.file);

  final File file;
  final deletedPaths = <String>[];

  @override
  Future<String> copyToOwnedFile(ReverseImageInputReference reference) async =>
      file.path;

  @override
  Future<void> deleteOwnedFile(String path) async => deletedPaths.add(path);

  @override
  Future<ReverseImageInputReference?> pickImage() async =>
      const ReverseImageInputReference(
        contentUri: 'content://picker/1',
        mimeType: 'image/png',
        sizeBytes: 128,
        hasReadUriPermission: true,
        source: ReverseImageInputSource.picker,
      );
}

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
