#!/usr/bin/env python3
"""Build the README images: framed screenshots and the header banner.

Inputs (kept outside the repository):
  --raw DIR    the user's device screenshots, 1440x3136, named <shot>.jpg
               (see SHOTS); the README only shows all-ages works.
  device art   Android Studio's Pixel 7 Pro frame (Apache-2.0), fetched from
               a pinned JetBrains/android commit, checked against SHA-256 and
               cached under --cache.
  fonts        Roboto and Material Icons from the pinned Flutter SDK's
               material_fonts artifact (--flutter-root, default: from PATH);
               Noto Sans SC (OFL-1.1) from a pinned noto-cjk commit, fetched
               and checked like the device art.

Outputs in .github/readme/:
  <shot>.webp          one framed screenshot per entry in SHOTS
  banner<lang>.webp    README header per entry in COPIES, 2x for high-DPI
                       screens
  social-preview.jpg   the Chinese banner at 1280x640, uploaded by hand in
                       the repository settings

Usage: python tool/build_readme_assets.py --raw ~/parfait-readme-work/raw
Requirements: tool/requirements-app-icon.txt (numpy, pillow, scipy).
"""

from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import sys
import urllib.request
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont
from scipy.ndimage import binary_dilation, convolve

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / ".github/readme"


@dataclass(frozen=True)
class Shot:
    name: str
    # The app draws edge-to-edge content behind the status bar, so the old
    # icons are removed from the picture instead of painting over a flat fill.
    behind_status_bar: bool = False
    # Light status bar icons, for screens with a dark top edge.
    dark: bool = False


SHOTS = (
    Shot("home"),
    Shot("detail"),
    Shot("search"),
    Shot("profile", behind_status_bar=True),
    Shot("ranking"),
    Shot("novel"),
    Shot("viewer", dark=True),
    Shot("downloads"),
)

RAW_SIZE = (1440, 3136)
# The Pixel 7 Pro screen is 1440x3120; the 16 extra rows come off the top,
# inside the status bar that is redrawn anyway.
CROP_TOP = 16
STATUS_BAND = 150  # rows (after the crop) holding the old status bar icons
# Region of the old icons on edge-to-edge shots, and what counts as an icon
# pixel there: neutral white glyphs, the black hotspot pill and the green
# battery level.
ICON_BOX = (630, 14, 1340, 124)
ICON_WHITE_MIN = 225
ICON_NEUTRAL_SPREAD = 20
ICON_BLACK_MAX = 70
ICON_GREEN_MARGIN = 40  # green channel above both red and blue
ICON_GROW = 5
INPAINT_STEPS = 800

# New status bar, in screen pixels (measured from the original shots).
BAR_CENTER_Y = 75
CLOCK_TEXT = "12:00"
CLOCK_X = 106
CLOCK_PX = 51  # Roboto cap height 0.711 em -> the original 36 px digits
ICON_PX = 60
ICON_GAP = 6
ICONS_RIGHT = 1318
BAR_INK = (31, 31, 31, 255)
BAR_INK_DARK = (255, 255, 255, 255)
# Flutter's MaterialIcons font (its own code points, see Flutter's icons.dart):
# wifi, signal_cellular_4_bar, battery_full.
STATUS_GLYPHS = ("\ue6e7", "\ue5a6", "\ue0d2")
FLAT_FILL_TOLERANCE = 3  # max channel deviation of the row under the bar

OUTPUT_WIDTH = 600  # README shows each frame at about 300 CSS px
WEBP_QUALITY = 88

DEVICE_ART_COMMIT = "b970f072653604910535171169ea4d9eef3580bb"
DEVICE_ART_URL = (
    "https://raw.githubusercontent.com/JetBrains/android/"
    f"{DEVICE_ART_COMMIT}/artwork/resources/device-art-resources/pixel_7_pro/"
)
DEVICE_ART = {
    "back.webp": "f3897119c111de02d97eb7f1098cc18d7d49ca7dc931fd32d1b545c6b267cbec",
    "mask.webp": "eee189c513add4f4295f7c48fa19c8cbfa7ef921cfed6f218a79a731358f861c",
}
SCREEN_SIZE = (1440, 3120)
SCREEN_OFFSET = (48, 66)  # from the device art's `layout` file

