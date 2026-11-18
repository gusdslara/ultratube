"""Ultratube brand assets: a white "U" cradling a play triangle on a red tile.

Geometry is defined once in a 108-unit space (Android adaptive icon grid) and
rendered supersampled with PIL. Vector XML twins are written for Android.
Usage: python -I brand.py <ppplayer_dir> <android_media_res_dir>
"""
import os
import sys
from PIL import Image, ImageDraw

PP, MEDIA_RES = sys.argv[1], sys.argv[2]
RES = os.path.join(PP, "android", "app", "src", "main", "res")
RED_TOP, RED_BOTTOM = (255, 42, 77), (184, 0, 37)

# 108-unit geometry (safe zone circle: diameter 66 centred at 54,54).
U_LEFT, U_RIGHT, U_TOP, U_ARM_END, THICK = 31.0, 77.0, 31.0, 55.0, 11.5
CX = (U_LEFT + U_RIGHT) / 2
R_OUT = (U_RIGHT - U_LEFT) / 2
R_IN = R_OUT - THICK
TRI = [(47.5, 35.5), (62.5, 45.0), (47.5, 54.5)]


def glyph(draw, s, ox=0.0, oy=0.0, fill=(255, 255, 255, 255)):
    """Draws the U + play glyph scaled by s (px per unit) at offset."""
    def P(x, y):
        return (ox + x * s, oy + y * s)
    # Arms.
    draw.rectangle([P(U_LEFT, U_TOP), P(U_LEFT + THICK, U_ARM_END)], fill=fill)
    draw.rectangle([P(U_RIGHT - THICK, U_TOP), P(U_RIGHT, U_ARM_END)], fill=fill)
    # Rounded arm tops.
    for x in (U_LEFT, U_RIGHT - THICK):
        draw.ellipse([P(x, U_TOP - THICK / 2), P(x + THICK, U_TOP + THICK / 2)], fill=fill)
    # Bottom bowl: outer half-disc minus inner half-disc.
    bowl = Image.new("L", draw.im.size, 0)
    bd = ImageDraw.Draw(bowl)
    bd.pieslice([P(CX - R_OUT, U_ARM_END - R_OUT), P(CX + R_OUT, U_ARM_END + R_OUT)], 0, 180, fill=255)
    bd.pieslice([P(CX - R_IN, U_ARM_END - R_IN), P(CX + R_IN, U_ARM_END + R_IN)], 0, 180, fill=0)
    draw.bitmap((0, 0), bowl, fill=fill)
    # Play triangle with softened corners.
    draw.polygon([P(*p) for p in TRI], fill=fill)


def gradient(size):
    img = Image.new("RGBA", (size, size))
    px = img.load()
    for y in range(size):
        for x in range(size):
            t = (x + y) / (2 * (size - 1))
            px[x, y] = tuple(int(a + (b - a) * t) for a, b in zip(RED_TOP, RED_BOTTOM)) + (255,)
    return img


def tile(size, radius_ratio=0.225, full_bleed=False):
    """Red rounded tile with the glyph, rendered 4x and downsampled."""
    big = size * 4
    grad = gradient(256).resize((big, big), Image.BICUBIC)
    mask = Image.new("L", (big, big), 0)
    if full_bleed:
        mask.paste(255, [0, 0, big, big])
    else:
        ImageDraw.Draw(mask).rounded_rectangle([0, 0, big - 1, big - 1], radius=int(big * radius_ratio), fill=255)
    out = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    out.paste(grad, (0, 0), mask)
    d = ImageDraw.Draw(out)
    # Glyph occupies the centre; scale 108 units onto the tile with padding.
    s = big / 108 * 1.12
    glyph(d, s, ox=(big - 108 * s) / 2, oy=(big - 108 * s) / 2 + big * 0.012)
    return out.resize((size, size), Image.LANCZOS)


