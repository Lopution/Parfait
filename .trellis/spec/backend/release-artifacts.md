# Android Release Artifacts and Size Budget

> Executable contracts for the per-ABI release split. The current defaults are
> exact bytes measured on 2026-09-10.

---

## Artifacts

- Release builds are **per-ABI splits only**:
  `flutter build apk --release --flavor <github|fdroid> --split-per-abi
  --target-platform android-arm64,android-arm --obfuscate --split-debug-info=build/symbols/<flavor>`.
- Flutter 3.47.2 names them `app-<abi>-<flavor>-release.apk` with `<abi>` in
  `arm64-v8a`, `armeabi-v7a`. No universal APK and no x86_64 are published
  (emulators use debug builds).
- Public release asset names: `parfait-v<version>-github-<abi>.apk`, plus
  `update-manifest.json` and `update-manifest.sig`. Symbols (`build/symbols/<flavor>`)
  are Actions artifacts only, never release assets.
- `libsqlite3.so` is excluded on Android (`android/app/build.gradle.kts`
  `packaging.jniLibs.excludes`); the desktop branch keeps `sqflite_common_ffi`.
  Each split contains exactly one `lib/<abi>/` directory.
- Split `versionCode`s carry Flutter's ABI offsets: `armeabi-v7a = 1000 + n`,
  `arm64-v8a = 2000 + n`. Never pass `-Pforce-version-code-ignoring-abi`.
- **Measurement packages.** `--dart-define=PIXIV_FRAME_PROBE=true` on the
  arm64 github release command shows the frame probe's settings entry in a
  signed release build (`kPixivFrameProbe`), so it installs over the user's
  copy without losing the login. Published releases never pass it. For a
  before/after pair, build the "before" side from a **detached** worktree
  (`git worktree add --detach <dir> main`) — a plain `main` checkout makes
  the cherry-pick land on the local `main` branch.

## Signing

- The `github` flavor signs release builds only with material injected as Gradle
  properties (`PIXIV_RELEASE_KEYSTORE`, `..._KEYSTORE_PASSWORD`, `..._KEY_ALIAS`,
  `..._KEY_PASSWORD`). Without them `:app:verifyGithubReleaseSigning` fails and
  names the four properties; it never falls back to debug keys silently. A local
  non-publishable build needs the explicit `-PPIXIV_ALLOW_DEBUG_RELEASE_SIGNING=true`
  and Gradle prints `!!! RELEASE SIGNING: DEBUG KEYS`. Keep that shape for any new
  signing path. `fdroid` release builds are unsigned (store-managed).
- Manifest signing is a separate EC P-256 key (`tool/update_release.py genkey`),
  never the APK keystore; the Kotlin verifier uses `SHA256withECDSA` over the raw
  manifest bytes and reports exactly `public_key_missing` / `algorithm_unavailable`
  / `signature_mismatch` / `message_missing` / `signature_missing`
  (`test/updater_flavor_contract_test.dart` pins both). Keys live outside the tree
  (`tool/RELEASE.md`, `~/.pixivfunc-release`); the root `.gitignore` ignores
  `*.jks / *.keystore / *.p12 / *.pem` and `release.yml` scans its outputs for
  private-key markers before publishing.
- Update downloads follow the measured redirect chain `github.com` 302 →
  `release-assets.githubusercontent.com` 200 (one hop, CDN path without `.apk`). Only the
  manifest URL and a `github.com` hop must end in `.apk`; CDN hops are exact-host
  HTTPS only (`lib/core/download/download_request.dart`). Adding a host means adding
  it to `kUpdateDownloadHosts` (and `kUpdateCdnHosts`) with a transport test.

## Size gate

- `tool/apk_size_report.py <apk>...` prints file bytes and `zipfile` `compress_size`
  buckets and exits 1 on: an APK whose `lib/` has anything but its own ABI, or file
  bytes above the threshold. `--self-test` exercises pass/fail paths.
- Thresholds: env `PIXIV_APK_MAX_BYTES_ARM64_V8A` / `PIXIV_APK_MAX_BYTES_ARMEABI_V7A`,
  set in the workflows as `${{ vars.<name> || '<default>' }}`. Defaults are measured
  fdroid split bytes + 1,000,000: **28,981,038 / 24,805,284** (measured
  **27,981,038 / 23,805,284** after child F). arm64 additionally has a hard cap of
  **32,000,000**; the stricter value wins.
- `ci.yml` `android-release` runs the script on the github flavor with the real
  keystore for pushes to `main` and same-repo PRs, as does `release.yml`; they
  fail without the secrets — do not bypass that. `android-size` is the
  secrets-free gate (fdroid flavor) and runs only for PRs from forks, which cannot
  read secrets. `--analyze-size` archives run only on `main` pushes.

## CI caches

- Flutter SDK: `subosito/flutter-action` with `cache: true`. Gradle: `actions/setup-java`
  with `cache: gradle` (not `gradle/actions`, whose cache is a closed component).
- **cargokit does not build into `rust/target`.** It passes `cargo --target-dir`:
  Android uses `<repo>/build/rhttp/build` (the rhttp Gradle project's `buildDir` +
  `/build`), Windows `<repo>/build/windows/x64/plugins/rhttp/cargokit_build`. The
  `Swatinem/rust-cache` `workspaces` entry must name that directory
  (`plugins/rhttp/rhttp/rust -> ../../../../build/...`), otherwise the cache hits but
  rhttp is rebuilt from scratch. `ci.yml` and `release.yml` share `shared-key: android`.
  Only the `plugin` job (`cargo test`) uses the default `rust/target`.
- A PR reads caches from `main` only; caches are written on `main` pushes, so a
  cache change shows its full effect after it merges.

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
