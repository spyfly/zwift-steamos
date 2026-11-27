#!/usr/bin/env python3
"""Generate all Steam library artwork for the custom shortcuts 'Zwift' and
'Zwift (Settings)'.

Files follow the non-Steam grid naming convention
(userdata/<id>/config/grid/):
    <appid>.png      920x430   wide capsule
    <appid>p.png     600x900   portrait grid
    <appid>_hero.png 1920x620  hero banner
    <appid>_icon.png 512x512   library icon

Design: dark charcoal full-bleed, orange (#FC4C02) motif - giant Z for the
game entry, gear-wrapped Z for the settings entry, perspective road glow.
Deterministic (no randomness), PIL-only.
"""
import math
import os

from PIL import Image, ImageDraw, ImageFont

ORANGE = (252, 76, 2)
ORANGE_DIM = (252, 76, 2, 0)
DARK = (21, 23, 28)
PANEL = (29, 32, 38)
WHITE = (245, 245, 245)
GREY = (42, 45, 51)
FONT_BOLD = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "icons")
APPS = {"zwift": 3907836014, "settings": 2566064630}


def radial_glow(draw, cx, cy, r_max, n=48, base_alpha=70):
    """Concentric ellipses: orange glow fading out."""
    for i in range(n, 0, -1):
        f = i / n
        r = r_max * (0.08 + 0.92 * f)
        alpha = int(base_alpha * (1 - f) ** 1.8)
        draw.ellipse([cx - r, cy - r * 0.55, cx + r, cy + r * 0.55],
                     fill=ORANGE + (alpha,))


def draw_road(img, horizon_y, apex_w, base_w):
    """Perspective road strip with glowing edges and centre dashes."""
    W, H = img.size
    ov = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(ov)
    apex = (W / 2, horizon_y)
    bl, br = (W / 2 - base_w / 2, H), (W / 2 + base_w / 2, H)
    d.polygon([apex, (apex[0] - apex_w / 2, apex[1]),
               bl, br], fill=PANEL + (255,))
    # glowing edge lines
    for side in (-1, 1):
        x0, x1 = apex[0] + side * apex_w / 2, W / 2 + side * base_w / 2
        for k in range(3):
            w = 2 + k * 2
            a = 90 - k * 30
            d.line([x0, horizon_y, x1, H], fill=ORANGE + (a,), width=w)
    # centre dashes
    y = horizon_y + (H - horizon_y) * 0.18
    while y < H:
        seg = (H - horizon_y) * 0.05
        t = (y - horizon_y) / (H - horizon_y)
        cx = W / 2
        w = apex_w * t + 2
        d.line([cx, y, cx, y + seg], fill=ORANGE + (150,), width=max(2, int(w)))
        y += seg * 2.2
    img.alpha_composite(ov)


def letter_spaced(d, xy_center, text, font, fill, spacing=0.0):
    """Draw text with extra letter spacing, horizontally centered."""
    widths = [d.textlength(c, font=font) for c in text]
    total = sum(widths) + spacing * (len(text) - 1)
    x = xy_center[0] - total / 2
    for c, w in zip(text, widths):
        d.text((x, xy_center[1]), c, font=font, fill=fill)
        x += w + spacing


def draw_gear(img, cx, cy, r_outer, r_hole, teeth=10, ring=None, color=ORANGE):
    ring = ring if ring is not None else r_outer * 0.16
    ov = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(ov)
    # teeth as rotated rounded stubs
    tw = ring * 1.25  # tooth width along radius direction
    for i in range(teeth):
        ang = 2 * math.pi * i / teeth
        tx = cx + math.cos(ang) * (r_outer - ring * 0.5)
        ty = cy + math.sin(ang) * (r_outer - ring * 0.5)
        # tooth = circle blob at rim (simple + clean at small sizes)
        d.ellipse([tx - tw / 2, ty - tw / 2, tx + tw / 2, ty + tw / 2],
                  fill=color + (255,))
    d.ellipse([cx - r_outer, cy - r_outer, cx + r_outer, cy + r_outer],
              fill=color + (255,))
    d.ellipse([cx - r_hole, cy - r_hole, cx + r_hole, cy + r_hole],
              fill=DARK + (255,))
    img.alpha_composite(ov)


def motif_z(img, cx, cy, h_frac, color=ORANGE):
    """Draw a clean geometric Z from polygons (thicker than any font)."""
    W, H = img.size
    h = h_frac * H
    w = h * 0.78
    bar = h * 0.14
    x0, y0 = cx - w / 2, cy - h / 2
    ov = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(ov)
    d.polygon([(x0, y0), (x0 + w, y0), (x0 + w, y0 + bar), (x0, y0 + bar)],
              fill=color + (255,))                       # top bar
    d.polygon([(x0, y0 + h - bar), (x0 + w, y0 + h - bar),
               (x0 + w, y0 + h), (x0, y0 + h)],
              fill=color + (255,))                       # bottom bar
    d.polygon([(x0 + w, y0), (x0 + w, y0 + bar),
               (x0, y0 + h), (x0, y0 + h - bar)],
              fill=color + (255,))                       # diagonal
    img.alpha_composite(ov)


