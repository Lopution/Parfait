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
  - CHANGELOG.md
  - .github/pull_request_template.md
reviewed: 2026-10-13
---

# Release artifacts, updater and toolchain

## Contents

- [Artifacts and signing](#artifacts-and-signing)
- [Updater](#updater)
- [CI](#ci)
- [Toolchain](#toolchain)
- [Process](#process)

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
  the Rust toolchain or `windows.yml` itself, nightly on `main`, and on
  dispatch. Pushes to `main` do not run it; dispatch it on the release ref
  before publishing. A path joins its trigger only if the Windows build
  reads it.
- **Why:** A release shipped without a Windows build check; listing
  `ci.yml` made every CI tweak wait 11 minutes for a build that does not
  read it.
- **Check:** manual
- **Code:** `.github/workflows/windows.yml`

### REL-13 Dart-only PRs skip the APK build; main is the size backstop
- **Rule:** User decision: on PRs, `android-release`, `android-size` and
  `android-unit` run only when the `android` path filter matches (Android,
  plugins, assets, pubspec, toolchain, workflows, the size script). Every
  build-affecting push to `main` still builds, signs and size-checks the
  APK. When that check fails on `main`, the next PR fixes it before
  anything else merges. A script that a build job calls joins the filter.
- **Why:** The release build set the PR wall clock at 7–9 minutes while
  Dart changes almost never move the APK past its cap.
- **Check:** manual
- **Code:** `.github/workflows/ci.yml`

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

### REL-17 Dependency upgrades start from a risk table
- **Rule:** Once a month, look at `flutter pub outdated` (app and plugin),
  `cargo update --dry-run`, Flutter's stable hotfix notes, the latest
  `deps-report` artifact and the open Dependabot alerts. An upgrade first
  fills one row per dependency: from and to, what the changelogs say
  (breaking, behaviour, security), where the app calls it, risk, and the
  tests and device checks that verify it. Read changelogs and source, not
  version numbers. One PR, one commit per layer (SDK and Dart packages,
  Rust and FRB, each major package) so each reverts alone. A package that
  cannot move goes to the user with options; a held version says why at
  its pin. An alert on code the app runs exposed (network, TLS, parsing)
  gets its own PR when it appears; otherwise the next upgrade closes it.
  Dependabot does not see Gradle: check AndroidX by hand. Workflows pin
  each action to a release's commit SHA with the version in a comment
  (`uses: owner/action@<sha> # vX.Y.Z`); the monthly check moves them.
- **Why:** Upgrades were judged by version numbers. A compatible
  rustls-platform-verifier release would have broken the Android build,
  and easy_refresh 4 changed the profile's fling.
- **Check:** manual
- **Code:** `pubspec.yaml`, `plugins/rhttp/rhttp/rust/Cargo.toml`, `.github/workflows/ci.yml`

## Process

### REL-14 Releases follow the checklist in `tool/RELEASE.md`
- **Rule:** User decision: a release ships when its features are
  complete, not on a schedule. Version and `CHANGELOG.md` move in one PR;
  that CHANGELOG section becomes the draft's notes before `release.yml`
  runs, and the workflow pins the draft to the commit it built. The user
  accepts the APK on a device before it is published; a large or risky
  version is a pre-release first, which the in-app updater skips.
- **Why:** v0.9.0's notes were first generated from developer-facing PR
  titles, and a draft without a target tags whatever `main` holds when it
  is published.
- **Check:** manual
- **Code:** `tool/RELEASE.md`, `.github/workflows/release.yml`

### REL-15 Unfinished features stay hidden on `main`
- **Rule:** A feature that lands over several PRs keeps its entry point
  (route, tab, menu item, setting) hidden until the last one merges, so
  every commit on `main` can be released. Hide the entry, not the code;
  the PR that reveals it adds the CHANGELOG entry.
- **Why:** Ranking categories and the bottom bar land in stages while a
  hotfix may have to ship from `main` at any time.
- **Check:** manual
- **Code:** `lib/app`

### REL-16 PRs follow the template; high-risk ones may get a second review
- **Rule:** PR titles use Conventional Commits, like the commits. The
  template's "User-facing change" (Chinese and English, or "none") feeds
  `CHANGELOG.md`. User decision: an independent `codex review --base main`
  is suggested for high-risk PRs (network and TLS, credentials and
  accounts, persistence and migrations, downloads, release and signing,
  CI workflows) and never required. Each finding is fixed or answered in
  the PR's "Independent review" section.
- **Why:** One agent wrote, checked and merged every change; the first
  review caught a cross-account replay the tests had missed.
- **Check:** manual
- **Code:** `.github/pull_request_template.md`
