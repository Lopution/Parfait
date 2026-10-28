import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:parfait/core/network/pixiv_http_client.dart';
import 'package:parfait/core/reverse_image/image_input.dart';
import 'package:parfait/core/reverse_image/reverse_image_platform.dart';
import 'package:parfait/core/reverse_image/reverse_image_provider.dart';
import 'waits.dart';

export 'fake_webview.dart';

/// Pumps until [finder] matches: the page copies and decodes the picked
/// file on real IO, which only advances under `runAsync`.
Future<void> pumpUntilVisible(WidgetTester tester, Finder finder) =>
    pumpIoUntil(
      tester,
      () => finder.tryEvaluate(),
      io: const Duration(milliseconds: 10),
      step: const Duration(milliseconds: 50),
      rounds: 40,
    );

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

/// Answers every search with [outcome]; while [blocker] is set, a search
/// waits for the test to complete it instead.
class OutcomeReverseImageProvider implements ReverseImageProvider {
  OutcomeReverseImageProvider(this.outcome, {this.blocker});

  /// A search that never finishes on its own.
  OutcomeReverseImageProvider.blocking()
    : this(const ReverseImageSearchSuccess(), blocker: Completer());

  final ReverseImageSearchOutcome outcome;
  Completer<ReverseImageSearchOutcome>? blocker;

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
  }) async => await blocker?.future ?? outcome;
}
