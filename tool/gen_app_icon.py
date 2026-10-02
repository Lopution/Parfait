#!/usr/bin/env python3
"""Render every app icon asset from the ribbon-P design ("E").

The mark is authored in a 1024-unit square: the 72dp visible area of an
Android adaptive icon. The ribbon gets a path-following colour field (OKLab
ramps along its arc length, shaded across its width) that SVG and
VectorDrawable cannot express, so everything except the monochrome layer is
rasterised here and the outputs are committed; this file is their source.

Setup (once):
    python3 -m venv /tmp/iconvenv
    /tmp/iconvenv/bin/pip install -r tool/requirements-app-icon.txt
Usage:
    /tmp/iconvenv/bin/python tool/gen_app_icon.py          # write all outputs
    /tmp/iconvenv/bin/python tool/gen_app_icon.py --check  # compare, exit 1 on drift
"""

from __future__ import annotations

import argparse
import io
import math
import sys
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw
from scipy.ndimage import gaussian_filter
from scipy.spatial import cKDTree
from shapely import affinity
from shapely.geometry import LineString, Point, Polygon, box
from shapely.ops import unary_union

ROOT = Path(__file__).resolve().parent.parent
RES = ROOT / "android/app/src/main/res"

DESIGN = 1024  # units of the visible 72dp area
ADAPTIVE = 1536  # units of the full 108dp adaptive-icon canvas
SUPERSAMPLE = 4

# ------------------------------------------------------------------ colour --

BAND = [(0, "#FFA3C0"), (0.16, "#FF7A9F"), (0.32, "#F4507F"), (0.48, "#FF6A92"),
        (0.7, "#F04B7F"), (0.88, "#DA3A70"), (1, "#C02A62")]
STEM = [(0, "#FF8FAE"), (0.45, "#FF6289"), (0.82, "#E4467A"), (1, "#C73068")]
STAR = [(0, "#FFD867"), (1, "#FFB930")]
SHADOW = "#7A0E36"
FOLD_SHADOW = 0.3  # stem darkening under the band that folds over it
TUCK_SHADOW = 0.34  # band darkening where it tucks under the stem
CROSS_SHADE = 0.03  # OKLab lightness change across the band width

_M1 = np.array([[0.4122214708, 0.5363325363, 0.0514459929],
                [0.2119034982, 0.6806995451, 0.1073969566],
                [0.0883024619, 0.2817188376, 0.6299787005]])
_M2 = np.array([[0.2104542553, 0.7936177850, -0.0040720468],
                [1.9779984951, -2.4285922050, 0.4505937099],
                [0.0259040371, 0.7827717662, -0.8086757660]])


def _hex(h: str) -> np.ndarray:
    h = h.lstrip("#")
    return np.array([int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)])


def _to_linear(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def _to_srgb(c):
    c = np.clip(c, 0, 1)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * c ** (1 / 2.4) - 0.055)


def to_oklab(rgb):
    return np.cbrt(_to_linear(rgb) @ _M1.T) @ _M2.T


def from_oklab(lab):
    lms = (lab @ np.linalg.inv(_M2).T) ** 3
    return _to_srgb(lms @ np.linalg.inv(_M1).T)


def ramp(stops, s):
    """Interpolate colour stops in OKLab; returns an OKLab array."""
    pos = np.array([p for p, _ in stops])
    labs = np.array([to_oklab(_hex(c)) for _, c in stops])
    s = np.clip(s, 0, 1)
    return np.stack([np.interp(s, pos, labs[:, k]) for k in range(3)], axis=-1)


# ---------------------------------------------------------------- geometry --

STEM_L, STEM_R, TOP = 320, 480, 203
BOTTOM_L, BOTTOM_R = 818, 772
STEM_TOP = 250
HEAD_Y = 450  # the band lies over the stem north of this line, under it south
GEOM = dict(yf=410, rx=165, n=2.3, bx=560, a=193, bottom=618,
            yr=338, yt=305, ai=70, yb=505, c1=(34, -40), c2=70)
