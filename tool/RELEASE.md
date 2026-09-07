# Release keys & updater assets (09-01 release-blockers)

This project signs two independent things:

1. **APK release keystore** — `github` flavor. Official material never
   enters the repository.
2. **Updater manifest signing key** — a separate EC P-256 key used by
   `tool/update_release.py`; never the APK keystore.

## Key management

All keys are generated **outside the repository** by the developer/agent and
stored with `0700` directory / `0600` file permissions. The user keeps an
offline encrypted backup. Keys are never committed, never printed to logs,
never placed in CI artifacts.

### APK keystore

```bash
# Out-of-repo directory, e.g. ~/.pixivfunc-release/
mkdir -p ~/.pixivfunc-release && chmod 700 ~/.pixivfunc-release
cd ~/.pixivfunc-release
keytool -genkeypair -v \
  -keystore pixivfunc-release.jks \
  -alias pixivfunc \
  -keyalg RSA -keysize 4096 -validity 10000 \
  -storetype JKS
chmod 600 pixivfunc-release.jks
```

Then build two split APKs (no fat / universal, no x86_64):

```bash
flutter build apk --release --flavor github \
  --split-per-abi --target-platform android-arm64,android-arm \
  --obfuscate --split-debug-info=build/symbols/github \
  -PPIXIV_RELEASE_KEYSTORE=$HOME/.pixivfunc-release/pixivfunc-release.jks \
  -PPIXIV_RELEASE_KEYSTORE_PASSWORD=... \
  -PPIXIV_RELEASE_KEY_ALIAS=pixivfunc \
  -PPIXIV_RELEASE_KEY_PASSWORD=...
```

Missing material: the release build fails with an explicit error. A local
debug-signed test APK is available only when the command explicitly adds
`-PPIXIV_ALLOW_DEBUG_RELEASE_SIGNING=true`; it is **NOT publishable** and has
`RELEASE_SIGNED_OFFICIALLY=false`. The CI release workflow fails when secrets
are absent.

`fdroid` flavor stays store-managed (D-5): no local release key; F-Droid's
build server signs its own builds.

### Updater manifest signing key

```bash
python3 tool/update_release.py genkey --out ~/.pixivfunc-release/update-signing-key.pem \
  --pubkey-out ~/.pixivfunc-release/update-signing-key.pub.b64
```

The printed/emitted **public** DER base64 is injected as the Gradle property
`PIXIV_UPDATE_PUBLIC_KEY_DER_B64` (already supported by `build.gradle.kts`;
the `fdroid` flavor keeps it empty because the updater is disabled there).

## Release procedure (per release)

1. Build the two split APKs: see above, `github` flavor. Flutter 3.47.2
   names them `app-arm64-v8a-github-release.apk` and
   `app-armeabi-v7a-github-release.apk`.
2. Check that both signer certificate fingerprints match:
   ```bash
   apksigner verify --print-certs \
     build/app/outputs/flutter-apk/app-arm64-v8a-github-release.apk
   apksigner verify --print-certs \
     build/app/outputs/flutter-apk/app-armeabi-v7a-github-release.apk
   ```
3. Generate the schema 2 manifest + signature. Asset URLs are derived from
   version + ABI; do not pass `--asset-url`:
   ```bash
   python3 tool/update_release.py generate \
     --apk arm64-v8a=build/app/outputs/flutter-apk/app-arm64-v8a-github-release.apk \
     --apk armeabi-v7a=build/app/outputs/flutter-apk/app-armeabi-v7a-github-release.apk \
     --version 1.0.0 --version-code 1 \
     --signing-cert-sha256 <hex from step 2> \
     --key-file ~/.pixivfunc-release/update-signing-key.pem \
     --out-dir ~/.pixivfunc-release/assets
   ```
   Top-level `versionCode` is the unshifted base `n`. Each asset stores the
   Flutter offset (`arm64-v8a` = `2000+n`, `armeabi-v7a` = `1000+n`).
4. Upload to the GitHub draft release exactly these four files (no fat APK):
   `pixiv-func-v<ver>-github-arm64-v8a.apk`,
   `pixiv-func-v<ver>-github-armeabi-v7a.apk`,
   `update-manifest.json`, and `update-manifest.sig`.
   The derived asset URL is
   `https://github.com/Lopution/Pixiv-func/releases/download/v<ver>/pixiv-func-v<ver>-github-<abi>.apk`
   (repository-name case is significant). See
   `.github/workflows/release.yml` for the automated path. Obfuscation
   symbols stay on the Actions artifact, not the public release.
5. Verify on real devices: API 29 and a modern Android, each selecting its
   ABI asset. The negative case (tampered manifest/signature, or a manifest
   missing the device ABI) must be rejected with a visible reason — never
   shown as “already up to date”.

## Signature algorithm

`SHA256withECDSA` (P-256) — the provider contract available since API 29
(D-3). Ed25519 is **not** available on API 29-32 and must never be used.
The manifest bytes signed are exactly the file bytes of
`update-manifest.json` (UTF-8, no trailing newline, `json.dumps(separators=(",",":"))`
ordering fixed by the script).

### Offline self-test

The signing tool includes a disposable-key round-trip and tamper check. It does
not read repository keys or leave assets behind:

```bash
python3 tool/update_release.py self-test
```
