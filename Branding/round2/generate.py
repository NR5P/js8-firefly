"""Round-2 icon concepts: Wren, Lantern, Firefly, Skip, Murmur.

Run: python3 Branding/round2/generate.py
Writes <name>-1024.png icons and sheet.png (comparison sheet) next to this file.
"""
import math
import os
import random

from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
S = 2048  # draw at 2x, downsample for anti-aliasing

CYAN = (51, 225, 255)
PERI = (115, 137, 255)
AMBER = (255, 191, 64)
RED = (255, 92, 77)
WHITE = (240, 246, 255)


def background():
    img = Image.new("RGBA", (S, S))
    px = img.load()
    for y in range(S):
        t = y / S
        c = (int(9 + 6 * t), int(11 + 10 * t), int(19 + 16 * t), 255)
        for x in range(S):
            px[x, y] = c
    # soft vignette glow in the centre
    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse([S * 0.15, S * 0.12, S * 0.85, S * 0.82], fill=(40, 70, 140, 70))
    glow = glow.filter(ImageFilter.GaussianBlur(220))
    return Image.alpha_composite(img, glow)


def layer():
    return Image.new("RGBA", (S, S), (0, 0, 0, 0))


def glow_paste(base, lyr, radius=40, strength=1):
    out = base
    for _ in range(strength):
        out = Image.alpha_composite(out, lyr.filter(ImageFilter.GaussianBlur(radius)))
    return Image.alpha_composite(out, lyr)


def staircase(d, x0, y0, step_w, step_h, tones, color, width):
    pts = []
    x = x0
    for t in tones:
        y = y0 - t * step_h
        pts += [(x, y), (x + step_w, y)]
        x += step_w
    d.line(pts, fill=color, width=width, joint="curve")


def waterfall_streaks(d, seed, alpha=60):
    random.seed(seed)
    for k in range(10):
        x0 = 120 + k * 190 + random.randint(-40, 40)
        w = random.randint(26, 50)
        for y in range(0, S, 14):
            if random.random() < 0.55:
                a = int(alpha * (0.4 + random.random()))
                d.rectangle([x0 + random.randint(-5, 5), y, x0 + w, y + 8], fill=(*CYAN, a))


def wren():
    img = background()
    lyr = layer()
    d = ImageDraw.Draw(lyr)
    # FSK staircase "branch" the bird perches on
    staircase(d, 260, 1500, 190, 46, [1, 3, 2, 5, 4, 6, 3, 7], CYAN + (255,), 34)
    bird = layer()
    b = ImageDraw.Draw(bird)
    # body
    b.ellipse([700, 820, 1360, 1300], fill=AMBER + (255,))
    # head
    b.ellipse([1180, 660, 1520, 1000], fill=AMBER + (255,))
    # cocked tail (classic wren pose)
    b.polygon([(720, 1080), (480, 560), (600, 470), (760, 520), (960, 920)], fill=AMBER + (255,))
    # beak
    b.polygon([(1500, 800), (1660, 850), (1500, 880)], fill=(255, 225, 150, 255))
    # wing
    b.pieslice([820, 880, 1280, 1240], 200, 340, fill=(214, 140, 40, 255))
    # eye
    b.ellipse([1370, 770, 1420, 820], fill=(12, 15, 26, 255))
    # legs to the branch
    b.line([(1000, 1290), (980, 1400)], fill=AMBER + (255,), width=20)
    b.line([(1120, 1290), (1140, 1400)], fill=AMBER + (255,), width=20)
    img = glow_paste(img, lyr, 30)
    img = glow_paste(img, bird, 50)
    # sound arcs from the beak
    arcs = layer()
    a = ImageDraw.Draw(arcs)
    for i, r in enumerate([120, 220, 320]):
        a.arc([1600 - r, 840 - r, 1600 + r, 840 + r], -40, 40, fill=CYAN + (255,), width=30 - i * 6)
    return glow_paste(img, arcs, 30)