STAR_CENTRE, STAR_RADIUS, STAR_ROTATION = (705, 250), 108, -10
STAR_GAP = 26  # clearance between the star and the ribbon
MONO_SLIT = 9  # half-width of the slits that keep the fold legible in monochrome


def superellipse(cx, cy, a, b, n, t0, t1, steps):
    pts = []
    for t in np.linspace(t0, t1, steps):
        c, s = math.cos(t), math.sin(t)
        pts.append((cx + a * math.copysign(abs(c) ** (2 / n), c),
                    cy + b * math.copysign(abs(s) ** (2 / n), s)))
    return pts


def cubic(p0, p1, p2, p3, steps):
    out = []
    for t in np.linspace(0, 1, steps):
        u = 1 - t
        out.append((u ** 3 * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t ** 3 * p3[0],
                    u ** 3 * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t ** 3 * p3[1]))
    return out


def line(p, q, steps):
    return [(p[0] + (q[0] - p[0]) * t, p[1] + (q[1] - p[1]) * t)
            for t in np.linspace(0, 1, steps)]


def half_plane(p, q, size=4000):
    """Half-plane bounded by the line p->q, keeping the side left of p->q."""
    p, q = np.array(p, float), np.array(q, float)
    d = (q - p) / np.linalg.norm(q - p)
    n = np.array([d[1], -d[0]])
    a, b = p - d * size, p + d * size
    return Polygon([a, b, b + n * size, a + n * size])


def round_corner(shape, corner, r):
    opened = shape.buffer(-r, quad_segs=24).buffer(r, quad_segs=24)
    region = Point(corner).buffer(r * 3)
    return unary_union([opened.intersection(region), shape.difference(region)])


@dataclass(frozen=True)
class Band:
    poly: Polygon
    outer: np.ndarray  # stations on the outer edge
    inner: np.ndarray  # matching stations on the inner edge


def strip(outer_parts, inner_parts) -> Band:
    outer, inner = [], []
    for o, i in zip(outer_parts, inner_parts):
        last = o is outer_parts[-1]
        outer += o if last else o[:-1]
        inner += i if last else i[:-1]
    outer, inner = np.array(outer), np.array(inner)
    return Band(Polygon(np.vstack([outer, inner[::-1]])).buffer(0), outer, inner)


def stem_poly():
    yf, rx = GEOM["yf"], GEOM["rx"]
    # Clip the stem top to the band's outer corner so no square corner shows.
    corner = superellipse(STEM_L + rx, yf, rx, yf - TOP, GEOM["n"], math.pi, 1.5 * math.pi, 90)
    clip = Polygon(corner + [(STEM_R + 20, TOP), (STEM_R + 20, 1000), (STEM_L, 1000)])
    stem = box(STEM_L, STEM_TOP, STEM_R, 900).intersection(clip)
    stem = stem.intersection(half_plane((STEM_L, BOTTOM_L), (STEM_R, BOTTOM_R)))
    stem = round_corner(stem, (STEM_L, BOTTOM_L), 40)
    return round_corner(stem, (STEM_R, BOTTOM_R), 18)


FOLD_STATIONS = 90  # inner-edge stations of the fold where the band crosses the stem


def band_strip() -> Band:
    g = GEOM
    yf, rx, n, bx = g["yf"], g["rx"], g["n"], g["bx"]
    b = (g["bottom"] - TOP) / 2
    cy = TOP + b
    outer = [
        superellipse(STEM_L + rx, yf, rx, yf - TOP, n, math.pi, 1.5 * math.pi, FOLD_STATIONS),
        line((STEM_L + rx, TOP), (bx, TOP), 40),
        superellipse(bx, cy, g["a"], b, n, -math.pi / 2, math.pi / 2, 240),
        line((bx, g["bottom"]), (400, g["bottom"]), 50),
    ]
    yr, yt, yb = g["yr"], g["yt"], g["yb"]
    d = np.array([bx - STEM_R, yt - yr], float)
    d /= np.linalg.norm(d)
    f = (STEM_L, yf)
    (c1x, c1y), c2 = g["c1"], g["c2"]
    inner = [
        cubic(f, (f[0] + c1x, f[1] + c1y), (STEM_R - d[0] * c2, yr - d[1] * c2),
              (STEM_R, yr), FOLD_STATIONS),
        line((STEM_R, yr), (bx, yt), 40),
        superellipse(bx, (yt + yb) / 2, g["ai"], (yb - yt) / 2, n, -math.pi / 2, math.pi / 2, 240),
        line((bx, yb), (400, yb), 50),
    ]
    return strip(outer, inner)