# Noto Sans SC (OFL-1.1) for the banner text, from a pinned noto-cjk commit.
CJK_FONT_COMMIT = "f8d157532fbfaeda587e826d4cd5b21a49186f7c"
CJK_FONT_URL = (
    "https://raw.githubusercontent.com/notofonts/noto-cjk/"
    f"{CJK_FONT_COMMIT}/Sans/SubsetOTF/SC/"
)
CJK_FONTS = {
    "NotoSansSC-Bold.otf": "c6cb5a93abaa9edc8ee7463b7ebb7f42d618d40e6ed2f7a5371c97b0b64767c0",
    "NotoSansSC-Regular.otf": "faa6c9df652116dde789d351359f3d7e5d2285a2b2a1f04a2d7244df706d5ea9",
}

# Banner: README header and the repository's social preview. The copy on
# the left, a fan of framed phones on the right. Layout values are in banner
# pixels at 1x; the README copy is drawn at BANNER_SCALE.
ICON = ROOT / ".github/branding/icon-512.png"
BANNER_SIZE = (1280, 640)  # GitHub's recommended social preview size
BANNER_SCALE = 2
BANNER_RADIUS = 28
INK = (43, 26, 34)
INK_MUTED = (110, 88, 98)
BRAND = (228, 70, 122)
CHIP_BORDER = (247, 182, 203)
SHADOW = (122, 14, 54)  # the icon's shadow colour
WASH = ((255, 248, 251), (255, 226, 236))  # top-left -> bottom-right


@dataclass(frozen=True)
class Copy:
    descriptor: str
    headline: str
    chips: tuple[str, ...]


# One banner per README language; the social preview uses the first.
COPIES = {
    "": Copy("第三方 pixiv 客户端", "支持中国大陆直连", ("Android 10+", "免费开源", "无广告无统计")),
    ".en": Copy("Unofficial pixiv client for Android", "Art, manga & novels",
                ("Android 10+", "Open source", "No ads or tracking")),
}

# The copy block; offsets from its top edge, text positions are baselines.
NAME = "Parfait"
ICON_SIZE, ICON_GAP_X, NAME_PX = 96, 22, 72
DESCRIPTOR_PX, DESCRIPTOR_TOP = 28, 160
HEADLINE_PX, HEADLINE_TOP = 46, 228
CHIPS_TOP, CHIP_PX, CHIP_HEIGHT, CHIP_PAD, CHIP_GAP = 262, 18, 40, 20, 10
COPY_HEIGHT = CHIPS_TOP + CHIP_HEIGHT
COPY_LEFT = 92

PHONES = (  # (shot, centre x, centre y, height, angle), back to front
    ("detail", 815, 370, 520, 8),
    ("search", 1095, 380, 520, -8),
    ("home", 955, 350, 590, 0),
)
PHONE_SHADOW_BLUR, PHONE_SHADOW_OPACITY = 24, 0.22
GLOW = (255, 196, 216)  # soft spot of brand colour behind the phones
GLOW_CENTER, GLOW_RADIUS = (955, 330), 420
SOCIAL_JPEG_QUALITY = 90


def fetch_pinned(cache: Path, base_url: str, files: dict[str, str]) -> dict[str, Path]:
    """Download each file once into the cache and check its SHA-256."""
    cache.mkdir(parents=True, exist_ok=True)
    paths = {}
    for name, digest in files.items():
        path = cache / name
        if not path.exists():
            with urllib.request.urlopen(base_url + name, timeout=120) as r:
                path.write_bytes(r.read())
        actual = hashlib.sha256(path.read_bytes()).hexdigest()
        if actual != digest:
            raise SystemExit(f"{path}: sha256 {actual}, expected {digest}")
        paths[name] = path
    return paths


