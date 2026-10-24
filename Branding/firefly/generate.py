"""JS8 Firefly icon variations.

Run: python3 Branding/firefly/generate.py
Writes firefly-<variant>-1024.png and sheet.png next to this file.
"""
import math
import os
import random

from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
S = 2048

CYAN = (51, 225, 255)
PERI = (115, 137, 255)
AMBER = (255, 191, 64)
GLOW = (214, 255, 92)      # firefly yellow-green
GLOW_HOT = (250, 255, 205)
WHITE = (240, 246, 255)
NAVY = (9, 11, 19)


def font(size, bold=True):
    for path in ["/System/Library/Fonts/SFNSRounded.ttf", "/System/Library/Fonts/SFNS.ttf"]:
        try:
            f = ImageFont.truetype(path, size)
            if bold:
                try:
                    f.set_variation_by_name("Bold")
                except Exception:
                    pass
            return f
        except OSError:
            continue
    return ImageFont.load_default()


def background(top=(9, 11, 19), bottom=(15, 21, 38), glow=(40, 70, 140, 70)):
    img = Image.new("RGBA", (S, S))
    d = ImageDraw.Draw(img)
    for y in range(S):
        t = y / S
        c = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        d.line([(0, y), (S, y)], fill=c + (255,))
    if glow:
        g = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        ImageDraw.Draw(g).ellipse([S * 0.15, S * 0.12, S * 0.85, S * 0.82], fill=glow)
        img = Image.alpha_composite(img, g.filter(ImageFilter.GaussianBlur(220)))
    return img


def layer():
    return Image.new("RGBA", (S, S), (0, 0, 0, 0))


def glow_paste(base, lyr, radius=40, strength=1):
    out = base
    for _ in range(strength):
        out = Image.alpha_composite(out, lyr.filter(ImageFilter.GaussianBlur(radius)))
    return Image.alpha_composite(out, lyr)


def firefly(img, cx, cy, scale=1.0, angle=-30, glow_strength=3):
    """A stylised firefly: dark body, two translucent wings, glowing tail.
    `angle` tilts the bug (degrees, 0 = head up). Drawn on a canvas large
    enough that rotation never clips the wings."""
    u = scale
    sz = int(1500 * u)
    c = sz / 2
    oy = 80 * u  # shift so the bug's visual centre sits at (cx, cy)

    def canvas():
        return Image.new("RGBA", (sz, sz), (0, 0, 0, 0))

    bug = canvas()
    # wings: leaf shapes angled out from the thorax
    for side in (-1, 1):
        ww, wh = int(250 * u), int(520 * u)
        wing = Image.new("RGBA", (ww, wh), (0, 0, 0, 0))
        ImageDraw.Draw(wing).ellipse([0, 0, ww - 1, wh - 1], fill=(185, 220, 255, 115))
        wing = wing.rotate(-side * 32, expand=True, resample=Image.BICUBIC)
        bug.alpha_composite(wing, (int(c + side * 150 * u - wing.width / 2), int(c - 120 * u - oy - wing.height / 2)))
    b = ImageDraw.Draw(bug)
    # thorax, head, antennae
    b.ellipse([c - 95 * u, c - 330 * u - oy, c + 95 * u, c - 90 * u - oy], fill=(36, 44, 70, 255))
    b.ellipse([c - 72 * u, c - 440 * u - oy, c + 72 * u, c - 300 * u - oy], fill=(255, 120, 90, 255))
    b.line([(c - 30 * u, c - 420 * u - oy), (c - 120 * u, c - 520 * u - oy)], fill=(170, 185, 220, 255), width=max(2, int(16 * u)))
    b.line([(c + 30 * u, c - 420 * u - oy), (c + 120 * u, c - 520 * u - oy)], fill=(170, 185, 220, 255), width=max(2, int(16 * u)))

    tail = canvas()
    ImageDraw.Draw(tail).ellipse([c - 125 * u, c - 130 * u - oy, c + 125 * u, c + 270 * u - oy], fill=GLOW + (255,))
    core = canvas()
    ImageDraw.Draw(core).ellipse([c - 78 * u, c - 70 * u - oy, c + 78 * u, c + 210 * u - oy], fill=GLOW_HOT + (255,))

    bug, tail, core = (im.rotate(angle, resample=Image.BICUBIC) for im in (bug, tail, core))
    pos = (int(cx - c), int(cy - c + oy))

    def placed(im):
        out = layer()
        out.paste(im, pos, im)
        return out

    halo = placed(tail)
    for r in (230 * u, 95 * u)[: max(1, min(2, glow_strength - 1))]:
        img = Image.alpha_composite(img, halo.filter(ImageFilter.GaussianBlur(r)))
    img = Image.alpha_composite(img, placed(bug))
    img = Image.alpha_composite(img, halo)
    return Image.alpha_composite(img, placed(core))