def star_poly(ratio=0.52, tip=20, notch=10):
    (cx, cy), r_out = STAR_CENTRE, STAR_RADIUS
    pts = []
    for k in range(10):
        r = r_out if k % 2 == 0 else r_out * ratio
        a = math.radians(STAR_ROTATION - 90 + k * 36)
        pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    s = Polygon(pts)
    s = s.buffer(-tip, join_style="round").buffer(tip, join_style="round")
    return s.buffer(notch, join_style="round").buffer(-notch, join_style="round")


@dataclass(frozen=True)
class Mark:
    """Mark geometry moved onto a canvas; `dx`/`dy` is the applied offset."""
    band: Band
    stem: Polygon
    star: Polygon
    dx: float
    dy: float


def mark(offset: float) -> Mark:
    """Centre the mark in the 1024-unit design square, then shift by `offset`."""
    band, stem, star = band_strip(), stem_poly(), star_poly()
    minx, miny, maxx, maxy = unary_union([band.poly, stem, star]).bounds
    dx = DESIGN / 2 - (minx + maxx) / 2 + offset
    dy = DESIGN / 2 - (miny + maxy) / 2 + offset
    move = lambda g: affinity.translate(g, dx, dy)  # noqa: E731
    shift = np.array([dx, dy])
    return Mark(Band(move(band.poly), band.outer + shift, band.inner + shift),
                move(stem), move(star), dx, dy)


# --------------------------------------------------------------- rendering --

def coverage(poly, size, scale):
    img = Image.new("L", (size * SUPERSAMPLE, size * SUPERSAMPLE), 0)
    draw = ImageDraw.Draw(img)
    polys = [poly] if poly.geom_type == "Polygon" else list(poly.geoms)
    k = scale * SUPERSAMPLE
    for p in polys:
        if p.is_empty:
            continue
        draw.polygon([(x * k, y * k) for x, y in p.exterior.coords], fill=255)
        for ring in p.interiors:
            draw.polygon([(x * k, y * k) for x, y in ring.coords], fill=0)
    img = img.resize((size, size), Image.Resampling.BOX)
    return np.asarray(img, dtype=np.float64) / 255


def band_field(band: Band, size, scale, smooth=1.5):
    """Per-pixel arc-length position `s` and cross position `t` (-1 inner .. +1 outer)."""
    center = (band.outer + band.inner) / 2
    seglen = np.linalg.norm(np.diff(center, axis=0), axis=1)
    s_st = np.concatenate([[0], np.cumsum(seglen)])
    s_st /= s_st[-1]
    across = band.outer - band.inner
    half = np.linalg.norm(across, axis=1) / 2
    normal = across / np.maximum(half[:, None] * 2, 1e-6)
    ys, xs = np.mgrid[0:size, 0:size]
    pts = np.stack([(xs + 0.5) / scale, (ys + 0.5) / scale], axis=-1).reshape(-1, 2)
    _, idx = cKDTree(center).query(pts)
    s = s_st[idx]
    t = np.einsum("ij,ij->i", pts - center[idx], normal[idx]) / np.maximum(half[idx], 1)
    s = gaussian_filter(s.reshape(size, size), smooth * scale)
    t = gaussian_filter(np.clip(t, -1.2, 1.2).reshape(size, size), smooth * scale)
    return s, t


def blurred(mask, sigma, dx, dy, scale):
    m = np.roll(np.roll(mask, int(round(dy * scale)), axis=0), int(round(dx * scale)), axis=1)
    return gaussian_filter(m, sigma * scale)


