#!/usr/bin/env python3
"""Generate the logo SVGs, app-icon PNGs and the index.html showcase.

    python3 Branding/generate.py

SVGs are written to Branding/logos/, rendered with macOS Quick Look (qlmanage)
and flattened to opaque RGB PNGs in Branding/icons/ at 1024, 180 and 60 px.
"""
import base64
import math
import random
import shutil
import subprocess
import tempfile
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent
LOGOS = ROOT / "logos"
ICONS = ROOT / "icons"

BG_TOP, BG_BOTTOM = "#0E1322", "#090B13"
CYAN, PERI, AMBER, RED = "#33E1FF", "#7389FF", "#FFBF40", "#FF5C4D"
DIM = "#1A2242"

# JS8's 7x7 Costas sync pattern (reference/js8call/lib/js8/genjs8.f90, icos7a)
COSTAS = [4, 2, 5, 6, 1, 3, 0]


def defs(extra=""):
    return f"""<defs>
  <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="{BG_TOP}"/><stop offset="1" stop-color="{BG_BOTTOM}"/>
  </linearGradient>
  <radialGradient id="halo" cx="0.5" cy="0.5" r="0.5">
    <stop offset="0" stop-color="{CYAN}" stop-opacity="0.16"/>
    <stop offset="1" stop-color="{CYAN}" stop-opacity="0"/>
  </radialGradient>
  <filter id="glow" x="-40%" y="-40%" width="180%" height="180%">
    <feGaussianBlur in="SourceGraphic" stdDeviation="16" result="b"/>
    <feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge>
  </filter>
  <filter id="softglow" x="-40%" y="-40%" width="180%" height="180%">
    <feGaussianBlur in="SourceGraphic" stdDeviation="8" result="b"/>
    <feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge>
  </filter>
  {extra}
</defs>"""


def svg(body, extra_defs="", halo=(512, 512, 420)):
    hx, hy, hr = halo
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
{defs(extra_defs)}
<rect width="1024" height="1024" fill="url(#bg)"/>
<circle cx="{hx}" cy="{hy}" r="{hr}" fill="url(#halo)"/>
{body}
</svg>
"""


def pts_to_path(pts, close=False):
    d = "M" + " L".join(f"{x:.1f},{y:.1f}" for x, y in pts)
    return d + (" Z" if close else "")


# ---------------------------------------------------------------- Eightfold
def eightfold():
    # A figure-8 that crosses at the waist: x = W*sin(2t), y = H*sin(t),
    # with rounder loops (|sin 2t|^0.8) and a smaller top loop, like a real 8.
    cx, cy = 512, 528
    pts = []
    for i in range(361):
        t = 2 * math.pi * i / 360
        s2 = math.sin(2 * t)
        x = cx + 212 * math.copysign(abs(s2) ** 0.8, s2)
        h = 300 if math.sin(t) > 0 else 270
        y = cy + h * math.sin(t)
        pts.append((x, y))
    eight = pts_to_path(pts, close=True)
    # faint waterfall tone lanes behind the 8
    lanes = []
    rnd = random.Random(8)
    for k in range(8):
        x = 168 + k * 98
        for j in range(26):
            if rnd.random() < 0.55:
                y = 120 + j * 30
                op = 0.05 + rnd.random() * 0.10
                lanes.append(f'<rect x="{x}" y="{y}" width="44" height="22" rx="4" fill="{PERI}" opacity="{op:.2f}"/>')
    grad = f"""<linearGradient id="eightg" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="{CYAN}"/><stop offset="1" stop-color="{PERI}"/></linearGradient>"""
    # a signal pulse riding the upper loop
    t = math.radians(-128)
    s2 = math.sin(2 * t)
    px = cx + 212 * math.copysign(abs(s2) ** 0.8, s2)
    py = cy + 270 * math.sin(t)
    body = "\n".join(lanes) + f"""
<path d="{eight}" fill="none" stroke="url(#eightg)" stroke-width="84" stroke-linejoin="round" filter="url(#glow)"/>
<circle cx="{px:.1f}" cy="{py:.1f}" r="40" fill="{AMBER}" filter="url(#softglow)"/>
<circle cx="{px:.1f}" cy="{py:.1f}" r="16" fill="#FFF3D6"/>"""
    return svg(body, grad)


# ---------------------------------------------------------------- Undernoise
def undernoise():
    rnd = random.Random(24)
    # jagged noise floor across the upper middle
    noise = [(-20, 520)]
    x = 0
    while x <= 1044:
        y = 470 - rnd.random() ** 2.2 * 230 - rnd.random() * 40
        noise.append((x, y))
        x += 26
    noise.append((1044, 520))
    floor_line = pts_to_path(noise[1:-1])
    floor_fill = pts_to_path(noise + [(1044, 1044), (-20, 1044)], close=True)
    # JS8 tone staircase, below the noise
    tones = [1, 3, 2, 5, 4, 6, 7]
    seg = 112
    x0 = 120
    step = []
    for i, tn in enumerate(tones):
        y = 820 - tn * 34
        step += [(x0 + i * seg, y), (x0 + (i + 1) * seg - 10, y)]
    sig = pts_to_path(step)
    grads = f"""<linearGradient id="nf" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="{PERI}" stop-opacity="0.38"/>
    <stop offset="0.55" stop-color="{PERI}" stop-opacity="0.06"/>
    <stop offset="1" stop-color="{PERI}" stop-opacity="0"/></linearGradient>"""
    body = f"""
