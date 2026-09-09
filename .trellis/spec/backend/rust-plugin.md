# rhttp Rust Plugin Guidelines

This guide records the repository-specific rules for the vendored `rhttp`
Flutter plugin and its Rust/Flutter Rust Bridge (FRB) boundary.

## Fork ownership and scope

The plugin is based on upstream `rhttp` 0.18.0 at commit
`9871f1c25d0cf75553af85698b9f03d38f438aed` from
`https://codeberg.org/Tienisto/rhttp`. The only functional fork change is
ECH support in the Rust TLS layer:

- `TlsSettings.ech_config_list` carries ECH config bytes from Dart.
- `rustls` builds the ECH client configuration and reqwest uses the
  preconfigured TLS backend.

DNS resolution, ECH discovery, endpoint selection, TTL handling, and
cancellation remain in the Dart policy layer. Do not copy the AliDNS HTTPS-RR
lookup, ECH cache, or `enable_ech` / `require_ech` switches from the GPL-3
PixEz fork. HTTP/3/QUIC is compiled upstream but unused by this application.

The build and dependency differences are recorded in
`plugins/rhttp/UPSTREAM.md`; every new fork-only difference must be added
there during an upstream sync. `login_webview_intercept` has no remaining
entry on either side and must stay absent.

## FRB version contract

All FRB version sources are pinned to `2.12.0`:

- the root and plugin `pubspec.lock` files;
- `plugins/rhttp/rhttp/pubspec.yaml`;
- `plugins/rhttp/rhttp/rust/Cargo.toml` and `Cargo.lock`;
- generated Dart headers and `RustLib.codegenVersion`.

Run `tool/frb_check.sh` from the repository root after dependency or generated
binding changes. It checks these sources and, when installed, the
`flutter_rust_bridge_codegen` binary version. Do not hand-edit generated Dart
or Rust bindings. `rust/src/lib.rs` keeps `#[rustfmt::skip]` on
`mod frb_generated;` because generated Rust is not stable under the pinned
formatting toolchain.

When Rust API signatures change, regenerate from the plugin directory:

```shell
cd plugins/rhttp/rhttp
dart run flutter_rust_bridge_codegen generate
```

The public plugin entry point in `lib/src/rhttp.dart` must retain
`forceSameCodegenVersion: false`. The generated `RustLib.init` default is a
separate generated API default; the plugin entry point deliberately overrides
it for consumers that use FRB elsewhere.

## Cargokit and ABI outputs

The copied Cargokit integration writes native libraries below
`build/jniLibs/<buildType>/`, with one ABI subdirectory per requested target.
`build_gradle.dart` creates those directories and copies the current
`librhttp.so` files, but does not remove stale ABI directories. The Gradle
`CargoKitBuildTask` therefore deletes the selected `jniLibs/<buildType>` output
directory before each build. Keep this cleanup when updating Cargokit; a
single-ABI build must not package an ABI left by a previous multi-ABI build.

The task adds `android-x86` and `android-x64` for debug builds. The release
targets are controlled by Flutter's requested ABI set. The Cargokit compile SDK
parser extracts the numeric major from values such as `android-37.0`, which is
required by the app's AGP 9 build.

## Android version boundaries

The plugin and consuming app intentionally use different Android build
versions:

| Boundary | Plugin `rhttp` | App | Reason |
|---|---:|---:|---|
| Android Gradle Plugin | 8.11.2 | 9.1.1 | The plugin keeps its library buildscript; the app uses the repository AGP. |
| Kotlin | 2.2.20 | 2.4.0 | The plugin's Kotlin toolchain is independent of the app plugin version. |
| `compileSdk` | 36 | 37 | The app requires the newer AndroidX dependencies. |
| `minSdk` | 24 | 29 | The app's download path relies on API 29 MediaStore behavior. |

In the plugin Android build file, do not apply
`org.jetbrains.kotlin.android` under the app's AGP 9 setup. AGP's built-in
Kotlin support compiles the plugin sources, and the `kotlin` extension sets
JVM 17. Preserve the existing plugin `compileOptions`/Kotlin JVM target.

## Cargo features and build profile

The reqwest feature set is deliberately narrow. `query` must remain enabled:
the Dart compatibility client removes the URL query from the URL and passes it
through `RequestBuilder::query`. The fork does not enable unused multipart,
form, socks, cookies, or charset support; the corresponding unsupported paths
remain explicit Rust errors. Tokio uses the features listed in
`rust/Cargo.toml`, not `full`.

The release profile currently uses `opt-level = 3`. `opt-level = "s"` was
measured but not adopted: it reduced `librhttp.so` by 1,539,000 bytes on arm64
and 884,944 bytes on armeabi-v7a. Do not change the profile based on size alone;
the adoption gate requires device wall-clock checks for listing and a large
download, as recorded in `release-artifacts.md`.

After editing `Cargo.toml`, update the lockfile with `cargo update -w` and
verify with `cargo test --locked`. Never hand-edit `Cargo.lock`.

## Verification commands

Run the following from the repository root or the indicated directory:

```shell
./tool/frb_check.sh
(cd plugins/rhttp/rhttp && flutter test)
(cd plugins/rhttp/rhttp/rust && cargo fmt --check)
(cd plugins/rhttp/rhttp/rust && cargo test --locked)
```

The raw ECH handshake test is ignored and network-dependent; run it explicitly
only when its recorded network environment is available:

```shell
(cd plugins/rhttp/rhttp/rust && cargo test --test ech_live_handshake -- --ignored --nocapture)
```

## Forbidden patterns and common mistakes

- Do not add runtime networking, DNS, ECH policy, or cancellation logic to the
  Rust fork when the Dart policy layer owns it.
- Do not regenerate only one side of the FRB boundary or relax the exact
  `2.12.0` pins to make a mismatch disappear.
- Do not hand-edit generated bindings, `Cargo.lock`, or Cargokit's copied
  output to repair a build.
- Do not remove the Cargokit output cleanup, drop reqwest `query`, or enable
  `opt-level = "s"` without the documented device gate.
- Do not treat the ignored live ECH test as a deterministic CI test or claim a
  device/network result when it was not run.
