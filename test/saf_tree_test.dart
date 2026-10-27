import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parfait/core/platform/saf_tree.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('parfait/saf_tree');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Future<PickedDocument?> pick() => const MethodChannelSafTree().pickDocument(
    label: 'TXT',
    extensions: const ['txt'],
    mimeTypes: const ['text/plain'],
    maxBytes: 4,
  );

  test('pickDocument reads the host copy and deletes it', () async {
    final dir = await Directory.systemTemp.createTemp('saf-pick');
    addTearDown(() => dir.delete(recursive: true));
    final copy = File('${dir.path}/input')..writeAsBytesSync([1, 2, 3]);
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'pickDocument'
          ? 'content://d/1'
          : {'path': copy.path, 'name': 'a.txt', 'sizeBytes': 3};
    });

    final picked = await pick();

    expect(picked!.name, 'a.txt');
    expect(picked.bytes, [1, 2, 3]);
    expect(copy.existsSync(), isFalse);
    expect(calls.last.arguments, {'uri': 'content://d/1', 'maxBytes': 4});
  });

  test('pickDocument maps the host limit to DocumentTooLargeException', () {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'pickDocument') return 'content://d/1';
      throw PlatformException(code: 'saf_too_large');
    });

    expect(pick(), throwsA(isA<DocumentTooLargeException>()));
  });
}