<path d="{floor_fill}" fill="url(#nf)"/>
<path d="{floor_line}" fill="none" stroke="{PERI}" stroke-width="16" stroke-linejoin="round" opacity="0.85"/>
<path d="{sig}" fill="none" stroke="{CYAN}" stroke-width="54" stroke-linecap="round" stroke-linejoin="round" filter="url(#glow)"/>
<circle cx="{step[-1][0] + 4}" cy="{step[-1][1]}" r="22" fill="{AMBER}" filter="url(#softglow)"/>"""
    return svg(body, grads, halo=(512, 690, 380))


# ---------------------------------------------------------------- Costas
def costas():
    cell, size = 104, 80
    off = (1024 - 7 * cell) / 2 + (cell - size) / 2
    dots = []
    for col in range(7):
        for row in range(7):
            x, y = off + col * cell, off + row * cell
            lit = (6 - COSTAS[col]) == row
            if not lit:
                dots.append(f'<rect x="{x:.0f}" y="{y:.0f}" width="{size}" height="{size}" rx="18" fill="{DIM}"/>')
    lit_rects = []
    for col in range(7):
        row = 6 - COSTAS[col]
        x, y = off + col * cell, off + row * cell
        color = AMBER if col == 0 else CYAN
        lit_rects.append(f'<rect x="{x:.0f}" y="{y:.0f}" width="{size}" height="{size}" rx="18" fill="{color}"/>')
    body = "\n".join(dots) + '\n<g filter="url(#glow)">\n' + "\n".join(lit_rects) + "\n</g>"
    return svg(body)


# ---------------------------------------------------------------- Tonestep
def tonestep():
    bars = []
    w, h, gap = 82, 50, 10
    x0, ybase, rise = 100, 836, 62
    for i in range(8):
        x = x0 + i * (w + gap)
        y = ybase - i * rise
        bars.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="16" fill="url(#stairg)"/>')
    # radio arcs off the top step
    tx, ty = x0 + 7 * (w + gap) + w / 2, ybase - 7 * rise
    arcs = []
    for k, r in enumerate((80, 140, 200)):
        a0, a1 = math.radians(-140), math.radians(-40)
        sx, sy = tx + r * math.cos(a0), ty - 30 + r * math.sin(a0)
        ex, ey = tx + r * math.cos(a1), ty - 30 + r * math.sin(a1)
        op = 1.0 - k * 0.22
        arcs.append(f'<path d="M{sx:.1f},{sy:.1f} A{r},{r} 0 0 1 {ex:.1f},{ey:.1f}" fill="none" '
                    f'stroke="{AMBER}" stroke-width="36" stroke-linecap="round" opacity="{op:.2f}"/>')
    lanes = []
    for i in range(8):
        x = x0 + i * (w + gap) + w / 2
        lanes.append(f'<line x1="{x}" y1="140" x2="{x}" y2="910" stroke="{PERI}" stroke-width="4" '
                     f'stroke-dasharray="2 22" stroke-linecap="round" opacity="0.28"/>')
    grad = f"""<linearGradient id="stairg" x1="100" y1="890" x2="830" y2="370" gradientUnits="userSpaceOnUse">
    <stop offset="0" stop-color="{PERI}"/><stop offset="1" stop-color="{CYAN}"/></linearGradient>"""
    bars_svg = "\n".join(bars)
    body = ("\n".join(lanes) + '\n<g filter="url(#softglow)">\n' + "\n".join(arcs) + "\n</g>"
            + '\n<g filter="url(#glow)">\n' + bars_svg + "\n</g>")
    return svg(body, grad, halo=(560, 560, 440))


# ---------------------------------------------------------------- Pocket JS8
def pocket_js8():
    # chat bubble with a tail at bottom-left, tone staircase cut into it
    bx, by, bw, bh, r = 130, 300, 620, 460, 116
    bubble = (f"M{bx + r},{by} H{bx + bw - r} A{r},{r} 0 0 1 {bx + bw},{by + r} V{by + bh - r} "
              f"A{r},{r} 0 0 1 {bx + bw - r},{by + bh} H{bx + 250} L{bx + 90},{by + bh + 140} "
              f"L{bx + 120},{by + bh} H{bx + r} A{r},{r} 0 0 1 {bx},{by + bh - r} V{by + r} "
              f"A{r},{r} 0 0 1 {bx + r},{by} Z")
    bars = []
    w, h, gap = 54, 38, 12
    tones = [0, 2, 1, 3, 5, 4, 6, 7]
    sx = bx + (bw - (8 * w + 7 * gap)) / 2
    for i, tn in enumerate(tones):
        x = sx + i * (w + gap)
        y = by + bh - 120 - tn * 30
        bars.append(f'<rect x="{x:.0f}" y="{y}" width="{w}" height="{h}" rx="12" fill="{BG_BOTTOM}"/>')
    # radio arcs off the bubble's top-right corner
    cx, cy = bx + bw - 30, by + 30
    arcs = []
    for k, rr in enumerate((80, 140, 200)):
        a0, a1 = math.radians(-80), math.radians(-10)
        p0 = (cx + rr * math.cos(a0), cy + rr * math.sin(a0))
        p1 = (cx + rr * math.cos(a1), cy + rr * math.sin(a1))
        arcs.append(f'<path d="M{p0[0]:.1f},{p0[1]:.1f} A{rr},{rr} 0 0 1 {p1[0]:.1f},{p1[1]:.1f}" fill="none" '
                    f'stroke="{AMBER}" stroke-width="34" stroke-linecap="round" opacity="{1 - k * 0.2:.2f}"/>')
    grad = f"""<linearGradient id="bub" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0" stop-color="{CYAN}"/><stop offset="1" stop-color="#4FB4FF"/></linearGradient>"""
    body = (f'<path d="{bubble}" fill="url(#bub)" filter="url(#glow)"/>\n' + "\n".join(bars)
            + '\n<g filter="url(#softglow)">\n' + "\n".join(arcs) + "\n</g>")
    return svg(body, grad, halo=(460, 540, 430))


