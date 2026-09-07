# Upstream

- Package: `rhttp` (Flutter plugin + Rust crate)
- Upstream: https://codeberg.org/Tienisto/rhttp
- Upstream commit: `9871f1c25d0cf75553af85698b9f03d38f438aed` (main, 2026-07-08)
  ("fix(android): initialize the native context only once per process (#111)")
- Version: 0.18.0 (per `pubspec.yaml`)
- License: MIT (see LICENSE)

## Fork policy

Keep functional diffs minimal. The ONLY functional change vs upstream is ECH
support at the TLS layer:

- `rust/Cargo.toml`: add `rustls = "0.23"` (with `aws-lc-rs` provider for ECH).
- `rust/src/api/client.rs`:
  - `TlsSettings` gains optional `ech_config_list: Option<Vec<u8>>` (ECH
    config bytes, as produced by the ECHClientConfig rdata of an HTTPS RR).
  - When present, build a rustls `EchMode::Enable` client config and inject
    it via reqwest `tls_backend_preconfigured`. When absent, behavior is
    byte-for-byte identical to upstream.
- Nothing else. DNS resolution, ECH config discovery, TTL, endpoint selection
  and cancellation stay in Dart (`DohResolver` + `NetworkAccessPolicy`).
  Dart passes resolved IPs via `DnsSettings.static` and ECH bytes via
  `TlsSettings.ech_config_list`.

Explicitly NOT inherited from PixEz's GPL-3 fork (even though it solved the
same problem): the AliDNS HTTPS-RR lookup, per-host ECH client cache,
`enable_ech`/`require_ech` policy switches. Those belong to the Dart policy
layer in this project, and copying GPL-3 code would contaminate the MIT
lineage.

Not part of this fork (upstream features, out of scope):
- HTTP/3 / QUIC usage (compiled upstream, unused by this app).

## Build configuration diffs (parent D-5)

- `rhttp/cargokit/gradle/plugin.gradle`: parse `compileSdkVersion` as the API
  major (`"android-37.0".substring(8).tokenize('.')[0]`). Upstream
  `substring(8) as int` throws `For input string: "37.0"` when AGP 9.1.1 +
  `platforms;android-37.0` reports `android-37.0` instead of `android-37`.
  Needed for child A step A7 (`compileSdk 37`). Re-apply on upstream sync.
- `rhttp/pubspec.yaml` pins `flutter_rust_bridge: 2.12.0` (no `^`) and the
  app tracks `rhttp/pubspec.lock`. Dart lock had resolved 2.13.0 while
  generated `frb_generated.dart` and Cargo stay on 2.12.0;
  `tool/frb_check.sh` fails unless every source matches.
- App-root `rust-toolchain.toml` pins `1.98.0` with `rustfmt`/`clippy` and
  Android targets `aarch64` / `armv7` / `x86_64` / `i686` (debug cargokit
  also builds `android-x86`). It sits at the app root rather than next to
  `rust/Cargo.toml` because cargokit's `_getToolchainVersion` only reads
  `<app root>/rust-toolchain.toml` (then falls back to `stable`), while
  rustup walks up from `rust/` to the same file. CI uses
  `flutter pub get --enforce-lockfile` and `cargo test --locked`.
- `rust/src/lib.rs`: `#[rustfmt::skip]` on `mod frb_generated;`. The codegen
  output is not rustfmt-stable across toolchains and CI runs
  `cargo fmt --check`; skipping the generated module keeps the check
  meaningful for hand-written code.
- `rhttp/cargokit/gradle/plugin.gradle`: `CargoKitBuildTask.build()` deletes
  `jniLibs/<buildType>` (`outputDir`) before `execOperations.exec` runs
  `build-gradle`. Upstream `build_gradle.dart` only `copySync`s the current
  target set and never removes leftover ABI subdirectories, so a later
  `--target-platform android-arm64` build would otherwise package stale
  `librhttp.so` from a previous 3-ABI run (research §0.2, ~10.4 MB).
  Re-apply on upstream sync.
- `rust/Cargo.toml` reqwest: drop `multipart`. The app never sends
  `HttpBody.multipart` (profile/SauceNAO multipart is built in Dart).
  `http.rs` returns `RhttpError::RhttpUnknownError` for that body instead of
  linking `reqwest::multipart` / `mime_guess`. Re-apply on upstream sync.
- `rust/Cargo.toml` reqwest: drop `form`. The app never sends
  `HttpBody.form`. `http.rs` returns `RhttpError::RhttpUnknownError` for that
  body instead of calling `RequestBuilder::form`. Re-apply on upstream sync.
- `rust/Cargo.toml` reqwest: drop `socks`. The app never passes
  `ProxySettings`; `socks://` URLs fail at `Proxy::*` construction via the
  existing `RhttpUnknownError`. http/https proxies still compile. Re-apply
  on upstream sync.
- `rust/Cargo.toml` reqwest: drop `cookies`. The app never passes
  `CookieSettings`. `client.rs` returns `RhttpError::RhttpUnknownError`
  instead of `ClientBuilder::cookie_store`, dropping `cookie_store` /
  `publicsuffix` / `time` from the lock. Re-apply on upstream sync.
- `rust/Cargo.toml` reqwest: drop `query`. The app builds query strings
  into the URL itself. `http.rs` returns `RhttpError::RhttpUnknownError`
  when the plugin `query` argument is present, dropping
  `serde_urlencoded`. Re-apply on upstream sync.
- `rust/Cargo.toml` reqwest: drop `charset`. The app never uses plugin
  text decoding (compat layer returns bytes). Drops `encoding_rs` from
  the lock; `.text()` still compiles as UTF-8. Re-apply on upstream sync.

## Sync guide

To rebase on a newer upstream:

1. Diff `plugins/rhttp/rhttp` against the new upstream revision.
2. Re-apply the ECH diffs (Cargo.toml + client.rs) and the build-configuration
   list in the D-5 section above (cargokit compileSdk parse, FRB exact pin,
   rust-toolchain.toml).
3. Regenerate `flutter_rust_bridge` bindings if Rust API signatures changed:
   `dart run flutter_rust_bridge_codegen generate` inside `plugins/rhttp/rhttp`.
   `src/lib.rs` carries `#[rustfmt::skip]` on `mod frb_generated;`, so the
   regenerated file is exempt from CI's `cargo fmt --check`; hand-written
   Rust must stay `cargo fmt` clean.
4. Update this file's upstream commit/version.