def lantern():
    img = background()
    rays = layer()
    r = ImageDraw.Draw(rays)
    cx, cy = 1024, 1120
    for i, rad in enumerate([520, 680, 840]):
        r.arc([cx - rad, cy - rad, cx + rad, cy + rad], 160, 200, fill=CYAN + (255,), width=34 - 8 * i)
        r.arc([cx - rad, cy - rad, cx + rad, cy + rad], -20, 20, fill=CYAN + (255,), width=34 - 8 * i)
    img = glow_paste(img, rays, 30)
    core = layer()
    c = ImageDraw.Draw(core)
    c.ellipse([cx - 230, cy - 300, cx + 230, cy + 260], fill=AMBER + (255,))
    img = glow_paste(img, core, 140, 2)
    body = layer()
    b = ImageDraw.Draw(body)
    frame = (205, 215, 235, 255)
    # handle
    b.arc([cx - 170, 330, cx + 170, 670], 180, 360, fill=frame, width=46)
    # cap
    b.polygon([(cx - 300, 640), (cx + 300, 640), (cx + 220, 520), (cx - 220, 520)], fill=frame)
    # glass outline
    b.rounded_rectangle([cx - 330, 640, cx + 330, 1600], radius=120, outline=frame, width=46)
    # base
    b.rounded_rectangle([cx - 380, 1580, cx + 380, 1700], radius=40, fill=frame)
    # flame: small FSK staircase inside the glass
    staircase(b, cx - 200, 1250, 50, 30, [0, 2, 1, 4, 3, 5, 2, 6], (255, 250, 230, 255), 22)
    return Image.alpha_composite(img, body)


def firefly():
    img = background()
    wf = layer()
    waterfall_streaks(ImageDraw.Draw(wf), 7, 55)
    img = Image.alpha_composite(img, wf)
    trail = layer()
    t = ImageDraw.Draw(trail)
    # descending JS8 tone trail of fading dots
    random.seed(3)
    x, y = 360, 1650
    tones = [0, 2, 1, 4, 3, 5, 6, 4, 7]
    for i, tone in enumerate(tones):
        px = 360 + i * 120
        py = 1700 - tone * 70 - i * 70
        a = int(60 + 190 * i / len(tones))
        rr = 18 + i * 3
        t.ellipse([px - rr, py - rr, px + rr, py + rr], fill=AMBER + (a,))
    img = glow_paste(img, trail, 25)
    fly = layer()
    f = ImageDraw.Draw(fly)
    cx, cy = 1400, 760
    f.ellipse([cx - 190, cy - 190, cx + 190, cy + 190], fill=(255, 230, 120, 255))
    img = glow_paste(img, fly, 160, 3)
    body = layer()
    b = ImageDraw.Draw(body)
    # translucent wings swept back from the glowing body
    for angle, dx in [(35, -1), (-35, 1)]:
        wing = Image.new("RGBA", (520, 200), (0, 0, 0, 0))
        ImageDraw.Draw(wing).ellipse([0, 0, 519, 199], fill=(190, 225, 255, 95))
        wing = wing.rotate(angle, expand=True, resample=Image.BICUBIC)
        wx = cx + dx * 150 - wing.width // 2
        wy = cy - 200 - wing.height // 2
        body.alpha_composite(wing, (int(wx), int(wy)))
    b.ellipse([cx - 110, cy - 110, cx + 110, cy + 110], fill=(255, 250, 220, 255))
    return Image.alpha_composite(img, body)


def skip():
    img = background()
    geo = layer()
    g = ImageDraw.Draw(geo)
    # Earth (bottom) and ionosphere (top) arcs
    g.ellipse([-1200, 1500, S + 1200, 4400], fill=(22, 40, 78, 255))
    g.arc([-1600, 300, S + 1600, 5200], 200, 340, fill=PERI + (200,), width=26)
    img = Image.alpha_composite(img, geo)
    path = layer()
    p = ImageDraw.Draw(path)
    pts = [(260, 1560), (720, 520), (1180, 1560), (1640, 520), (1860, 900)]
    p.line(pts, fill=CYAN + (255,), width=58, joint="curve")
    img = glow_paste(img, path, 50, 2)
    dots = layer()
    q = ImageDraw.Draw(dots)
    for (x, y), col in [((260, 1560), AMBER), ((1180, 1560), CYAN), ((1860, 900), RED)]:
        q.ellipse([x - 70, y - 70, x + 70, y + 70], fill=col + (255,))
    return glow_paste(img, dots, 40)