CONCEPTS = [
    ("eightfold", "Eightfold", eightfold,
     "JS8 is 8-tone FSK. A single glowing figure-8 with a signal pulse riding the loop; "
     "owns the \"8\" without borrowing the JS8Call name.",
     "Recommended"),
    ("undernoise", "Undernoise", undernoise,
     "JS8 decodes around −24 dB SNR, below the noise floor. A jagged noise floor on top, "
     "the clean JS8 tone staircase gliding underneath it.",
     "Runner-up"),
    ("costas", "Costas", costas,
     "Every JS8 frame starts with a 7×7 Costas array (4 2 5 6 1 3 0) for sync. "
     "This is that exact pattern, lit up; the most legible icon at 60 px.",
     ""),
    ("tonestep", "Tonestep", tonestep,
     "The 8 FSK tones as a staircase climbing the waterfall lanes, transmitting from the top step.",
     ""),
    ("pocket-js8", "Pocket JS8", pocket_js8,
     "A chat bubble with the tone staircase cut into it and radio waves off the corner: "
     "keyboard-to-keyboard chat over HF. The safe descriptive option.",
     "Descriptive"),
]


def render(svg_path, png_path):
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(["qlmanage", "-t", "-s", "1024", "-o", tmp, str(svg_path)],
                       check=True, capture_output=True)
        out = Path(tmp) / (svg_path.name + ".png")
        im = Image.open(out).convert("RGBA")
    if im.size != (1024, 1024):
        im = im.resize((1024, 1024), Image.LANCZOS)
    flat = Image.new("RGB", im.size, BG_BOTTOM)
    flat.paste(im, mask=im.split()[3])
    flat.save(png_path, optimize=True)
    for s in (180, 60):
        flat.resize((s, s), Image.LANCZOS).save(png_path.with_name(png_path.name.replace("-1024", f"-{s}")))


def data_uri(p):
    return "data:image/png;base64," + base64.b64encode(p.read_bytes()).decode()


def build_index():
    cards = []
    for slug, name, _, why, tag in CONCEPTS:
        big = data_uri(ICONS / f"{slug}-1024.png")
        i180 = data_uri(ICONS / f"{slug}-180.png")
        i60 = data_uri(ICONS / f"{slug}-60.png")
        badge = f'<span class="tag">{tag}</span>' if tag else ""
        cards.append(f"""
<section class="card">
  <div class="head"><h2>{name}</h2>{badge}</div>
  <p class="why">{why}</p>
  <div class="row">
    <figure class="big"><img src="{big}" width="1024" height="1024" alt="{name} icon at 1024 px"><figcaption>1024 px (scaled to fit)</figcaption></figure>
    <div class="smalls">
      <div class="pair dark">
        <figure><img class="ios" src="{i180}" width="180" height="180" alt=""><figcaption>180</figcaption></figure>
        <figure><img class="ios" src="{i60}" width="60" height="60" alt=""><figcaption>60</figcaption></figure>
        <span class="lbl">dark</span>
      </div>
      <div class="pair light">
        <figure><img class="ios" src="{i180}" width="180" height="180" alt=""><figcaption>180</figcaption></figure>
        <figure><img class="ios" src="{i60}" width="60" height="60" alt=""><figcaption>60</figcaption></figure>
        <span class="lbl">light</span>
      </div>
    </div>
  </div>
</section>""")
    strip = "".join(
        f'<figure><img class="ios" src="{data_uri(ICONS / f"{s}-60.png")}" width="60" height="60" alt=""><figcaption>{n}</figcaption></figure>'
        for s, n, *_ in CONCEPTS)
    html = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>JS8 App Icons</title>