def linear_gradient(size, scale, stops, p0, p1):
    ys, xs = np.mgrid[0:size, 0:size] / scale
    d = np.array(p1, float) - np.array(p0, float)
    s = ((xs - p0[0]) * d[0] + (ys - p0[1]) * d[1]) / (d @ d)
    return from_oklab(ramp(stops, s))


def render_mark(size: int, canvas_units: int) -> np.ndarray:
    """Straight-alpha RGBA float array of the mark on a transparent canvas."""
    scale = size / canvas_units
    m = mark((canvas_units - DESIGN) / 2)
    gap = m.star.buffer(STAR_GAP)
    head = m.band.poly.intersection(box(0, 0, STEM_R + 1 + m.dx, HEAD_Y + m.dy))
    a_band = coverage(m.band.poly.difference(gap), size, scale)
    a_stem = coverage(m.stem.difference(gap), size, scale)
    a_head = coverage(head.difference(gap), size, scale)
    a_star = coverage(m.star, size, scale)

    s, t = band_field(m.band, size, scale)
    band_lab = ramp(BAND, s)
    band_lab[..., 0] += CROSS_SHADE * t
    band_rgb = from_oklab(band_lab)
    ys = np.mgrid[0:size, 0:size][0] / scale
    stem_rgb = from_oklab(ramp(STEM, (BOTTOM_L + m.dy - ys) / (BOTTOM_L - STEM_TOP)))
    deep = _hex(SHADOW)
    south = np.clip((ys - HEAD_Y - m.dy) / 20, 0, 1)
    tuck = (TUCK_SHADOW * blurred(a_stem, 11, 7, 0, scale) * south)[..., None]
    band_rgb = band_rgb * (1 - tuck) + deep * tuck
    fold = (FOLD_SHADOW * blurred(a_head, 11, 3, 9, scale))[..., None]
    stem_rgb = stem_rgb * (1 - fold) + deep * fold
    star_rgb = linear_gradient(size, scale, STAR, (600 + m.dx, 150 + m.dy), (800 + m.dx, 380 + m.dy))

    premul = np.zeros((size, size, 3))
    alpha = np.zeros((size, size))
    for rgb, a in ((band_rgb, a_band), (stem_rgb, a_stem), (band_rgb, a_head), (star_rgb, a_star)):
        premul = premul * (1 - a[..., None]) + rgb * a[..., None]
        alpha = alpha * (1 - a) + a
    rgb = premul / np.maximum(alpha, 1e-9)[..., None]
    return np.dstack([np.clip(rgb, 0, 1), np.clip(alpha, 0, 1)])


def on_white(rgba: np.ndarray) -> np.ndarray:
    a = rgba[..., 3:]
    return rgba[..., :3] * a + (1 - a)


def to_image(rgba: np.ndarray) -> Image.Image:
    return Image.fromarray((rgba * 255 + 0.5).astype(np.uint8), "RGBA")


def tile_icon(size: int, corner_ratio=0.225) -> Image.Image:
    """Full icon as a launcher shows it: white rounded square with the mark."""
    r = DESIGN * corner_ratio
    tile = coverage(box(r, r, DESIGN - r, DESIGN - r).buffer(r, quad_segs=32), size, size / DESIGN)
    mark_rgba = render_mark(size, DESIGN)
    rgb = on_white(mark_rgba)
    return to_image(np.dstack([rgb, tile]))


def monochrome_shape():
    m = mark((ADAPTIVE - DESIGN) / 2)
    gap = m.star.buffer(STAR_GAP)
    body = unary_union([m.band.poly, m.stem]).difference(gap)
    # Slits keep the ribbon structure legible once colour and shading are gone.
    fold_edge = LineString(m.band.inner[:FOLD_STATIONS]).buffer(MONO_SLIT, cap_style="flat")
    x = STEM_R + m.dx
    tuck_edge = LineString([(x, HEAD_Y + m.dy + 40), (x, 640 + m.dy)]).buffer(MONO_SLIT, cap_style="flat")
    body = body.difference(fold_edge).difference(tuck_edge.intersection(m.band.poly))
    return unary_union([body, m.star])