def material_fonts(flutter_root: Path | None) -> Path:
    if flutter_root is None:
        flutter = shutil.which("flutter")
        if flutter is None:
            raise SystemExit("flutter not on PATH; pass --flutter-root")
        flutter_root = Path(flutter).resolve().parent.parent
    fonts = flutter_root / "bin/cache/artifacts/material_fonts"
    if not fonts.is_dir():
        raise SystemExit(f"{fonts} missing; run `flutter precache` first")
    return fonts


def load_screen(raw: Path, shot: Shot) -> Image.Image:
    path = raw / f"{shot.name}.jpg"
    image = Image.open(path).convert("RGB")
    if image.size != RAW_SIZE:
        raise SystemExit(f"{path}: {image.size}, expected {RAW_SIZE}")
    return image.crop((0, CROP_TOP, RAW_SIZE[0], RAW_SIZE[1]))


def clear_flat_bar(screen: Image.Image) -> None:
    """Paint the status bar band with the uniform colour right below it."""
    row = np.asarray(screen)[STATUS_BAND].astype(int)
    fill = np.median(row, axis=0)
    if np.abs(row - fill).max() > FLAT_FILL_TOLERANCE:
        raise SystemExit("row under the status bar is not flat; mark the shot "
                         "behind_status_bar")
    color = tuple(int(c) for c in fill)
    ImageDraw.Draw(screen).rectangle((0, 0, screen.width, STATUS_BAND - 1), color)


def clear_icons_on_picture(screen: Image.Image) -> None:
    """Remove the old icons from edge-to-edge content by diffusing the
    surrounding picture into the icon pixels."""
    x0, y0, x1, y1 = ICON_BOX
    pixels = np.asarray(screen).astype(float)
    region = pixels[y0:y1, x0:x1].copy()
    lo, hi = region.min(axis=2), region.max(axis=2)
    white = (lo >= ICON_WHITE_MIN) & (hi - lo <= ICON_NEUTRAL_SPREAD)
    r, g, b = region[..., 0], region[..., 1], region[..., 2]
    green = g - np.maximum(r, b) >= ICON_GREEN_MARGIN
    mask = binary_dilation(white | green | (hi <= ICON_BLACK_MAX),
                           iterations=ICON_GROW)
    mask[[0, -1], :] = False  # keep the box border as the boundary condition
    mask[:, [0, -1]] = False
    kernel = np.array([[0, 0.25, 0], [0.25, 0, 0.25], [0, 0.25, 0]])
    region[mask] = region[~mask].mean(axis=0)
    for _ in range(INPAINT_STEPS):
        for c in range(3):
            smoothed = convolve(region[..., c], kernel, mode="nearest")
            region[..., c][mask] = smoothed[mask]
    pixels[y0:y1, x0:x1] = region
    screen.paste(Image.fromarray(pixels.round().astype(np.uint8)))


def draw_status_bar(screen: Image.Image, fonts: Path, dark: bool) -> None:
    draw = ImageDraw.Draw(screen)
    ink = BAR_INK_DARK if dark else BAR_INK
    clock = ImageFont.truetype(str(fonts / "Roboto-Medium.ttf"), CLOCK_PX)
    draw.text((CLOCK_X, BAR_CENTER_Y), CLOCK_TEXT, font=clock, fill=ink, anchor="lm")
    icons = ImageFont.truetype(str(fonts / "MaterialIcons-Regular.otf"), ICON_PX)
    x = ICONS_RIGHT
    for glyph in reversed(STATUS_GLYPHS):
        draw.text((x, BAR_CENTER_Y), glyph, font=icons, fill=ink, anchor="rm")
        x -= icons.getlength(glyph) + ICON_GAP