def tone_trail(d, start, step, tones, color, r0=14, r1=34, fade=True):
    """Dots following a JS8 8-FSK tone sequence."""
    x0, y0 = start
    dx, dy = step
    n = len(tones)
    for i, t in enumerate(tones):
        x = x0 + i * dx
        y = y0 + i * dy - t * 46
        a = int(70 + 185 * i / max(1, n - 1)) if fade else 255
        r = r0 + (r1 - r0) * i / max(1, n - 1)
        d.ellipse([x - r, y - r, x + r, y + r], fill=color + (a,))


def wordmark(img, y=1660, size=290, color=WHITE):
    lyr = layer()
    d = ImageDraw.Draw(lyr)
    f = font(size)
    tw = d.textlength("JS8", font=f)
    d.text(((S - tw) / 2, y), "JS8", font=f, fill=color + (255,))
    return glow_paste(img, lyr, 24)


TONES = [4, 2, 5, 6, 1, 3, 0, 5, 7, 3, 6]


# --- Variants ---------------------------------------------------------------

def v_classic():
    """Firefly flying up a JS8 tone trail over a faint waterfall."""
    img = background()
    wf = layer()
    d = ImageDraw.Draw(wf)
    random.seed(7)
    for k in range(11):
        x0 = 90 + k * 180 + random.randint(-30, 30)
        w = random.randint(24, 46)
        for y in range(0, S, 14):
            if random.random() < 0.5:
                d.rectangle([x0, y, x0 + w, y + 8], fill=CYAN + (int(30 + 40 * random.random()),))
    img = Image.alpha_composite(img, wf)
    trail = layer()
    tone_trail(ImageDraw.Draw(trail), (300, 1500), (95, -62), TONES[:9], GLOW)
    img = glow_paste(img, trail, 26)
    img = firefly(img, 1400, 760, 1.05, -35)
    return wordmark(img)


def v_figure8():
    """Glowing trail tracing a figure 8, firefly at the head of the trail."""
    img = background()
    trail = layer()
    d = ImageDraw.Draw(trail)
    cx, cy, a = 1000, 880, 640
    pts = []
    for i in range(0, 360):
        t = math.radians(i)
        # lemniscate turned upright to read as an "8"
        den = 1 + math.sin(t) ** 2
        x = a * 0.62 * math.sin(t) * math.cos(t) / den
        y = a * math.cos(t) / den
        pts.append((cx + x, cy + y))
    n = len(pts)
    for i in range(0, n - 18, 6):
        alpha = int(120 + 135 * (i / n))
        r = 16 + 18 * (i / n)
        x, y = pts[i]
        d.ellipse([x - r, y - r, x + r, y + r], fill=GLOW + (alpha,))
    img = glow_paste(img, trail, 30, 2)
    hx, hy = pts[-12]
    img = firefly(img, hx + 30, hy - 40, 0.75, -60)
    return wordmark(img, y=1690, size=250)


def v_jar():
    """Firefly in a jar: store-and-forward messages, kept until picked up."""
    img = background(glow=(30, 55, 110, 60))
    cx = 1024
    img = firefly(img, cx, 980, 0.8, -15)
    jar = layer()
    d = ImageDraw.Draw(jar)
    glass = (200, 220, 245)
    d.rounded_rectangle([cx - 430, 470, cx + 430, 1560], radius=200, outline=glass + (230,), width=40)
    d.rounded_rectangle([cx - 330, 330, cx + 330, 470], radius=40, fill=(120, 135, 170, 255))
    # glass highlight
    d.rounded_rectangle([cx - 350, 600, cx - 300, 1300], radius=25, fill=(255, 255, 255, 60))
    img = Image.alpha_composite(img, jar)
    trail = layer()
    tone_trail(ImageDraw.Draw(trail), (cx - 280, 1440), (60, -8), TONES[:9], GLOW, 8, 18)
    img = glow_paste(img, trail, 18)
    return wordmark(img, y=1640, size=250)


