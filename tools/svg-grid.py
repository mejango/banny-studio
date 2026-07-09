#!/usr/bin/env python3
"""Catalog SVG parser + deterministic grid->SVG emitter.

parse: rasterize a BannyAssets SVG at viewBox resolution (integer-aligned
edges -> pixel-exact, no AA) and build a palette-indexed grid from the
observed RGBA pixels (some assets use fill-opacity, so blended colors are
part of the palette; the declared fills are not the source of truth).
emit: palette-indexed grid -> clean rect-run SVG (greedy maximal rects,
fill-opacity re-emitted for non-opaque entries).
Round-trips all 124 catalog SVGs (parse -> emit -> re-rasterize -> compare)
and writes ml/dataset part-* training pairs + ml/catalog-palette.json.
"""
import json, re, subprocess, tempfile
from collections import Counter
from pathlib import Path
from PIL import Image

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
ROOT = Path(__file__).resolve().parent.parent
SVG_DIR = ROOT / "App/Resources/BannyAssets/svg"
DATASET = ROOT / "ml/dataset"


def rasterize(svg_text: str, w: int, h: int) -> Image.Image:
    """Headless-Chrome rasterize to RGBA. width/height attrs must match
    --window-size or Chrome renders at intrinsic size (see skill notes)."""
    svg_text = re.sub(
        r'(<svg[^>]*?) width="\d+" height="\d+"',
        rf'\1 width="{w}" height="{h}"',
        svg_text,
        count=1,
    )
    with tempfile.TemporaryDirectory() as td:
        src = Path(td) / "in.svg"
        out = Path(td) / "out.png"
        src.write_text(svg_text)
        cmd = [CHROME, "--headless", "--disable-gpu",
               "--default-background-color=00000000",
               f"--window-size={w},{h}", f"--screenshot={out}",
               f"file://{src}"]
        for attempt in range(3):  # headless Chrome occasionally hangs on launch
            try:
                subprocess.run(cmd, check=True, capture_output=True, timeout=30)
                break
            except subprocess.TimeoutExpired:
                if attempt == 2:
                    raise
        return Image.open(out).convert("RGBA")


def parse(svg_text: str):
    """-> (w, h, palette [(r,g,b,a)...], grid rows of index|-1, RGBA image).
    Palette order = first appearance in row-major scan (deterministic)."""
    vb = re.search(r'viewBox="0 0 (\d+) (\d+)"', svg_text)
    w, h = int(vb.group(1)), int(vb.group(2))
    img = rasterize(svg_text, w, h)
    px = img.load()
    palette, index = [], {}
    grid = []
    for y in range(h):
        row = []
        for x in range(w):
            r, g, b, a = px[x, y]
            if a == 0:
                row.append(-1)
                continue
            key = (r, g, b, a)
            if key not in index:
                index[key] = len(palette)
                palette.append(key)
            row.append(index[key])
        grid.append(row)
    return w, h, palette, grid, img


def emit(w: int, h: int, palette, grid) -> str:
    """Grid -> rect-run SVG. Greedy maximal rects, grouped per palette entry."""
    covered = [[False] * w for _ in range(h)]
    rects = [[] for _ in palette]  # per entry: (x, y, rw, rh)
    for y in range(h):
        for x in range(w):
            i = grid[y][x]
            if i < 0 or covered[y][x]:
                continue
            rw = 1
            while x + rw < w and grid[y][x + rw] == i and not covered[y][x + rw]:
                rw += 1
            rh = 1
            while y + rh < h and all(
                    grid[y + rh][x + k] == i and not covered[y + rh][x + k]
                    for k in range(rw)):
                rh += 1
            for yy in range(y, y + rh):
                for xx in range(x, x + rw):
                    covered[yy][xx] = True
            rects[i].append((x, y, rw, rh))
    style, groups = [], []
    for i, (r, g, b, a) in enumerate(palette):
        fill = f"fill:#{r:02x}{g:02x}{b:02x};"
        if a < 255:
            fill += f"fill-opacity:{a / 255:.6f};"
        style.append(f".c{i}{{{fill}}}")
        if not rects[i]:
            continue
        body = "".join(
            f'<rect x="{x}" y="{y}" width="{rw}" height="{rh}"/>'
            for x, y, rw, rh in rects[i])
        groups.append(f'<g class="c{i}">{body}</g>')
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" '
            f'viewBox="0 0 {w} {h}" shape-rendering="crispEdges">'
            f"<style>{''.join(style)}</style>{''.join(groups)}</svg>")


def caption(name: str) -> str:
    words = name.replace("@", " ").replace("-", " ")
    return f"bannyverse pixel art sprite, {words}, flat colors, white background"


def main():
    DATASET.mkdir(parents=True, exist_ok=True)
    colors = Counter()
    files = sorted(SVG_DIR.glob("*.svg"))
    for i, f in enumerate(files):
        w, h, palette, grid, img = parse(f.read_text())
        # round-trip check: emitted SVG must rasterize to the identical grid
        _, _, palette2, grid2, _ = parse(emit(w, h, palette, grid))
        assert grid2 == grid and palette2 == palette, f"round-trip failed: {f.name}"
        for row in grid:
            for idx in row:
                if idx >= 0:
                    r, g, b, a = palette[idx]
                    key = f"#{r:02x}{g:02x}{b:02x}" + (f"{a:02x}" if a < 255 else "")
                    colors[key] += 1
        # dataset pair: composite on white, nearest-neighbor to 512
        white = Image.new("RGBA", img.size, (255, 255, 255, 255))
        white.alpha_composite(img)
        out = white.convert("RGB").resize((512, 512), Image.NEAREST)
        name = f.stem
        out.save(DATASET / f"part-{name}.png")
        (DATASET / f"part-{name}.txt").write_text(caption(name))
        print(f"[{i + 1}/{len(files)}] {name} ok", flush=True)
    (ROOT / "ml/catalog-palette.json").write_text(
        json.dumps(dict(colors.most_common()), indent=1))
    print(f"done: {len(files)} round-tripped, palette {len(colors)} colors")


if __name__ == "__main__":
    main()
