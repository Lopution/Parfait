---
prefix: REL
applies_to:
  - android/app/build.gradle.kts
  - android/settings.gradle.kts
  - .github/workflows/**
  - tool/apk_size_report.py
  - tool/update_release.py
  - tool/RELEASE.md
  - lib/core/updater/**
  - lib/core/download/download_request.dart
  - android/app/src/github/**
  - android/app/src/fdroid/**
  - pubspec.yaml
  - pubspec.lock
  - rust-toolchain.toml
reviewed: 2026-10-12
---

# Release artifacts, updater and toolchain

## Contents

- [Artifacts and signing](#artifacts-and-signing)
- [Updater](#updater)
- [CI](#ci)
- [Toolchain](#toolchain)

## Artifacts and signing

### REL-01 Releases are per-ABI splits
- **Rule:** Release builds are per-ABI splits for `arm64-v8a` and
  `armeabi-v7a` only, obfuscated with symbols kept as Actions artifacts.
  No universal or x86_64 APK. Split `versionCode`s keep Flutter's offsets
  (`1000 + n`, `2000 + n`); never pass
  `-Pforce-version-code-ignoring-abi`. `libsqlite3.so` stays excluded on
  Android.
- **Why:** A universal APK doubled the download; ignoring offsets broke
  updates between splits.
- **Check:** `tool/apk_size_report.py`
- **Code:** `android/app/build.gradle.kts`, `.github/workflows/release.yml`

### REL-02 Release signing never falls back silently
- **Rule:** The `github` flavor signs release builds only with the four
  `PIXIV_RELEASE_*` Gradle properties; without them
  `verifyGithubReleaseSigning` fails and names them. A local debug-signed
  release needs `-PPIXIV_ALLOW_DEBUG_RELEASE_SIGNING=true` and prints a
  warning. `fdroid` release builds are unsigned. A new signing path keeps
  this shape.
- **Why:** A debug-signed release would not update over installed copies.
- **Check:** manual
- **Code:** `android/app/build.gradle.kts`

### REL-03 Size gate thresholds live in the workflows
- **Rule:** `tool/apk_size_report.py` fails on an APK carrying another ABI
  or exceeding its threshold; arm64 also has a hard cap of 32,000,000
  bytes. Thresholds are the `PIXIV_APK_MAX_BYTES_*` defaults, identical in
  `ci.yml` and `release.yml`. Release-signed size checks need the secrets
  and must not be bypassed; the fdroid `android-size` job is for forks.
- **Why:** Diverging caps let a release fail after CI passed.
- **Check:** `tool/apk_size_report.py`
- **Code:** `tool/apk_size_report.py`, `.github/workflows/ci.yml`

### REL-04 Measurement packages build from a detached worktree
- **Rule:** A profiling build passes `--dart-define=PIXIV_FRAME_PROBE=true`
  on the signed arm64 github release command; published releases never do.
  The "before" side of a comparison builds from
  `git worktree add --detach <dir> main`.
- **Why:** A plain `main` checkout made the cherry-pick land on local
  `main`.
- **Check:** `test/frame_probe_test.dart` "PIXIV_FRAME_PROBE stays unset in a default build"
- **Code:** `lib/core/debug/frame_probe.dart`

## Updater

### REL-05 The manifest is signed with its own P-256 key
- **Rule:** The update manifest is schema 2 with exact top-level keys and
  an `assets[]` list (one entry per ABI). It is signed with a separate EC
  P-256 key (`tool/update_release.py genkey`), never the APK keystore; the
  Kotlin verifier checks `SHA256withECDSA` over the raw bytes before parsing
  and reports exactly `public_key_missing`, `algorithm_unavailable`,
  `signature_mismatch`, `message_missing` or `signature_missing`. Keys stay
  outside the tree.
- **Why:** A manifest trusted before verification could point at any APK.
- **Check:** `test/updater_manifest_test.dart` "valid signature is required before a release is available" "rejects schema 1 with schema", `test/updater_flavor_contract_test.dart`
- **Code:** `lib/core/updater`, `tool/update_release.py`

### REL-06 ABI and version selection never claim "up to date" wrongly
- **Rule:** The first supported ABI present in `assets[]` wins; none is
  `invalid` with `abi_unsupported`. Versions compare by semver, then by
  `versionCode` against the installed code modulo 1000.
- **Why:** An unsupported device was told it was up to date.
- **Check:** `test/updater_manifest_test.dart` "unsupported ABI is invalid, never up_to_date" "installed 2001 is up to date against manifest base 1"
- **Code:** `lib/core/updater`

### REL-07 Updates install only after confirmation and full verification
- **Rule:** `apply` requires explicit confirmation, streams to
  app-private `files/updates/`, and checks size, SHA-256, package and
  signer before a `content://` install intent. The F-Droid flavor never
  fetches a manifest. Download redirects follow only `kUpdateDownloadHosts`
  and the measured CDN hosts; a new host needs a transport test.
- **Why:** Installing without checks or from shared storage would allow a
  swapped APK.
- **Check:** `test/updater_download_test.dart` "apply requires explicit confirmation and never silently installs" "hash or exact-size mismatch fails closed and cleans the APK", `test/updater_manifest_test.dart` "F-Droid capability never fetches a manifest or signature"
- **Code:** `lib/core/updater`, `lib/core/download/download_request.dart`

## CI

### REL-08 The Rust cache names cargokit's target directory
- **Rule:** cargokit builds into `build/rhttp/build` (Android) and
  `build/windows/x64/plugins/rhttp/cargokit_build` (Windows), not
  `rust/target`; the `Swatinem/rust-cache` `workspaces` entry must name
  that directory. `ci.yml` and `release.yml` share `shared-key: android`.
- **Why:** Naming `rust/target` gave cache hits that rebuilt rhttp from
  scratch.
- **Check:** manual
- **Code:** `.github/workflows/ci.yml`, `.github/workflows/windows.yml`

### REL-09 Windows builds run on dispatch before a release
- **Rule:** `windows.yml` runs on PRs touching Windows, plugins, pubspec,
  the Rust toolchain or workflows, nightly on `main`, and on dispatch.
  Pushes to `main` do not run it; dispatch it on the release ref before
  publishing.
- **Why:** A release shipped without a Windows build check.
- **Check:** manual
- **Code:** `.github/workflows/windows.yml`

## Toolchain

### REL-10 Stay inside Flutter's validated Android matrix
- **Rule:** AGP, Gradle and Kotlin stay inside the range the pinned Flutter
  validates. `compileSdk` may lead Flutter's default when a dependency
  requires it; `minSdk` and `targetSdk` change only in their own task.
- **Why:** Versions outside the matrix broke plugin builds; a target SDK
  bump changes runtime behaviour.
- **Check:** manual
- **Code:** `android/settings.gradle.kts`, `android/app/build.gradle.kts`

### REL-11 Lockfiles are the contract
- **Rule:** `pubspec.lock` (app and plugin) and `Cargo.lock` are committed;
  CI uses `--enforce-lockfile` and `--locked`. Refresh them with
  `flutter pub upgrade` or `cargo update` in a dedicated commit; resolve
  conflicts by regenerating, never by hand. Coupled upgrades (`archive`
  with `image`; `flutter_secure_storage` with `compileSdk`, AGP and
  `androidx.core`) move together after reading their changelogs.
- **Why:** Hand-merged locks and half-done coupled upgrades broke builds
  and storage formats.
- **Check:** manual
- **Code:** `pubspec.lock`, `plugins/rhttp/rhttp/rust/Cargo.lock`

### REL-12 One Rust pin, at the app root
- **Rule:** `rust-toolchain.toml` lives at the repository root; bumping
  Rust means editing its channel, then `cargo test --locked` and an APK
  build.
- **Why:** cargokit reads only `<app root>/rust-toolchain.toml` and
  otherwise falls back to `stable`.
- **Check:** manual
- **Code:** `rust-toolchain.toml`
