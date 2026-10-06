#!/usr/bin/env python3
"""Fetch the fonts the UX review harness renders with.

Noto Sans SC (OFL-1.1) covers Latin, Cyrillic, kana and CJK in one family,
like the OEM system fonts on Chinese ROMs. It comes from the same pinned
noto-cjk commit build_readme_assets.py uses for the README banner. The
material icon font comes from the Flutter SDK's material_fonts cache.
Every file is checked against a SHA-256 pin, so a moved SDK or a changed
upstream fails here instead of rendering different shots.

Usage: tool/fetch_review_fonts.py <out-dir>
test/review/flutter_test_config.dart loads the files from <out-dir>.
"""

import hashlib
import shutil
import sys
import urllib.request
from pathlib import Path

CJK_FONT_URL = (
    "https://raw.githubusercontent.com/notofonts/noto-cjk/"
    "f8d157532fbfaeda587e826d4cd5b21a49186f7c/Sans/SubsetOTF/SC/"
)
CJK_FONTS = {
    "NotoSansSC-Regular.otf": "faa6c9df652116dde789d351359f3d7e5d2285a2b2a1f04a2d7244df706d5ea9",
    "NotoSansSC-Medium.otf": "7633f5a016d4dd95e685a69633d818aabc4644c4b08e26bd35b1b30c45ed5dda",
    "NotoSansSC-Bold.otf": "c6cb5a93abaa9edc8ee7463b7ebb7f42d618d40e6ed2f7a5371c97b0b64767c0",
}
SDK_FONTS = {
    "MaterialIcons-Regular.otf": "d9865b671a09d683d13a863089d8825e0f61a37696ce5d7d448bc8023aa62453",
}


def verify(path: Path, digest: str) -> None:
    actual = hashlib.sha256(path.read_bytes()).hexdigest()
    if actual != digest:
        path.unlink()
        raise SystemExit(f"{path.name}: sha256 {actual}, expected {digest}")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)

    flutter = shutil.which("flutter")
    if flutter is None:
        raise SystemExit("flutter not on PATH")
    sdk_fonts = (
        Path(flutter).resolve().parent.parent / "bin/cache/artifacts/material_fonts"
    )
    if not sdk_fonts.is_dir():
        raise SystemExit(f"{sdk_fonts} missing; run `flutter precache` first")
    for name, digest in SDK_FONTS.items():
        shutil.copyfile(sdk_fonts / name, out / name)
        verify(out / name, digest)

    for name, digest in CJK_FONTS.items():
        path = out / name
        if not path.exists():
            with urllib.request.urlopen(CJK_FONT_URL + name, timeout=120) as r:
                path.write_bytes(r.read())
        verify(path, digest)

    print("review fonts:", ", ".join(sorted(p.name for p in out.iterdir())), "->", out)


if __name__ == "__main__":
    main()
