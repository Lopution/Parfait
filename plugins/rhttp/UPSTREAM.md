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

## Sync guide

To rebase on a newer upstream:

1. Diff `plugins/rhttp/rhttp` against the new upstream revision.
2. Re-apply the ECH diffs (Cargo.toml + client.rs) and the build-configuration
   list in the D-5 section above (cargokit compileSdk parse, FRB exact pin,
   rust-toolchain.toml).
3. Regenerate `flutter_rust_bridge` bindings if Rust API signatures changed:
   `dart run flutter_rust_bridge_codegen generate` inside `plugins/rhttp/rhttp`.
4. Update this file's upstream commit/version.
