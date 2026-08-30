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

## Sync guide

To rebase on a newer upstream:

1. Diff `plugins/rhttp/rhttp` against the new upstream revision.
2. Re-apply the two diffs above (Cargo.toml + client.rs).
3. Regenerate `flutter_rust_bridge` bindings if Rust API signatures changed:
   `dart run flutter_rust_bridge_codegen generate` inside `plugins/rhttp/rhttp`.
4. Update this file's upstream commit/version.
