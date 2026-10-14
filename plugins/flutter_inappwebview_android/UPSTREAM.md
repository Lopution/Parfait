# Upstream

- Package: `flutter_inappwebview_android` (Android implementation of `flutter_inappwebview`)
- Upstream: https://github.com/pichillilorenzo/flutter_inappwebview, directory `flutter_inappwebview_android/`
- Upstream tag: `v6.1.5` (`f67ae1f34868c7660c16a2473f53a7a7bfb6f784`), which ships this package as 1.1.3
- Version: 1.1.3 (per `pubspec.yaml`, the same as the pub.dev release)
- License: Apache-2.0 (see LICENSE)
- Used through `dependency_overrides` in the app's `pubspec.yaml`

## Differences from upstream

Verified by diffing this directory against the pub.dev archive of 1.1.3.
Package names, Java packages and channel names are unchanged.

1. **AGP 9 build fix** (`android/build.gradle`). Both build types use
   `getDefaultProguardFile('proguard-android-optimize.txt')` instead of
   `'proguard-android.txt'`. AGP 9 dropped the non-optimizing file, and the
   upstream name fails the build.
2. **One-shot file chooser slot for reverse image search**
   (`android/src/main/java/com/pichillilorenzo/flutter_inappwebview_android/webview/in_app_webview/InAppWebViewChromeClient.java`):
   - The patch adds a static `armedFileChooserUris` field.
   - When the field is set, the next `onShowFileChooser` hands those URIs to the page and clears the field, instead of opening the system picker.
   - The chooser still opens only from the user's own tap on the site's upload button. So the site, including any Cloudflare challenge, runs its own upload in a real browser context. The patch only pre-fills the file.
   - The app arms the slot from `ReverseImageInputChannel`.
3. **Not vendored**: the upstream `example/` and `test/` directories, and the empty `android/src/main/assets/` directory.

## Removing the fork

- Difference 1 is fixed upstream in the 6.2.0 beta line (`flutter_inappwebview_android` 1.2). Once that line is stable, a stock release no longer needs the vendored build file.
- Difference 2 has no upstream equivalent. Reverse image search keeps the fork until upstream offers a way to answer a file chooser programmatically, or until the upload channel moves elsewhere.
- Until both conditions hold, keep the fork and move it to the new upstream release. Remove the override only when the fork carries no differences at all.

## Syncing with upstream

Replace the directory with the new upstream release, then re-apply every difference listed above. Update this file in the same commit: tag, version and the list of differences.