def v_minimal():
    """One big firefly, nothing else: boldest at home-screen size."""
    img = background(top=(8, 10, 18), bottom=(12, 16, 30), glow=None)
    img = firefly(img, 1024, 950, 1.55, -25, 4)
    return img


def v_waves():
    """Firefly beaming radio waves from its glow, the JS8 signal as light."""
    img = background()
    waves = layer()
    d = ImageDraw.Draw(waves)
    cx, cy = 980, 1030
    for i, r in enumerate([300, 450, 600, 750]):
        d.arc([cx - r, cy - r, cx + r, cy + r], -55, 35, fill=GLOW + (255 - i * 45,), width=40 - i * 7)
    img = glow_paste(img, waves, 30, 2)
    img = firefly(img, 860, 1050, 0.95, -45)
    return wordmark(img)


def v_waterfall_trace():
    """A single JS8 signal trace on the waterfall whose head is the firefly."""
    img = background(top=(5, 7, 14), bottom=(10, 14, 28), glow=None)
    wf = layer()
    d = ImageDraw.Draw(wf)
    random.seed(11)
    for y in range(0, S, 12):
        for x in range(0, S, 12):
            if random.random() < 0.18:
                v = random.random()
                d.rectangle([x, y, x + 10, y + 8], fill=(20, 60 + int(80 * v), 140 + int(90 * v), int(40 + 50 * v)))
    img = Image.alpha_composite(img, wf)
    trace = layer()
    t = ImageDraw.Draw(trace)
    x = 1024
    y = S
    random.seed(2)
    seq = [0, 3, 1, 5, 2, 7, 4, 6, 3, 5, 1, 4, 6, 2]
    for i, tone in enumerate(seq):
        y0 = 1600 - i * 75
        tx = 860 + tone * 45
        a = int(80 + 175 * i / len(seq))
        t.rectangle([tx - 30, y0 - 90, tx + 30, y0], fill=GLOW + (a,))
    img = glow_paste(img, trace, 22, 2)
    img = firefly(img, 1080, 520, 0.85, 0)
    return wordmark(img, y=1690, size=250)


VARIANTS = [
    ("classic", v_classic, "Classic", "Tone trail over a waterfall"),
    ("figure8", v_figure8, "Figure 8", "Flight path draws the 8"),
    ("jar", v_jar, "Jar", "Messages kept until picked up"),
    ("minimal", v_minimal, "Minimal", "Boldest on the home screen"),
    ("waves", v_waves, "Beacon", "Its glow is the signal"),
    ("trace", v_waterfall_trace, "Trace", "A JS8 signal on the waterfall"),
]


def main():
    rendered = []
    for key, fn, title, tag in VARIANTS:
        im = fn().convert("RGB").resize((1024, 1024), Image.LANCZOS)
        im.save(os.path.join(HERE, f"firefly-{key}-1024.png"))
        rendered.append((title, tag, im))

    cols, cell_w, cell_h = 3, 700, 760
    W, H = cols * cell_w + 60, 2 * cell_h + 40
    sheet = Image.new("RGB", (W, H), NAVY)
    d = ImageDraw.Draw(sheet)
    fbig, fsm = font(52), font(28, bold=False)
    big = 420
    mask = Image.new("L", (big, big), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, big - 1, big - 1], radius=94, fill=255)
    mask60 = Image.new("L", (60, 60), 0)
    ImageDraw.Draw(mask60).rounded_rectangle([0, 0, 59, 59], radius=13, fill=255)
    for i, (title, tag, im) in enumerate(rendered):
        col, row = i % cols, i // cols
        x = 30 + col * cell_w
        y = 40 + row * cell_h
        cx = x + cell_w // 2
        sheet.paste(im.resize((big, big), Image.LANCZOS), (cx - big // 2, y), mask)
        sheet.paste(im.resize((60, 60), Image.LANCZOS), (cx - 30, y + big + 30), mask60)
        label = f"{i + 1}. {title}"
        tw = d.textlength(label, font=fbig)
        d.text((cx - tw / 2, y + big + 110), label, font=fbig, fill=(240, 246, 255))
        tw = d.textlength(tag, font=fsm)
        d.text((cx - tw / 2, y + big + 180), tag, font=fsm, fill=(140, 150, 175))
    sheet.save(os.path.join(HERE, "sheet.png"))


if __name__ == "__main__":
    main()
