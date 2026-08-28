import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixiv_func/core/reverse_image/image_input.dart';
import 'package:pixiv_func/core/reverse_image/reverse_image_platform.dart';
import 'package:pixiv_func/features/search/reverse_image_search_page.dart';

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
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: ReverseImageSearchPage(platform: platform),
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
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: ReverseImageSearchPage(
          initialReference: reference,
          platform: platform,
        ),
      ),
    );
    await _pumpUntilVisible(tester, find.text('图片已准备好'));

    expect(find.text('图片已准备好'), findsOneWidget);
    expect(find.text('开始反向搜图'), findsOneWidget);
  });
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