<style>
:root {{
  --bg: #090B13; --panel: #0E1322; --line: #1E2640; --text: #E6ECFF; --muted: #8C97C2;
  --cyan: #33E1FF; --amber: #FFBF40; --light: #F2F3F7; --lighttext: #4A5068;
}}
* {{ box-sizing: border-box; }}
body {{ margin: 0; background: var(--bg); color: var(--text);
  font: 15px/1.5 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif; }}
main {{ max-width: 1180px; margin: 0 auto; padding: 32px 16px 64px; }}
h1 {{ font-size: 26px; margin: 0 0 4px; letter-spacing: .2px; }}
.sub {{ color: var(--muted); margin: 0 0 24px; }}
.strip {{ display: flex; flex-wrap: wrap; gap: 20px; padding: 18px; background: var(--panel);
  border: 1px solid var(--line); border-radius: 16px; margin-bottom: 28px; }}
.strip figure {{ margin: 0; text-align: center; }}
.strip figcaption {{ font-size: 12px; color: var(--muted); margin-top: 6px; }}
.card {{ background: var(--panel); border: 1px solid var(--line); border-radius: 18px;
  padding: 22px; margin-bottom: 24px; }}
.head {{ display: flex; align-items: center; gap: 12px; }}
h2 {{ margin: 0; font-size: 22px; }}
.tag {{ font-size: 12px; font-weight: 600; color: #0E1322; background: var(--amber);
  border-radius: 999px; padding: 2px 10px; }}
.why {{ color: var(--muted); margin: 6px 0 18px; max-width: 70ch; }}
.row {{ display: grid; grid-template-columns: minmax(0, 1fr) auto; gap: 22px; align-items: start; }}
figure {{ margin: 0; }}
figcaption {{ font: 12px ui-monospace, "SF Mono", Menlo, monospace; color: var(--muted); margin-top: 6px; text-align: center; }}
.big img {{ width: 100%; height: auto; max-width: 1024px; display: block; border-radius: 12px; }}
.ios {{ border-radius: 22.4%; display: block; }}
.smalls {{ display: flex; flex-direction: column; gap: 14px; }}
.pair {{ position: relative; display: flex; align-items: flex-end; gap: 22px; padding: 22px 22px 14px;
  border-radius: 14px; }}
.pair.dark {{ background: #000; }}
.pair.light {{ background: var(--light); }}
.pair.light figcaption {{ color: var(--lighttext); }}
.pair.light .ios {{ box-shadow: 0 1px 3px rgba(0,0,0,.18); }}
.lbl {{ position: absolute; top: 8px; right: 12px; font-size: 11px; text-transform: uppercase;
  letter-spacing: 1px; color: var(--muted); }}
.pair.light .lbl {{ color: var(--lighttext); }}
@media (max-width: 760px) {{
  .row {{ grid-template-columns: 1fr; }}
  .pair {{ justify-content: center; }}
  .pair img[width="180"] {{ width: 120px; height: 120px; }}
}}
</style>
</head>
<body>
<main>
<h1>App icon concepts</h1>
<p class="sub">Five names and icons for the native JS8 client. Icons are opaque 1024 px PNGs (iOS masks the corners; the rounded previews here imitate that). Full name list and conflict notes: <code>NAMES.md</code>.</p>
<div class="strip">{strip}</div>
{''.join(cards)}
</main>
</body>
</html>
"""
    (ROOT / "index.html").write_text(html)


def main():
    LOGOS.mkdir(exist_ok=True)
    ICONS.mkdir(exist_ok=True)
    assert shutil.which("qlmanage"), "needs macOS qlmanage to rasterize SVG"
    for slug, _, fn, *_ in CONCEPTS:
        p = LOGOS / f"{slug}.svg"
        p.write_text(fn())
        render(p, ICONS / f"{slug}-1024.png")
        print("wrote", p.name, f"{slug}-1024.png")
    build_index()
    print("wrote index.html")


if __name__ == "__main__":
    main()
