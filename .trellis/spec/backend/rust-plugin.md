---
prefix: RHTTP
applies_to:
  - plugins/rhttp/**
  - tool/frb_check.sh
reviewed: 2026-10-14
---

# The rhttp fork

### RHTTP-01 The fork adds ECH and nothing else
- **Rule:** The only functional fork change is ECH in the Rust TLS layer
  (`TlsSettings.ech_config_list`). DNS, ECH discovery, endpoint selection,
  TTLs and cancellation stay in the Dart policy. Every fork-only build
  difference is recorded in `plugins/rhttp/UPSTREAM.md`.
- **Why:** Policy split across Dart and Rust drifted; the GPL-3 PixEz fork's
  lookup and switches must not be copied in.
- **Check:** manual
- **Code:** `plugins/rhttp/rhttp/rust`, `plugins/rhttp/UPSTREAM.md`

### RHTTP-02 The FRB version moves as one triplet
- **Rule:** The plugin `pubspec.yaml`, `rust/Cargo.toml` and generated
  `codegenVersion` pin the same `flutter_rust_bridge`; `tool/frb_check.sh`
  checks them. Regenerate bindings with the matching codegen; never edit
  generated code or relax the pins. The plugin entry point keeps
  `forceSameCodegenVersion: false`.
- **Why:** A mismatched triplet fails at runtime on init.
- **Check:** `tool/frb_check.sh`
- **Code:** `plugins/rhttp/rhttp/lib/src/rhttp.dart`, `plugins/rhttp/rhttp/pubspec.yaml`

### RHTTP-03 Cargokit cleans its ABI output
- **Rule:** The Gradle `CargoKitBuildTask` deletes the selected
  `jniLibs/<buildType>` directory before each build; keep this cleanup when
  updating Cargokit.
- **Why:** A single-ABI build packaged a stale ABI left by an earlier
  multi-ABI build.
- **Check:** manual
- **Code:** `plugins/rhttp/rhttp/cargokit`

### RHTTP-04 The plugin keeps its own Android versions
- **Rule:** The plugin keeps its own AGP, Kotlin, `compileSdk` and
  `minSdk`, independent of the app, and does not apply
  `org.jetbrains.kotlin.android` under the app's AGP 9.
- **Why:** Applying the Kotlin plugin under AGP 9's built-in Kotlin broke
  the build.
- **Check:** manual
- **Code:** `plugins/rhttp/rhttp/android/build.gradle.kts`

### RHTTP-05 reqwest `query` stays enabled
- **Rule:** The reqwest feature set is narrow, but `query` stays: the Dart
  adapter strips the query from the URL and passes it separately on every
  request. A feature change is validated by reading `io_request.dart`, a
  release cargo build, a real split build and a device pass; the Dart
  tests mock above the Rust boundary. After editing `Cargo.toml`, run
  `cargo update -w` and `cargo test --locked`.
- **Why:** Dropping `query` made every request fail while all Dart tests
  passed.
- **Check:** manual
- **Code:** `plugins/rhttp/rhttp/rust/Cargo.toml`, `plugins/rhttp/rhttp/lib/src/client/io/io_request.dart`

### RHTTP-06 Release opt-level changes need a device gate
- **Rule:** The release profile stays at `opt-level = 3`. `"s"` is adopted
  only after the user's device shows no wall-clock regression for listing
  and a large download.
- **Why:** `"s"` saves about 1.5 MB on arm64, which does not justify an
  unmeasured slowdown of every transfer.
- **Check:** manual
- **Code:** `plugins/rhttp/rhttp/rust/Cargo.toml`

### RHTTP-07 Android verifies with webpki roots only
- **Rule:** Every client verifies against the bundled webpki roots;
  `RootCertSource.platform` is not used. The Android build ships no
  rustls-platform-verifier AAR, and `create_client` rejects `platform` on
  Android. The crate itself stays: reqwest's `rustls` feature depends on
  it, and its init only stores the JVM context.
- **Why:** The release build never contained the verifier's Java classes
  (R8 dropped them), so the AAR only cost a build dependency. From 0.7.1 it
  moved to a Maven repository on GitHub and its manifest would have set an
  app-wide network security config for CRL downloads.
- **Check:** manual
- **Code:** `plugins/rhttp/rhttp/android/build.gradle.kts`, `plugins/rhttp/rhttp/rust/src/api/client.rs`