def vector_drawable(shape, tolerance=0.5) -> str:
    shape = shape.simplify(tolerance)
    polys = [shape] if shape.geom_type == "Polygon" else list(shape.geoms)
    parts = []
    for poly in polys:
        for ring in [poly.exterior, *poly.interiors]:
            xy = list(ring.coords)[:-1]
            parts.append("M" + "L".join(f"{x:.1f},{y:.1f}" for x, y in xy) + "Z")
    return (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        "<!-- Generated by tool/gen_app_icon.py; do not edit. -->\n"
        '<vector xmlns:android="http://schemas.android.com/apk/res/android"\n'
        '    android:width="108dp"\n'
        '    android:height="108dp"\n'
        f'    android:viewportWidth="{ADAPTIVE}"\n'
        f'    android:viewportHeight="{ADAPTIVE}">\n'
        "    <path\n"
        '        android:fillColor="#FFFFFFFF"\n'
        '        android:fillType="evenOdd"\n'
        f'        android:pathData="{"".join(parts)}" />\n'
        "</vector>\n"
    )


# ----------------------------------------------------------------- outputs --

DENSITIES = {"mdpi": 108, "hdpi": 162, "xhdpi": 216, "xxhdpi": 324, "xxxhdpi": 432}
ICO_SIZES = [16, 24, 32, 48, 64, 128, 256]
SPLASH_PX = 480  # 160dp at 3x; matches the Android 12+ system splash icon


def outputs() -> dict[Path, Image.Image | str]:
    out: dict[Path, Image.Image | str] = {}
    for density, px in DENSITIES.items():
        out[RES / f"mipmap-{density}/ic_launcher_foreground.png"] = to_image(render_mark(px, ADAPTIVE))
    out[RES / "drawable/ic_launcher_monochrome.xml"] = vector_drawable(monochrome_shape())
    big = to_image(render_mark(1024, DESIGN))
    out[ROOT / "assets/branding/parfait_icon.png"] = to_image(render_mark(SPLASH_PX, DESIGN))
    out[ROOT / "windows/runner/resources/app_icon.ico"] = big
    out[ROOT / ".github/branding/mark-1024.png"] = big
    out[ROOT / ".github/branding/icon-512.png"] = tile_icon(512)
    return out


def encode(path: Path, value: Image.Image | str) -> bytes:
    if isinstance(value, str):
        return value.encode()
    buf = io.BytesIO()
    if path.suffix == ".ico":
        value.save(buf, format="ICO", sizes=[(s, s) for s in ICO_SIZES])
    else:
        value.save(buf, format="PNG", optimize=True)
    return buf.getvalue()


def decoded_frames(data: bytes, path: Path) -> list[np.ndarray]:
    im = Image.open(io.BytesIO(data))
    if path.suffix == ".ico":
        return [np.asarray(im.ico.getimage((s, s)).convert("RGBA")) for s in ICO_SIZES]
    return [np.asarray(im.convert("RGBA"))]


def same(path: Path, expected: bytes) -> bool:
    if not path.exists():
        return False
    actual = path.read_bytes()
    if path.suffix == ".xml":
        return actual == expected
    a, b = decoded_frames(actual, path), decoded_frames(expected, path)
    return len(a) == len(b) and all(x.shape == y.shape and np.array_equal(x, y) for x, y in zip(a, b))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true", help="compare instead of writing")
    args = parser.parse_args()
    drift = []
    for path, value in outputs().items():
        data = encode(path, value)
        rel = path.relative_to(ROOT)
        if args.check:
            if not same(path, data):
                drift.append(rel)
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        print(f"wrote {rel} ({len(data)} B)")
    if drift:
        print("out of date (run tool/gen_app_icon.py):", *drift, sep="\n  ", file=sys.stderr)
        return 1
    if args.check:
        print("all icon outputs up to date")
    return 0


if __name__ == "__main__":
    sys.exit(main())