def frame(screen: Image.Image, art: dict[str, Image.Image]) -> Image.Image:
    framed = art["back.webp"].copy()
    framed.paste(screen, SCREEN_OFFSET)
    # mask.webp is a foreground layer: opaque screen corners and camera hole.
    framed.alpha_composite(art["mask.webp"], SCREEN_OFFSET)
    return framed


def resize_to_width(image: Image.Image, width: int) -> Image.Image:
    return image.resize((width, round(image.height * width / image.width)), Image.LANCZOS)


def build_screen(shot: Shot, raw: Path, fonts: Path) -> Image.Image:
    screen = load_screen(raw, shot)
    if shot.behind_status_bar:
        clear_icons_on_picture(screen)
    else:
        clear_flat_bar(screen)
    draw_status_bar(screen, fonts, shot.dark)
    if screen.size != SCREEN_SIZE:
        raise SystemExit(f"{shot.name}: screen {screen.size}, expected {SCREEN_SIZE}")
    return screen


def gradient(size: tuple[int, int]) -> Image.Image:
    w, h = size
    t = (np.arange(w)[None, :] / w + np.arange(h)[:, None] / h) / 2
    start, end = (np.array(c, dtype=float) for c in WASH)
    pixels = start + t[..., None] * (end - start)
    return Image.fromarray(pixels.round().astype(np.uint8)).convert("RGBA")


def round_corners(image: Image.Image, radius: float) -> Image.Image:
    mask = Image.new("L", image.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, *image.size), radius=radius, fill=255)
    rounded = image.convert("RGBA")
    rounded.putalpha(mask)
    return rounded


def drop_shadow(image: Image.Image, blur: float, opacity: float) -> Image.Image:
    """A blurred silhouette of `image`, padded by 2*blur on every side."""
    pad = round(blur * 2)
    alpha = Image.new("L", (image.width + 2 * pad, image.height + 2 * pad), 0)
    alpha.paste(image.getchannel("A"), (pad, pad))
    alpha = alpha.filter(ImageFilter.GaussianBlur(blur)).point(
        lambda a: round(a * opacity))
    shadow = Image.new("RGBA", alpha.size, SHADOW)
    shadow.putalpha(alpha)
    return shadow


def paste_centered(canvas: Image.Image, image: Image.Image,
                   center: tuple[float, float]) -> None:
    canvas.alpha_composite(image, (round(center[0] - image.width / 2),
                                   round(center[1] - image.height / 2)))


def draw_copy(canvas: Image.Image, cjk: dict[str, Path], s: int, copy: Copy,
              left: float, top: float) -> None:
    """Icon and name, descriptor, headline and chips, left-aligned."""
    def font(weight: str, px: int) -> ImageFont.FreeTypeFont:
        return ImageFont.truetype(str(cjk[f"NotoSansSC-{weight}.otf"]), px * s)

    draw = ImageDraw.Draw(canvas)
    icon_px = ICON_SIZE * s
    icon_x, icon_y = round(left), round(top)
    icon = Image.open(ICON).convert("RGBA").resize((icon_px, icon_px), Image.LANCZOS)
    # The icon is white too; the shadow is what outlines it on the light ground.
    paste_centered(canvas, drop_shadow(icon, 6 * s, 0.30),
                   (icon_x + icon_px / 2, icon_y + icon_px / 2 + 3 * s))
    canvas.alpha_composite(icon, (icon_x, icon_y))
    draw.text((icon_x + icon_px + ICON_GAP_X * s, icon_y + icon_px / 2), NAME,
              font=font("Bold", NAME_PX), fill=INK, anchor="lm")

    draw.text((left, top + DESCRIPTOR_TOP * s), copy.descriptor,
              font=font("Regular", DESCRIPTOR_PX), fill=INK_MUTED, anchor="ls")
    draw.text((left, top + HEADLINE_TOP * s), copy.headline,
              font=font("Bold", HEADLINE_PX), fill=BRAND, anchor="ls")

    chip = font("Regular", CHIP_PX)
    chip_x = left
    chip_top = top + CHIPS_TOP * s
    chip_bottom = chip_top + CHIP_HEIGHT * s
    for label in copy.chips:
        width = chip.getlength(label) + 2 * CHIP_PAD * s
        draw.rounded_rectangle((chip_x, chip_top, chip_x + width, chip_bottom),
                               radius=CHIP_HEIGHT * s / 2, fill="white",
                               outline=CHIP_BORDER, width=s)
        draw.text((chip_x + width / 2, (chip_top + chip_bottom) / 2), label, font=chip,
                  fill=INK, anchor="mm")
        chip_x += width + CHIP_GAP * s


