# Android Release Artifacts and Size Budget

> Executable contracts introduced by task `09-07-release-size-per-abi` (child B of
> `09-02-performance-size-maintainability-refactor`). Numbers are exact bytes measured
> on 2026-09-07; the research record is
> `.trellis/tasks/09-02-performance-size-maintainability-refactor/research/apk-size-breakdown.md` §6.

---

## Artifacts

- Release builds are **per-ABI splits only**:
  `flutter build apk --release --flavor <github|fdroid> --split-per-abi
  --target-platform android-arm64,android-arm --obfuscate --split-debug-info=build/symbols/<flavor>`.
- Flutter 3.47.2 names them `app-<abi>-<flavor>-release.apk` with `<abi>` in
  `arm64-v8a`, `armeabi-v7a`. No universal APK and no x86_64 are published
  (emulators use debug builds).
- Public release asset names: `pixiv-func-v<version>-github-<abi>.apk`, plus
  `update-manifest.json` and `update-manifest.sig`. Symbols (`build/symbols/<flavor>`)
  are Actions artifacts only, never release assets.
- `libsqlite3.so` is excluded on Android (`android/app/build.gradle.kts`
  `packaging.jniLibs.excludes`); the desktop branch keeps `sqflite_common_ffi`.
  Each split contains exactly one `lib/<abi>/` directory.
- Split `versionCode`s carry Flutter's ABI offsets: `armeabi-v7a = 1000 + n`,
  `arm64-v8a = 2000 + n`. Never pass `-Pforce-version-code-ignoring-abi`.

## Size gate

- `tool/apk_size_report.py <apk>...` prints file bytes and `zipfile` `compress_size`
  buckets and exits 1 on: an APK whose `lib/` has anything but its own ABI, or file
  bytes above the threshold. `--self-test` exercises pass/fail paths.
- Thresholds: env `PIXIV_APK_MAX_BYTES_ARM64_V8A` / `PIXIV_APK_MAX_BYTES_ARMEABI_V7A`,
  set in the workflows as `${{ vars.<name> || '<default>' }}`. Defaults are measured
  fdroid split bytes + 1,000,000: **28,435,321 / 24,226,795** (measured
  27,435,321 / 23,226,795). arm64 additionally has a hard cap of **32,000,000**; the
  stricter value wins. Re-measure and reset the defaults after child F migrates to
  `material_ui`.
- `ci.yml` `android-size` is the secrets-free gate (fdroid flavor, every PR).
  `android-release` and `release.yml` run the same script on the github flavor and
  stay red until the keystore secrets exist — do not bypass that.

## Updater manifest (schema 2)

- Top-level keys, exact: `schema` (must be `2`), `repository`, `tag`, `channel`,
  `version`, `versionCode` (base `n`), `packageName`, `signingCertificateSha256`,
  `assets`. Schema 1 is rejected; nothing was ever published with it.
- `assets[]` keys, exact: `abi` (unique, in `{arm64-v8a, armeabi-v7a}`), `url`
  (strict https GitHub release URL), `size` (≤ `updateAssetMaxBytes`), `sha256`
  (lower-case hex, 64), `versionCode` (`1000 + n` / `2000 + n`).
- Selection: Kotlin reports `supportedAbis = Build.SUPPORTED_ABIS` (both flavors);
  the first supported ABI present in `assets[]` wins; no match is `invalid` +
  `abi_unsupported`, never "up to date".
- Version compare: semver first; only when equal,
  `manifest.versionCode <= installed.versionCode % 1000` means up to date.
- Generator: `python3 tool/update_release.py generate --apk arm64-v8a=<path>
  --apk armeabi-v7a=<path> --version <semver> --version-code <n> ...` (see
  `tool/RELEASE.md`). The signature covers the raw manifest bytes.

## rhttp fork: changing Cargo features

- All app traffic goes through `RhttpCompatibleClient`
  (`lib/core/network/compat/rhttp_client_factory.dart`). Its adapter
  `plugins/rhttp/rhttp/lib/src/client/io/io_request.dart` rebuilds the URL without
  its query string and passes `query: uri.queryParameters` and `HttpBody.stream` on
  **every** request. Therefore reqwest `query` **must stay enabled** (dropping it was
  tried as B5e and reverted: every request failed with
  "query parameters are not supported"). `form`, `multipart`, `cookies`, `socks`,
  `charset` are dropped and `tokio` is narrowed; those Rust branches return
  `RhttpError::RhttpUnknownError` for the now-unsupported inputs.
- The app's Dart tests are mocked **above** the Rust boundary
  (`test/rhttp_client_factory_test.dart`, `test/restricted_compat_network_test.dart`
  passed with the broken B5e). A feature change is only validated by: reading
  `io_request.dart` for what the adapter actually sends, `cargo build --release
  --locked`, a real fdroid split build, and a device login/list/download pass.
- After editing `plugins/rhttp/rhttp/rust/Cargo.toml`, sync the lockfile with
  `cargo update -w` (never hand-edit) and keep `cargo test --locked` green. Record
  every fork-only build difference in `plugins/rhttp/UPSTREAM.md`.
- `[profile.release] opt-level = "s"` was measured (`librhttp.so` −1,539,000 arm64 /
  −884,944 armeabi-v7a) but is **not adopted** until the user's device wall-clock
  (list + large download) shows no regression. Adoption is the single commit
  `size(rhttp): set release opt-level to s` plus an `UPSTREAM.md` line.