def splash(canvas):
    """Android 12 splash icon: tile at 2/3 of the canvas on transparent."""
    img = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    t = tile(int(canvas * 0.5))
    img.paste(t, ((canvas - t.width) // 2, (canvas - t.height) // 2), t)
    return img


def save(img, *parts):
    path = os.path.join(*parts)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path, optimize=True)
    print("wrote", path, img.size)


# In-app logo + store icon.
save(tile(512), PP, "assets", "logo.png")
save(tile(512), PP, "assets", "logo_splash.png")
save(tile(1024), PP, "assets", "ultratube_icon_1024.png")

# Legacy launcher icons.
for folder, px in {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}.items():
    save(tile(px), RES, f"mipmap-{folder}", "ic_launcher.png")
    save(tile(px, radius_ratio=0.5), RES, f"mipmap-{folder}", "ic_launcher_round.png")

# Splash images (pre-12 centred bitmap and Android 12 animated icon slot).
for folder, px in {"mdpi": 288, "hdpi": 432, "xhdpi": 576, "xxhdpi": 864, "xxxhdpi": 1152}.items():
    img = splash(px)
    for variant in (f"drawable-{folder}", f"drawable-night-{folder}"):
        save(img, RES, variant, "android12splash.png")
        save(img, RES, variant, "splash.png")
for variant in ("drawable", "drawable-v21", "drawable-night", "drawable-night-v21"):
    save(Image.new("RGBA", (1, 1), (0, 0, 0, 255)), RES, variant, "background.png")


# ---------------------------------------------------------------- vectors
def f(v):
    return f"{v:.2f}".rstrip("0").rstrip(".")


def glyph_path():
    l, r, t, a, th = U_LEFT, U_RIGHT, U_TOP, U_ARM_END, THICK
    ht = th / 2
    u = (
        f"M{f(l)},{f(t)}"
        f"A{f(ht)},{f(ht)} 0,0 1 {f(l + th)},{f(t)}"
        f"V{f(a)}"
        f"A{f(R_IN)},{f(R_IN)} 0,0 0 {f(r - th)},{f(a)}"
        f"V{f(t)}"
        f"A{f(ht)},{f(ht)} 0,0 1 {f(r)},{f(t)}"
        f"V{f(a)}"
        f"A{f(R_OUT)},{f(R_OUT)} 0,0 1 {f(l)},{f(a)}Z"
    )
    tri = "M" + "L".join(f"{f(x)},{f(y)}" for x, y in TRI) + "Z"
    return u + tri


GLYPH = glyph_path()
VEC = 'xmlns:android="http://schemas.android.com/apk/res/android"'
AAPT = 'xmlns:aapt="http://schemas.android.com/aapt"'


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)
    print("wrote", path)


fg = f'''<!-- Ultratube glyph (white U + play) on the 108dp adaptive grid. -->
<vector {VEC} android:width="108dp" android:height="108dp" android:viewportWidth="108" android:viewportHeight="108">
    <path android:fillColor="#FFFFFF" android:pathData="{GLYPH}" />
</vector>
'''
bg = f'''<vector {VEC} {AAPT} android:width="108dp" android:height="108dp" android:viewportWidth="108" android:viewportHeight="108">
    <path android:pathData="M0,0h108v108h-108z">
        <aapt:attr name="android:fillColor">
            <gradient android:type="linear" android:startX="0" android:startY="0" android:endX="108" android:endY="108"
                android:startColor="#FFFF2A4D" android:endColor="#FFB80025" />
        </aapt:attr>
    </path>
</vector>
'''
write(os.path.join(RES, "drawable", "ic_launcher_foreground_ut.xml"), fg)
write(os.path.join(RES, "drawable", "ic_launcher_background_ut.xml"), bg)
adaptive = f'''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon {VEC}>
    <background android:drawable="@drawable/ic_launcher_background_ut" />
    <foreground android:drawable="@drawable/ic_launcher_foreground_ut" />
    <monochrome android:drawable="@drawable/ic_launcher_foreground_ut" />
</adaptive-icon>
'''
write(os.path.join(RES, "mipmap-anydpi-v26", "ic_launcher.xml"), adaptive)
write(os.path.join(RES, "mipmap-anydpi-v26", "ic_launcher_round.xml"), adaptive)

# Shared module: tile icon (watch launcher) and notification silhouette.
tile_vec = f'''<!-- Ultratube tile: red gradient rounded square with the white glyph. -->
<vector {VEC} {AAPT} android:width="108dp" android:height="108dp" android:viewportWidth="108" android:viewportHeight="108">
    <path android:pathData="M24,0h60a24,24 0,0 1 24,24v60a24,24 0,0 1 -24,24h-60a24,24 0,0 1 -24,-24v-60a24,24 0,0 1 24,-24z">
        <aapt:attr name="android:fillColor">
            <gradient android:type="linear" android:startX="0" android:startY="0" android:endX="108" android:endY="108"
                android:startColor="#FFFF2A4D" android:endColor="#FFB80025" />
        </aapt:attr>
    </path>
    <path android:fillColor="#FFFFFF" android:pathData="{GLYPH}" />
</vector>
'''
write(os.path.join(MEDIA_RES, "drawable", "ic_ultratube.xml"), tile_vec)
notif = f'''<!-- Status-bar silhouette of the Ultratube glyph. -->
<vector {VEC} android:width="24dp" android:height="24dp" android:viewportWidth="108" android:viewportHeight="108">
    <path android:fillColor="#FFFFFF" android:pathData="{GLYPH}" />
</vector>
'''
write(os.path.join(MEDIA_RES, "drawable", "ic_ultratube_notification.xml"), notif)