def glow(canvas: Image.Image, s: int) -> None:
    w, h = canvas.size
    cx, cy = GLOW_CENTER[0] * s, GLOW_CENTER[1] * s
    d = np.hypot(np.arange(w)[None, :] - cx, np.arange(h)[:, None] - cy) / (GLOW_RADIUS * s)
    layer = Image.new("RGBA", canvas.size, GLOW)
    layer.putalpha(Image.fromarray((np.exp(-d ** 2) * 255).round().astype(np.uint8)))
    canvas.alpha_composite(layer)


def build_banner(framed: dict[str, Image.Image], cjk: dict[str, Path],
                 copy: Copy) -> Image.Image:
    s = BANNER_SCALE
    canvas = gradient((BANNER_SIZE[0] * s, BANNER_SIZE[1] * s))
    glow(canvas, s)
    for name, cx, cy, height, angle in PHONES:
        phone = framed[name]
        phone = phone.resize((round(phone.width * height * s / phone.height), height * s),
                             Image.LANCZOS).rotate(angle, Image.BICUBIC, expand=True)
        paste_centered(canvas, drop_shadow(phone, PHONE_SHADOW_BLUR * s, PHONE_SHADOW_OPACITY),
                       (cx * s, (cy + 16) * s))
        paste_centered(canvas, phone, (cx * s, cy * s))
    draw_copy(canvas, cjk, s, copy, COPY_LEFT * s, (canvas.height - COPY_HEIGHT * s) / 2)
    return canvas


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--raw", type=Path, required=True)
    parser.add_argument("--cache", type=Path,
                        default=Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))
                        / "parfait-readme")
    parser.add_argument("--flutter-root", type=Path)
    args = parser.parse_args()

    art = {name: Image.open(path).convert("RGBA") for name, path in
           fetch_pinned(args.cache / "pixel_7_pro", DEVICE_ART_URL, DEVICE_ART).items()}
    cjk = fetch_pinned(args.cache / "noto-cjk", CJK_FONT_URL, CJK_FONTS)
    fonts = material_fonts(args.flutter_root)
    OUT.mkdir(parents=True, exist_ok=True)

    framed = {shot.name: frame(build_screen(shot, args.raw, fonts), art) for shot in SHOTS}
    for name, image in framed.items():
        save(resize_to_width(image, OUTPUT_WIDTH), OUT / f"{name}.webp")

    for i, (suffix, copy) in enumerate(COPIES.items()):
        banner = build_banner(framed, cjk, copy)
        save(round_corners(banner, BANNER_RADIUS * BANNER_SCALE), OUT / f"banner{suffix}.webp")
        if i == 0:
            social = banner.resize(BANNER_SIZE, Image.LANCZOS).convert("RGB")
            save(social, OUT / "social-preview.jpg")
    return 0


def save(image: Image.Image, path: Path) -> None:
    if path.suffix == ".webp":
        image.save(path, "WEBP", quality=WEBP_QUALITY, method=6)
    else:
        image.save(path, "JPEG", quality=SOCIAL_JPEG_QUALITY, optimize=True)
    print(f"{path.relative_to(ROOT)}  {image.width}x{image.height}  "
          f"{path.stat().st_size // 1024} KB")


if __name__ == "__main__":
    sys.exit(main())