def murmur():
    img = background()
    bub = layer()
    b = ImageDraw.Draw(bub)
    b.rounded_rectangle([300, 420, 1750, 1420], radius=300, outline=PERI + (255,), width=60)
    b.polygon([(560, 1360), (470, 1700), (840, 1400)], fill=PERI + (255,))
    img = glow_paste(img, bub, 40)
    wave = layer()
    w = ImageDraw.Draw(wave)
    # quiet sine that grows into a staircase: "a murmur that gets through"
    pts = []
    for i in range(0, 700):
        x = 480 + i
        amp = 30 + i * 0.12
        pts.append((x, 920 + amp * math.sin(i / 28)))
    w.line(pts, fill=CYAN + (255,), width=30)
    staircase(w, 1180, 1080, 60, 40, [0, 3, 1, 5, 4, 7, 6], CYAN + (255,), 30)
    return glow_paste(img, wave, 30, 2)


ICONS = [
    ("JS8 Wren", wren, "Small bird, big voice: QRP that carries"),
    ("JS8 Lantern", lantern, "A light others find in the dark"),
    ("JS8 Hop", skip, "Your signal hopping off the ionosphere"),
    ("JS8 Firefly", firefly, "A tiny glow blinking across the waterfall"),
    ("JS8 Chat", murmur, "Keyboard-to-keyboard, under the noise"),
]


def with_wordmark(art):
    """Shrink the artwork slightly and add a bold "JS8" wordmark below it."""
    base = background()
    scale = 0.80
    size = int(S * scale)
    small = art.resize((size, size), Image.LANCZOS)
    feather = Image.new("L", (size, size), 0)
    ImageDraw.Draw(feather).rounded_rectangle([60, 60, size - 60, size - 60], radius=260, fill=255)
    feather = feather.filter(ImageFilter.GaussianBlur(60))
    base.paste(small, ((S - size) // 2, 40), feather)
    try:
        font = ImageFont.truetype("/System/Library/Fonts/SFNSRounded.ttf", 300)
    except OSError:
        font = ImageFont.load_default()
    text = layer()
    t = ImageDraw.Draw(text)
    tw = t.textlength("JS8", font=font)
    t.text(((S - tw) / 2, 1620), "JS8", font=font, fill=WHITE + (255,))
    if hasattr(font, "set_variation_by_name"):
        try:
            font.set_variation_by_name("Bold")
        except Exception:
            pass
    return glow_paste(base, text, 30)


def main():
    rendered = []
    for name, fn, tag in ICONS:
        im = with_wordmark(fn()).convert("RGB").resize((1024, 1024), Image.LANCZOS)
        path = os.path.join(HERE, f"{name.lower().replace(' ', '-')}-1024.png")
        im.save(path)
        rendered.append((name, tag, im))

    # Comparison sheet: rounded icons at 360 px + 60 px preview + name.
    W, H = 2200, 760
    sheet = Image.new("RGB", (W, H), (9, 11, 19))
    d = ImageDraw.Draw(sheet)
    try:
        fbig = ImageFont.truetype("/System/Library/Fonts/SFNSRounded.ttf", 56)
        fsm = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 28)
    except OSError:
        fbig = fsm = ImageFont.load_default()
    mask = Image.new("L", (360, 360), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, 359, 359], radius=80, fill=255)
    mask60 = Image.new("L", (60, 60), 0)
    ImageDraw.Draw(mask60).rounded_rectangle([0, 0, 59, 59], radius=13, fill=255)
    for i, (name, tag, im) in enumerate(rendered):
        x = 60 + i * 430
        sheet.paste(im.resize((360, 360), Image.LANCZOS), (x, 80), mask)
        sheet.paste(im.resize((60, 60), Image.LANCZOS), (x + 150, 470), mask60)
        tw = d.textlength(name, font=fbig)
        d.text((x + 180 - tw / 2, 560), name, font=fbig, fill=(240, 246, 255))
        words = tag
        tw2 = d.textlength(words, font=fsm)
        if tw2 > 400:
            mid = words.rfind(" ", 0, len(words) // 2 + 6)
            lines = [words[:mid], words[mid + 1:]]
        else:
            lines = [words]
        for j, ln in enumerate(lines):
            lw = d.textlength(ln, font=fsm)
            d.text((x + 180 - lw / 2, 640 + j * 36), ln, font=fsm, fill=(140, 150, 175))
    sheet.save(os.path.join(HERE, "sheet.png"))


if __name__ == "__main__":
    main()
