import 'dart:convert';
import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:parfait/core/network/pixiv_http_client.dart';
import 'package:parfait/core/reverse_image/image_input.dart';
import 'package:parfait/core/reverse_image/reverse_image_platform.dart';
import 'package:parfait/core/reverse_image/reverse_image_provider.dart';

/// Pumps until [finder] matches: the page copies and decodes the picked
/// file on real IO, which only advances under `runAsync`.
Future<void> pumpUntilVisible(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 40 && finder.evaluate().isEmpty; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// A 1×1 PNG at `image.png` in [directory].
File writeTinyPng(Directory directory) => File('${directory.path}/image.png')
  ..writeAsBytesSync(
    base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    ),
  );

class FakeReverseImagePlatform implements ReverseImageInputPlatform {
  FakeReverseImagePlatform(this.file, {this.mimeType = 'image/png'});

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
class FakeInAppWebViewPlatform extends InAppWebViewPlatform {
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

class OutcomeReverseImageProvider implements ReverseImageProvider {
  const OutcomeReverseImageProvider(this.outcome);

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
