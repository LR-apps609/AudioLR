# Icona di AudioLR (logo 2026): sette barre arrotondate a forma d'onda, dal corallo al verde acqua,
# su un riquadro prugna scuro. Disegnata in grande e ridotta, così i bordi restano morbidi.
#   python3 Tools/make_icon.py <cartella>          → icon_1024.png (griglia delle icone macOS) e logo.png (riquadro pieno)
import sys
from PIL import Image, ImageDraw, ImageFilter

S = 2048

# Le barre: altezza (frazione del riquadro) e sfumatura dall'alto al basso, misurate sul logo originale
BARS = [
    (0.14, [(239, 152, 130), (232, 136, 116)]),
    (0.29, [(237, 164, 137), (232, 145, 116)]),
    (0.47, [(241, 202, 147), (222, 164, 132)]),
    (0.65, [(232, 212, 246), (194, 171, 235), (134, 191, 198)]),
    (0.47, [(168, 196, 238), (128, 173, 228), (113, 180, 186)]),
    (0.29, [(111, 162, 224), (101, 175, 174)]),
    (0.14, [(119, 195, 171), (108, 184, 160)]),
]
SPACING = 0.1147   # distanza tra i centri delle barre
WIDTH = 0.067      # larghezza di una barra


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def gradient(stops, t):
    if len(stops) == 1:
        return stops[0]
    seg = min(int(t * (len(stops) - 1)), len(stops) - 2)
    local = t * (len(stops) - 1) - seg
    return lerp(stops[seg], stops[seg + 1], local)


def tile(side, radius):
    """Il riquadro: sfumatura in diagonale da prugna (in alto a sinistra) a quasi nero, bordo appena illuminato."""
    bg = Image.new("RGBA", (side, side))
    px = bg.load()
    a, b, c = (62, 53, 80), (37, 33, 52), (14, 14, 22)
    for y in range(side):
        for x in range(side):
            t = (x * 0.35 + y * 0.65) / side
            px[x, y] = (lerp(a, b, t / 0.5) if t < 0.5 else lerp(b, c, (t - 0.5) / 0.5)) + (255,)
    # Alone morbido dietro l'onda
    glow = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse([side * 0.18, side * 0.25, side * 0.82, side * 0.75], fill=(150, 130, 210, 40))
    bg = Image.alpha_composite(bg, glow.filter(ImageFilter.GaussianBlur(side * 0.08)))
    # Bordo: una linea chiara sottile, più visibile in alto
    rim = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    ImageDraw.Draw(rim).rounded_rectangle([2, 2, side - 3, side - 3], radius, outline=(255, 255, 255, 46), width=max(2, side // 220))
    fade = Image.linear_gradient("L").resize((side, side)).point(lambda v: 255 - int(v * 0.75))
    rim.putalpha(Image.composite(rim.split()[3], Image.new("L", (side, side), 0), fade))
    bg = Image.alpha_composite(bg, rim)
    mask = Image.new("L", (side, side), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, side - 1, side - 1], radius, fill=255)
    out = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    out.paste(bg, mask=mask)
    return out


def bars(side):
    """Le sette barre con la loro sfumatura e un leggero bagliore."""
    layer = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    w = WIDTH * side
    n = len(BARS)
    for i, (h, stops) in enumerate(BARS):
        cx = side / 2 + (i - (n - 1) / 2) * SPACING * side
        H = h * side
        x0, y0 = cx - w / 2, side / 2 - H / 2
        bar = Image.new("RGBA", (int(w) + 2, int(H) + 2))
        bp = bar.load()
        for y in range(bar.size[1]):
            col = gradient(stops, min(1, y / max(1, H)))
            for x in range(bar.size[0]):
                bp[x, y] = col + (255,)
        cap = Image.new("L", bar.size, 0)
        ImageDraw.Draw(cap).rounded_rectangle([0, 0, w, H], radius=w / 2, fill=255)
        layer.paste(bar, (int(round(x0)), int(round(y0))), cap)
    glow = layer.filter(ImageFilter.GaussianBlur(side * 0.02))
    glow.putalpha(glow.split()[3].point(lambda v: int(v * 0.45)))
    return Image.alpha_composite(glow, layer)


def logo(side):
    """Il riquadro pieno (per il sito, Windows e i documenti)."""
    t = tile(side, int(side * 0.225))
    return Image.alpha_composite(t, Image.composite(bars(side), Image.new("RGBA", (side, side), (0, 0, 0, 0)), t.split()[3]))


def macos_icon(size):
    """Icona macOS: il riquadro dentro la griglia ufficiale (824 su 1024) con un'ombra leggera."""
    big = S
    m = int(big * 100 / 1024)
    inner = logo(big - 2 * m)
    canvas = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    shadow = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle([m, m + big * 0.012, big - m, big - m + big * 0.012], int((big - 2 * m) * 0.225), fill=(0, 0, 0, 110))
    canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(big * 0.012)))
    canvas.paste(inner, (m, m), inner)
    return canvas.resize((size, size), Image.LANCZOS)


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "."
    macos_icon(1024).save(f"{out}/icon_1024.png")
    logo(S).resize((512, 512), Image.LANCZOS).save(f"{out}/logo.png")
    print("Fatto:", out)
