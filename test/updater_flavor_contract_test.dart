import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// This file checks the Android flavor/source-set build surface. Runtime
/// channel payload parsing and platform helper behavior belong to the Dart
/// updater tests and the Android JVM tests.
void main() {
  final root = Directory.current.path;

  String read(String relativePath) =>
      File('$root/$relativePath').readAsStringSync();

  test('Android declares compile-time github and fdroid updater flavors', () {
    final gradle = read('android/app/build.gradle.kts');

    expect(gradle, contains('flavorDimensions += "distribution"'));
    expect(gradle, contains('create("github")'));
    expect(gradle, contains('create("fdroid")'));
    expect(gradle, contains('UPDATE_SELF_UPDATER_ENABLED'));
    expect(gradle, contains('UPDATE_PUBLIC_KEY_DER_B64'));
  });

  test('only the github manifest requests package installation', () {
    final baseManifest = read('android/app/src/main/AndroidManifest.xml');
    final githubManifest = read('android/app/src/github/AndroidManifest.xml');
    final fdroidManifest = read('android/app/src/fdroid/AndroidManifest.xml');

    expect(baseManifest, isNot(contains('REQUEST_INSTALL_PACKAGES')));
    expect(githubManifest, contains('REQUEST_INSTALL_PACKAGES'));
    expect(fdroidManifest, isNot(contains('REQUEST_INSTALL_PACKAGES')));
  });

  test('each flavor owns the same updater channel with different capability', () {
    final github = read(
      'android/app/src/github/kotlin/io/github/lopution/pixivfunc/DistributionUpdaterChannel.kt',
    );
    final fdroid = read(
      'android/app/src/fdroid/kotlin/io/github/lopution/pixivfunc/DistributionUpdaterChannel.kt',
    );

    expect(github, contains('object DistributionUpdaterChannel'));
    expect(github, contains('UPDATE_SELF_UPDATER_ENABLED'));
    expect(github, contains('pixivfunc/updater'));
    expect(github, contains('UpdaterPlatformInfo.platformInfo'));
    // API 29-safe verifier: SHA256withECDSA over the raw manifest bytes, and
    // every failure is one of the five diagnosable codes the Dart side maps.
    expect(github, contains('"SHA256withECDSA"'));
    for (final code in const [
      'public_key_missing',
      'algorithm_unavailable',
      'signature_mismatch',
      'message_missing',
      'signature_missing',
    ]) {
      expect(github, contains('"$code"'), reason: code);
    }
    expect(fdroid, contains('object DistributionUpdaterChannel'));
    expect(fdroid, contains('storeManaged'));
    expect(fdroid, contains('UpdaterPlatformInfo.platformInfo'));
    expect(fdroid, isNot(contains('HttpURLConnection')));
    expect(fdroid, isNot(contains('github.com')));

    final shared = read(
      'android/app/src/main/kotlin/io/github/lopution/pixivfunc/updater/UpdaterPlatformInfo.kt',
    );
    expect(
      shared,
      contains('"supportedAbis" to Build.SUPPORTED_ABIS.toList()'),
    );
  });

  test('the installer is limited to the app-private updates path', () {
    final paths = read('android/app/src/main/res/xml/file_provider_paths.xml');
    final activity = read(
      'android/app/src/main/kotlin/io/github/lopution/pixivfunc/MainActivity.kt',
    );

    expect(paths, contains('name="updates"'));
    expect(activity, contains('DistributionUpdaterChannel.configure'));
  });
}
