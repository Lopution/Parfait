import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

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
    expect(fdroid, contains('object DistributionUpdaterChannel'));
    expect(fdroid, contains('storeManaged'));
    expect(fdroid, isNot(contains('HttpURLConnection')));
    expect(fdroid, isNot(contains('github.com')));
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
