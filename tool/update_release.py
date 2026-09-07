#!/usr/bin/env python3
"""Minimal reproducible updater release tooling (09-01 release-blockers).

Produces the two assets the app already downloads from the GitHub release:

  update-manifest.json
  update-manifest.sig       (Base64 text of the DER signature)

Consumed by lib/core/updater/update_manifest.dart. The signature algorithm is
SHA256withECDSA (P-256), the provider contract available since API 29 (D-3);
Ed25519 is NOT available on API 29-32 and must not be used.

Key boundary:
  - The manifest signing key is a separate EC P-256 key, never the APK
    keystore.
  - The private key is read from $PIXIV_UPDATE_SIGNING_KEY (path to a PEM
    file) or --key-file; the script refuses to read it from stdin and never
    prints key material.
  - The public key is emitted to stdout / --pubkey-out as DER base64 for the
    Gradle property PIXIV_UPDATE_PUBLIC_KEY_DER_B64 (matching the format the
    Android verifier Base64-decodes and feeds to KeyFactory("EC")).

Usage:
  python3 tool/update_release.py generate \
      --apk arm64-v8a=<path> --apk armeabi-v7a=<path> \
      --version <semver> --version-code <int> \
      --signing-cert-sha256 <hex64> --key-file <pem> \
      --out-dir <dir> [--pubkey-out <file>] [--channel stable|beta]
  python3 tool/update_release.py pubkey --key-file <pem> [--pubkey-out <file>]
  python3 tool/update_release.py genkey --out <pem-path> [--pubkey-out <file>]

The script fails loudly (non-zero exit, no partial assets) when the private
key is absent or a verification step fails; it never writes half-generated
assets.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import sys
import tempfile
from pathlib import Path
from urllib.parse import urlparse

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec

REPOSITORY = "Lopution/Pixiv-func"
PACKAGE_NAME = "io.github.lopution.pixivfunc"
MANIFEST_NAME = "update-manifest.json"
SIGNATURE_NAME = "update-manifest.sig"
KNOWN_ABIS = {
    "armeabi-v7a": 1000,
    "arm64-v8a": 2000,
}

SEMVER_RE = re.compile(
    r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z.-]+))?(?:\+([0-9A-Za-z.-]+))?$"
)


class ReleaseError(RuntimeError):
    pass


def load_private_key(path: str) -> ec.EllipticCurvePrivateKey:
    key_path = Path(path)
    if not key_path.is_file():
        raise ReleaseError(f"signing key not found: {key_path}")
    try:
        key = serialization.load_pem_private_key(
            key_path.read_bytes(), password=None
        )
    except Exception as error:  # pragma: no cover - defensive
        raise ReleaseError(f"cannot load signing key: {error}")
    if not isinstance(key, ec.EllipticCurvePrivateKey):
        raise ReleaseError("signing key is not an EC private key")
    if not isinstance(key.curve, ec.SECP256R1):
        raise ReleaseError(f"signing key must be P-256, got {key.curve.name}")
    return key


def public_key_der_b64(key: ec.EllipticCurvePrivateKey) -> str:
    der = key.public_key().public_bytes(
        serialization.Encoding.DER,
        serialization.PublicFormat.SubjectPublicKeyInfo,
    )
    return base64.b64encode(der).decode("ascii")


def generate_key(out_path: str, pubkey_out: str | None = None) -> None:
    out = Path(out_path)
    if out.exists():
        raise ReleaseError(f"refusing to overwrite existing key: {out}")
    key = ec.generate_private_key(ec.SECP256R1())
    pem = key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    )
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(pem)
    try:
        os.chmod(out, 0o600)
    except OSError:
        pass
    pubkey = public_key_der_b64(key)
    if pubkey_out:
        Path(pubkey_out).write_text(pubkey + "\n")
        try:
            os.chmod(pubkey_out, 0o600)
        except OSError:
            pass
    print("generated P-256 signing key at %s (chmod 0600)" % out)


def asset_url_for(version: str, abi: str) -> str:
    # GitHub does not normalise repository-name case before redirecting.
    url = (
        f"https://github.com/Lopution/Pixiv-func/releases/download/"
        f"v{version}/pixiv-func-v{version}-github-{abi}.apk"
    )
    parsed = urlparse(url)
    if (
        parsed.scheme != "https"
        or parsed.hostname != "github.com"
        or parsed.username
        or parsed.fragment
        or not parsed.path.startswith("/Lopution/Pixiv-func/releases/download/")
        or not parsed.path.lower().endswith(".apk")
    ):
        raise ReleaseError("asset URL must be the GitHub repository release APK URL")
    return parsed.geturl()


def parse_apk_spec(value: str) -> tuple[str, Path]:
    if "=" not in value:
        raise ReleaseError(f"--apk must be <abi>=<path>, got {value!r}")
    abi, raw_path = value.split("=", 1)
    if abi not in KNOWN_ABIS:
        raise ReleaseError(f"unsupported ABI {abi!r}")
    path = Path(raw_path)
    if not path.is_file() or path.stat().st_size <= 0:
        raise ReleaseError(f"apk not found: {path}")
    return abi, path


def manifest_payload(
    apk_specs: list[tuple[str, Path]],
    version: str,
    version_code: int,
    signing_cert_sha256: str,
    channel: str,
) -> dict:
    match = SEMVER_RE.match(version)
    if not match:
        raise ReleaseError(f"invalid semver: {version}")
    if version_code <= 0 or version_code > 0x7FFFFFFF:
        raise ReleaseError(f"invalid versionCode: {version_code}")
    if channel not in ("stable", "beta"):
        raise ReleaseError(f"invalid channel: {channel}")
    cert = signing_cert_sha256.lower()
    if not re.fullmatch(r"[0-9a-f]{64}", cert):
        raise ReleaseError("signingCertSha256 must be 64 lowercase hex")
    if not apk_specs:
        raise ReleaseError("at least one --apk <abi>=<path> is required")
    seen: set[str] = set()
    assets: list[dict] = []
    for abi, apk in apk_specs:
        if abi in seen:
            raise ReleaseError(f"duplicate ABI {abi}")
        seen.add(abi)
        assets.append(
            {
                "abi": abi,
                "url": asset_url_for(version, abi),
                "size": apk.stat().st_size,
                "sha256": hashlib.sha256(apk.read_bytes()).hexdigest(),
                "versionCode": KNOWN_ABIS[abi] + version_code,
            }
        )
    return {
        "schema": 2,
        "repository": REPOSITORY,
        "tag": f"v{version}",
        "channel": channel,
        "version": version,
        "versionCode": version_code,
        "packageName": PACKAGE_NAME,
        "signingCertificateSha256": cert,
        "assets": assets,
    }


def generate(
    apk_specs: list[tuple[str, Path]],
    version: str,
    version_code: int,
    signing_cert_sha256: str,
    key_file: str,
    out_dir: str,
    pubkey_out: str | None = None,
    channel: str = "stable",
) -> None:
    key = load_private_key(key_file)
    payload = manifest_payload(
        apk_specs, version, version_code, signing_cert_sha256, channel
    )
    # Canonical, reproducible bytes: what is written is exactly what is
    # signed. No trailing newline, no re-ordering of the dict beyond the
    # fixed literal order above.
    manifest_bytes = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    signature = key.sign(manifest_bytes, ec.ECDSA(hashes.SHA256()))
    pubkey = public_key_der_b64(key)

    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    manifest_path = out / MANIFEST_NAME
    signature_path = out / SIGNATURE_NAME
    if manifest_path.exists() or signature_path.exists():
        raise ReleaseError(
            f"refusing to overwrite existing assets in {out} "
            "(remove them first or use a fresh out-dir)"
        )
    # Write signature first; the manifest only lands once signing succeeded.
    # Upload ASCII Base64 so HTTP transport cannot reinterpret arbitrary DER
    # bytes through a text response path.
    signature_path.write_text(base64.b64encode(signature).decode("ascii") + "\n")
    manifest_path.write_bytes(manifest_bytes)
    if pubkey_out:
        Path(pubkey_out).write_text(pubkey + "\n")
        try:
            os.chmod(pubkey_out, 0o600)
        except OSError:
            pass
    print(f"wrote {manifest_path}")
    print(f"wrote {signature_path} (Base64 of {len(signature)} DER bytes)")
    print(f"public key DER base64 for PIXIV_UPDATE_PUBLIC_KEY_DER_B64: {pubkey}")


def self_test() -> None:
    """Run a disposable sign/verify/tamper round-trip without repo writes."""
    with tempfile.TemporaryDirectory(prefix="pixivfunc-release-test-") as root:
        root_path = Path(root)
        key_path = root_path / "test-key.pem"
        arm64 = root_path / "arm64.apk"
        armv7 = root_path / "armv7.apk"
        out_dir = root_path / "assets"
        key = ec.generate_private_key(ec.SECP256R1())
        key_path.write_bytes(
            key.private_bytes(
                serialization.Encoding.PEM,
                serialization.PrivateFormat.PKCS8,
                serialization.NoEncryption(),
            )
        )
        arm64.write_bytes(b"pixiv-func-release-self-test-arm64")
        armv7.write_bytes(b"pixiv-func-release-self-test-armv7")
        cert = "a" * 64
        generate(
            [("arm64-v8a", arm64), ("armeabi-v7a", armv7)],
            "1.2.3-test",
            123,
            cert,
            str(key_path),
            str(out_dir),
        )
        manifest = (out_dir / MANIFEST_NAME).read_bytes()
        payload = json.loads(manifest.decode("utf-8"))
        if payload.get("schema") != 2:
            raise ReleaseError(f"self-test schema: {payload.get('schema')}")
        if payload.get("versionCode") != 123:
            raise ReleaseError("self-test base versionCode must stay unshifted")
        assets = payload.get("assets")
        if not isinstance(assets, list) or len(assets) != 2:
            raise ReleaseError("self-test must write two assets")
        by_abi = {item["abi"]: item for item in assets}
        if by_abi["arm64-v8a"]["versionCode"] != 2123:
            raise ReleaseError("self-test arm64 versionCode")
        if by_abi["armeabi-v7a"]["versionCode"] != 1123:
            raise ReleaseError("self-test armeabi-v7a versionCode")
        signature = base64.b64decode(
            (out_dir / SIGNATURE_NAME).read_text().strip(), validate=True
        )
        key.public_key().verify(signature, manifest, ec.ECDSA(hashes.SHA256()))
        tampered = manifest + b" "
        try:
            key.public_key().verify(signature, tampered, ec.ECDSA(hashes.SHA256()))
        except Exception:
            pass
        else:
            raise ReleaseError("self-test tamper verification unexpectedly passed")
        try:
            generate(
                [("arm64-v8a", arm64), ("armeabi-v7a", armv7)],
                "1.2.3-test",
                123,
                cert,
                str(key_path),
                str(out_dir),
            )
        except ReleaseError as error:
            if "refusing to overwrite" not in str(error):
                raise
        else:
            raise ReleaseError("self-test overwrite unexpectedly succeeded")
        print("self-test passed: schema 2, two assets, sign/verify, tamper")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    gen = sub.add_parser("generate", help="generate manifest + signature")
    gen.add_argument(
        "--apk",
        action="append",
        required=True,
        metavar="ABI=PATH",
        help="repeatable split APK spec, e.g. arm64-v8a=app.apk",
    )
    gen.add_argument("--version", required=True)
    gen.add_argument("--version-code", type=int, required=True)
    gen.add_argument("--signing-cert-sha256", required=True)
    gen.add_argument("--key-file", required=True)
    gen.add_argument("--out-dir", required=True)
    gen.add_argument("--pubkey-out")
    gen.add_argument("--channel", default="stable")

    pub = sub.add_parser("pubkey", help="print the public key DER base64")
    pub.add_argument("--key-file", required=True)
    pub.add_argument("--pubkey-out")

    keygen = sub.add_parser("genkey", help="generate a fresh P-256 key pair")
    keygen.add_argument("--out", required=True)
    keygen.add_argument("--pubkey-out")

    sub.add_parser("self-test", help="run a disposable sign/verify/tamper check")

    args = parser.parse_args(argv)
    if args.command == "generate":
        generate(
            [parse_apk_spec(spec) for spec in args.apk],
            args.version,
            args.version_code,
            args.signing_cert_sha256,
            args.key_file,
            args.out_dir,
            args.pubkey_out,
            args.channel,
        )
    elif args.command == "pubkey":
        key = load_private_key(args.key_file)
        pubkey = public_key_der_b64(key)
        if args.pubkey_out:
            Path(args.pubkey_out).write_text(pubkey + "\n")
        print(pubkey)
    elif args.command == "genkey":
        generate_key(args.out, args.pubkey_out)
    elif args.command == "self-test":
        self_test()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except ReleaseError as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
