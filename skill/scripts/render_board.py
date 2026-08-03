#!/usr/bin/env python3
"""PitBoard fallback renderer — pure Python/PIL, no browser needed.

Use when Chromium/Playwright is unavailable (local VMs, minimal sandboxes).
Fidelity is approximate but fully readable: strokes, shapes+labels, arrows,
text, images (loaded from the repo clone), alpha.

Usage:
  python3 render_board.py <board.json> <out.png> [x0 y0 x1 y1] [--repo DIR]
    no region: auto-fit all content.  --repo: clone root, for image files.
"""
import json
import math
import os
import sys

from PIL import Image, ImageDraw, ImageFont

BG = (0x14, 0x17, 0x1D)
INK = (0xF2, 0xF4, 0xF8)


def color(c, alpha=255):
    if not c or c == "ink":
        return INK + (alpha,)
    try:
        v = int(c.lstrip("#"), 16)
        return ((v >> 16) & 255, (v >> 8) & 255, v & 255, alpha)
    except ValueError:
        return INK + (alpha,)


def font(size):
    for p in ("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
              "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
              "/System/Library/Fonts/Helvetica.ttc"):
        try:
            return ImageFont.truetype(p, max(8, int(size)))
        except OSError:
            continue
    return ImageFont.load_default()


def bbox(el):
    t = el.get("type")
    if t == "stroke":
        xs = [p[0] for p in el.get("points", [])]
        ys = [p[1] for p in el.get("points", [])]
        return (min(xs), min(ys), max(xs), max(ys)) if xs else (0, 0, 0, 0)
    if t in ("line", "arrow"):
        return (min(el["x1"], el["x2"]), min(el["y1"], el["y2"]),
                max(el["x1"], el["x2"]), max(el["y1"], el["y2"]))
    x, y = el.get("x", 0), el.get("y", 0)
    if t == "text":
        return (x, y, x + len(el.get("text", "")) * el.get("fontSize", 17) * 0.55,
                y + el.get("fontSize", 17) * 1.3)
    return (x, y, x + abs(el.get("w", 100)), y + abs(el.get("h", 50)))


def render(board_path, out_path, region=None, repo_dir=None):
    d = json.load(open(board_path))
    els = d["elements"]
    if region:
        x0, y0, x1, y1 = region
    else:
        boxes = [bbox(e) for e in els] or [(0, 0, 1500, 1000)]
        x0 = min(b[0] for b in boxes) - 30
        y0 = min(b[1] for b in boxes) - 30
        x1 = max(b[2] for b in boxes) + 30
        y1 = max(b[3] for b in boxes) + 30
    W = 1600
    s = min(W / max(1, x1 - x0), 1200 / max(1, y1 - y0), 1.6)
    H = int((y1 - y0) * s) + 1

    img = Image.new("RGBA", (int((x1 - x0) * s) + 1, H), BG + (255,))

    def T(x, y):
        return ((x - x0) * s, (y - y0) * s)

    for el in els:
        layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
        dr = ImageDraw.Draw(layer)
        t = el.get("type")
        a = int(255 * el.get("alpha", 1.0))
        col = color(el.get("color"), a)
        wdt = max(1, int(el.get("size", 3) * s))

        if t == "stroke":
            pts = [T(p[0], p[1]) for p in el.get("points", [])]
            if len(pts) >= 2:
                dr.line(pts, fill=col, width=wdt, joint="curve")
            elif pts:
                r = wdt
                dr.ellipse([pts[0][0]-r, pts[0][1]-r, pts[0][0]+r, pts[0][1]+r], fill=col)
        elif t in ("rect", "ellipse", "diamond", "image"):
            x, y = el.get("x", 0), el.get("y", 0)
            w, h = el.get("w", 100), el.get("h", 50)
            if w < 0: x, w = x + w, -w
            if h < 0: y, h = y + h, -h
            p0, p1 = T(x, y), T(x + w, y + h)
            box = [p0[0], p0[1], p1[0], p1[1]]
            if t == "image":
                drawn = False
                src = el.get("src")
                if repo_dir and src:
                    fp = os.path.join(repo_dir, src)
                    if os.path.exists(fp):
                        try:
                            pic = Image.open(fp).convert("RGBA")
                            pic = pic.resize((max(1, int(box[2]-box[0])), max(1, int(box[3]-box[1]))))
                            if a < 255:
                                pic.putalpha(pic.getchannel("A").point(lambda v: v * a // 255))
                            layer.alpha_composite(pic, (int(box[0]), int(box[1])))
                            drawn = True
                        except Exception:
                            pass
                if not drawn:
                    dr.rectangle(box, outline=(90, 100, 116, 255), width=2)
                    dr.text(((box[0]+box[2])/2, (box[1]+box[3])/2), "image",
                            fill=(90, 100, 116, 255), font=font(14*s), anchor="mm")
            else:
                fill = color(el.get("color"), max(10, a // 10))
                if t == "rect":
                    dr.rounded_rectangle(box, radius=8*s, fill=fill, outline=col, width=wdt)
                elif t == "ellipse":
                    dr.ellipse(box, fill=fill, outline=col, width=wdt)
                else:
                    cx, cy = (box[0]+box[2])/2, (box[1]+box[3])/2
                    dr.polygon([(cx, box[1]), (box[2], cy), (cx, box[3]), (box[0], cy)],
                               fill=fill, outline=col, width=wdt)
                if el.get("label"):
                    dr.text(((box[0]+box[2])/2, (box[1]+box[3])/2), el["label"],
                            fill=INK + (255,), font=font(16 * s), anchor="mm")
        elif t in ("line", "arrow"):
            p0, p1 = T(el["x1"], el["y1"]), T(el["x2"], el["y2"])
            dr.line([p0, p1], fill=col, width=wdt)
            if t == "arrow":
                ang = math.atan2(p1[1]-p0[1], p1[0]-p0[0])
                L = (6 + el.get("size", 3) * 2.4) * s
                for da in (-0.46, 0.46):
                    dr.line([p1, (p1[0] - L*math.cos(ang+da), p1[1] - L*math.sin(ang+da))],
                            fill=col, width=wdt)
        elif t == "text":
            dr.text(T(el.get("x", 0), el.get("y", 0)), el.get("text", ""),
                    fill=col, font=font(el.get("fontSize", 17) * s), anchor="la")

        img = Image.alpha_composite(img, layer)

    img.convert("RGB").save(out_path)
    print(f"rendered {out_path} ({img.size[0]}x{img.size[1]}, scale {s:.2f})")


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--repo")]
    repo = None
    for i, a in enumerate(sys.argv):
        if a == "--repo" and i + 1 < len(sys.argv):
            repo = sys.argv[i + 1]
            args = [x for x in args if x != repo]
    if len(args) < 2:
        print(__doc__)
        sys.exit(1)
    region = tuple(map(float, args[2:6])) if len(args) >= 6 else None
    if repo is None:
        repo = os.path.dirname(os.path.abspath(args[0])) or "."
        if os.path.basename(repo) == "boards":
            repo = os.path.dirname(repo)
    render(args[0], args[1], region, repo)