def canvas(W, H):
    img = Image.new("RGBA", (W, H), DARK + (255,))
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, W - 1, H - 1], outline=GREY + (255,), width=max(2, W // 300))
    return img


def centered_stack(img, gear, caption2=None, road=True):
    """Portrait/square composition: motif centered, wordmark below."""
    W, H = img.size
    if road:
        draw_road(img, H * 0.80, W * 0.10, W * 0.92)
    ov = Image.new("RGBA", img.size, (0, 0, 0, 0))
    radial_glow(ImageDraw.Draw(ov), W / 2, H * 0.42, W * 0.75)
    img.alpha_composite(ov)
    d = ImageDraw.Draw(img)
    if gear:
        r = H * 0.20
        draw_gear(img, W / 2, H * 0.38, r, r * 0.55)
        motif_z(img, W / 2, H * 0.38, 0.16, color=WHITE)
    else:
        motif_z(img, W / 2, H * 0.38, 0.34)
    f1 = ImageFont.truetype(FONT_BOLD, int(H * 0.075))
    letter_spaced(d, (W / 2, H * 0.60), "ZWIFT", f1, WHITE, spacing=H * 0.012)
    if caption2:
        f2 = ImageFont.truetype(FONT_BOLD, int(H * 0.055))
        letter_spaced(d, (W / 2, H * 0.685), caption2, f2, ORANGE,
                      spacing=H * 0.012)


def wide_layout(img, gear, caption2=None):
    """Wide composition: motif + wordmark left, road glow right."""
    W, H = img.size
    draw_road(img, H * 0.62, W * 0.05, W * 0.45)
    ov = Image.new("RGBA", img.size, (0, 0, 0, 0))
    radial_glow(ImageDraw.Draw(ov), W * 0.28, H * 0.45, W * 0.22)
    img.alpha_composite(ov)
    d = ImageDraw.Draw(img)
    if gear:
        r = H * 0.30
        draw_gear(img, W * 0.20, H * 0.44, r, r * 0.55)
        motif_z(img, W * 0.20, H * 0.44, 0.24, color=WHITE)
    else:
        motif_z(img, W * 0.20, H * 0.46, 0.62)
    f1 = ImageFont.truetype(FONT_BOLD, int(H * 0.20))
    letter_spaced(d, (W * 0.20, H * 0.72), "ZWIFT", f1, WHITE, spacing=H * 0.03)
    if caption2:
        f2 = ImageFont.truetype(FONT_BOLD, int(H * 0.10))
        letter_spaced(d, (W * 0.20, H * 0.90), caption2, f2, ORANGE,
                      spacing=H * 0.025)


def icon_layout(img, gear):
    """Square badge: rounded panel, centered motif, no caption."""
    W, H = img.size
    ov = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(ov)
    d.rounded_rectangle([W * 0.03, H * 0.03, W * 0.97, H * 0.97],
                        radius=W * 0.12, fill=DARK + (255,))
    img.alpha_composite(ov)
    ov2 = Image.new("RGBA", img.size, (0, 0, 0, 0))
    radial_glow(ImageDraw.Draw(ov2), W / 2, H * 0.52, W * 0.55)
    img.alpha_composite(ov2)
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([W * 0.03, H * 0.03, W * 0.97, H * 0.97],
                        radius=W * 0.12, outline=GREY + (255,),
                        width=max(3, W // 120))
    if gear:
        r = H * 0.34
        draw_gear(img, W / 2, H / 2, r, r * 0.55)
        motif_z(img, W / 2, H / 2, 0.28, color=WHITE)
    else:
        motif_z(img, W / 2, H / 2, 0.62)


def emit(app, appid, gear, caption2=None):
    jobs = [
        ("%d.png" % appid, 920, 430, wide_layout),
        ("%dp.png" % appid, 600, 900, centered_stack),
        ("%d_hero.png" % appid, 1920, 620, wide_layout),
        ("%d_icon.png" % appid, 512, 512, icon_layout),
    ]
    for name, W, H, fn in jobs:
        # render at 2x then downscale for crisp edges
        img = canvas(W * 2, H * 2)
        img = img.resize((W, H), Image.LANCZOS) if False else img
        img2 = Image.new("RGBA", (W, H), DARK + (255,))
        m = Image.new("RGBA", (W * 2, H * 2), DARK + (255,))
        d = ImageDraw.Draw(m)
        d.rectangle([0, 0, W * 2 - 1, H * 2 - 1], outline=GREY + (255,),
                    width=max(2, W // 150))
        if fn is icon_layout:
            icon_layout(m, gear)
        elif fn is wide_layout:
            wide_layout(m, gear, caption2)
        else:
            centered_stack(m, gear, caption2)
        img2 = m.resize((W, H), Image.LANCZOS)
        path = os.path.join(OUT, name)
        img2.convert("RGB").save(path, "PNG", optimize=True)
        print("wrote", path, img2.size)


def main():
    os.makedirs(OUT, exist_ok=True)
    emit("zwift", APPS["zwift"], gear=False)
    emit("settings", APPS["settings"], gear=True, caption2="SETTINGS")
    print("done")


if __name__ == "__main__":
    main()
