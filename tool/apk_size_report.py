#!/usr/bin/env python3
"""Summarize per-ABI split APKs and enforce the arm64 size cap.

Prints each APK's file bytes and zipfile compress_size buckets
(lib/<abi>, classes.dex, assets, plus the top 6 buckets). ABI is taken
from the file name (arm64-v8a / armeabi-v7a). Each split APK must contain
exactly one lib/<abi> directory.

Optional env thresholds:
  PIXIV_APK_MAX_BYTES_ARM64_V8A
  PIXIV_APK_MAX_BYTES_ARMEABI_V7A

arm64 always has a hard cap of 32_000_000 bytes; the stricter of that cap
and the env value wins. Empty env values are treated as unset.

Exit 1 and print a ::error:: line on any violation.
"""

from __future__ import annotations

import argparse
import os
import sys
import tempfile
import zipfile
from collections import defaultdict
from pathlib import Path

ARM64 = "arm64-v8a"
ARMV7 = "armeabi-v7a"
KNOWN_ABIS = (ARM64, ARMV7)
ARM64_HARD_CAP = 32_000_000
ENV_ARM64 = "PIXIV_APK_MAX_BYTES_ARM64_V8A"
ENV_ARMV7 = "PIXIV_APK_MAX_BYTES_ARMEABI_V7A"


class ReportError(RuntimeError):
    pass


def env_threshold(name: str) -> int | None:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return None
    try:
        value = int(raw)
    except ValueError as error:
        raise ReportError(f"{name} must be an integer, got {raw!r}") from error
    if value <= 0:
        raise ReportError(f"{name} must be positive, got {value}")
    return value


def threshold_for(abi: str) -> int | None:
    if abi == ARM64:
        env_cap = env_threshold(ENV_ARM64)
        return ARM64_HARD_CAP if env_cap is None else min(ARM64_HARD_CAP, env_cap)
    if abi == ARMV7:
        return env_threshold(ENV_ARMV7)
    return None


def abi_from_filename(path: Path) -> str:
    name = path.name
    found = [abi for abi in KNOWN_ABIS if abi in name]
    if len(found) != 1:
        raise ReportError(
            f"cannot derive ABI from file name {name!r}; "
            f"expected exactly one of {', '.join(KNOWN_ABIS)}"
        )
    return found[0]


def compress_buckets(archive: zipfile.ZipFile) -> tuple[dict[str, int], set[str]]:
    buckets: dict[str, int] = defaultdict(int)
    lib_abis: set[str] = set()
    for info in archive.infolist():
        name = info.filename.replace("\\", "/")
        if name.endswith("/"):
            continue
        if name.startswith("lib/"):
            parts = name.split("/")
            if len(parts) < 3 or not parts[1]:
                raise ReportError(f"unexpected lib/ entry {name!r}")
            abi = parts[1]
            lib_abis.add(abi)
            buckets[f"lib/{abi}"] += info.compress_size
            continue
    for info in archive.infolist():
        name = info.filename.replace("\\", "/")
        if name.endswith("/") or name.startswith("lib/"):
            continue
        top = name.split("/", 1)[0]
        buckets[top] += info.compress_size
    return dict(buckets), lib_abis


def analyze_apk(path: Path) -> dict:
    if not path.is_file() or path.stat().st_size <= 0:
        raise ReportError(f"APK not found or empty: {path}")
    abi = abi_from_filename(path)
    file_bytes = path.stat().st_size
    with zipfile.ZipFile(path) as archive:
        buckets, lib_abis = compress_buckets(archive)
    if lib_abis != {abi}:
        raise ReportError(
            f"{path} contains lib/ directories {sorted(lib_abis)}, "
            f"expected exactly [{abi}]"
        )
    limit = threshold_for(abi)
    return {
        "path": str(path),
        "name": path.name,
        "abi": abi,
        "file_bytes": file_bytes,
        "buckets": buckets,
        "lib_bytes": buckets.get(f"lib/{abi}", 0),
        "dex_bytes": buckets.get("classes.dex", 0),
        "assets_bytes": buckets.get("assets", 0),
        "limit": limit,
    }


def print_apk(report: dict) -> None:
    buckets: dict[str, int] = report["buckets"]
    top = sorted(buckets.items(), key=lambda item: (-item[1], item[0]))[:6]
    print(f"{report['name']}")
    print(f"  file_bytes: {report['file_bytes']}")
    print(f"  abi: {report['abi']}")
    print(f"  lib/{report['abi']}: {report['lib_bytes']}")
    print(f"  classes.dex: {report['dex_bytes']}")
    print(f"  assets: {report['assets_bytes']}")
    print("  top 6:")
    for key, value in top:
        print(f"    {key}: {value}")
    limit = report["limit"]
    if limit is not None:
        print(f"  limit: {limit}")


def print_summary(reports: list[dict]) -> None:
    print("")
    print(f"{'ABI':<14} {'file':>12} {'lib':>12} {'dex':>12} {'assets':>12} {'limit':>12}")
    for report in reports:
        limit = report["limit"]
        print(
            f"{report['abi']:<14} {report['file_bytes']:>12} "
            f"{report['lib_bytes']:>12} {report['dex_bytes']:>12} "
            f"{report['assets_bytes']:>12} "
            f"{(str(limit) if limit is not None else '-'):>12}"
        )


def fail(message: str) -> int:
    print(f"::error::{message}")
    return 1


def write_fake_apk(path: Path, abis: list[str], payload: bytes = b"so") -> None:
    with zipfile.ZipFile(path, "w") as archive:
        for abi in abis:
            archive.writestr(f"lib/{abi}/libfake.so", payload)
        archive.writestr("classes.dex", b"dex")
        archive.writestr("assets/placeholder", b"asset")


def self_test() -> int:
    with tempfile.TemporaryDirectory(prefix="pixiv-apk-size-") as root:
        root_path = Path(root)
        good = root_path / f"app-{ARM64}-fdroid-release.apk"
        write_fake_apk(good, [ARM64])
        if main([str(good)]) != 0:
            return fail("self-test pass path failed")
        print("self-test pass path: ok")

        bad = root_path / f"app-{ARM64}-github-release.apk"
        write_fake_apk(bad, [ARM64, ARMV7])
        if main([str(bad)]) == 0:
            return fail("self-test fail path unexpectedly passed")
        print("self-test fail path: ok")

        os.environ[ENV_ARM64] = "1"
        try:
            if threshold_for(ARM64) != 1:
                return fail("self-test env threshold did not take the stricter cap")
            if main([str(good)]) == 0:
                return fail("self-test env cap unexpectedly passed")
        finally:
            os.environ.pop(ENV_ARM64, None)
        print("self-test env threshold: stricter cap wins")
        print("self-test passed")
        return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apks", nargs="*", type=Path, help="split APK paths")
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="build two fake zips and exercise pass/fail paths",
    )
    args = parser.parse_args(argv)
    if args.self_test:
        return self_test()
    if not args.apks:
        return fail("no APK paths given")

    reports: list[dict] = []
    errors: list[str] = []
    for apk in args.apks:
        try:
            report = analyze_apk(apk)
        except ReportError as error:
            errors.append(str(error))
            continue
        print_apk(report)
        limit = report["limit"]
        if limit is not None and report["file_bytes"] > limit:
            errors.append(
                f"{report['abi']} APK exceeds size cap: "
                f"{report['file_bytes']} > {limit} ({report['name']})"
            )
        reports.append(report)
    if reports:
        print_summary(reports)
    if errors:
        for message in errors:
            print(f"::error::{message}")
        return 1
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except ReportError as error:
        print(f"::error::{error}")
        sys.exit(1)
