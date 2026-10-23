# Icona di AudioLR: un'onda sonora le cui barre sono divise nei colori dei quattro strumenti.
import sys, math
from PIL import Image, ImageDraw, ImageFilter
S = 2048                       # disegno al doppio, poi riduco (bordi morbidi)
def hexc(h, a=255): return ((h >> 16) & 255, (h >> 8) & 255, h & 255, a)

def make():
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    # Riquadro con angoli arrotondati (griglia delle icone macOS: 824/1024)
    m = int(S * 100 / 1024); side = S - 2 * m; r = int(side * 0.225)
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle([m, m, m + side, m + side], r, fill=255)
    # Fondo: sfumatura verticale, inchiostro-prugna in alto, quasi nero in basso
    bg = Image.new("RGBA", (S, S))
    top, bot = hexc(0x2E2540), hexc(0x120F18)
    px = bg.load()
    for y in range(S):
        t = (y - m) / side; t = min(max(t, 0), 1)
        c = tuple(int(top[i] + (bot[i] - top[i]) * t) for i in range(3)) + (255,)
        for x in range(S): px[x, y] = c
    # Solchi di un disco, appena visibili
    grooves = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(grooves)
    cx = cy = S // 2
    for k in range(16):
        rr = int(side * (0.16 + k * 0.021))
        d.ellipse([cx - rr, cy - rr, cx + rr, cy + rr], outline=(255, 255, 255, 13), width=4)
    bg = Image.alpha_composite(bg, grooves)
    # Alone caldo al centro
    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse([cx - side * .36, cy - side * .30, cx + side * .36, cy + side * .30], fill=hexc(0xD6AA62, 70))
    glow = glow.filter(ImageFilter.GaussianBlur(S * 0.07))
    bg = Image.alpha_composite(bg, glow)

    # Le barre dell'onda: ogni barra è divisa in voce, batteria, basso, altri strumenti
    colors = [0xE5917A, 0xE6B45C, 0xB497D0, 0x76C3B9]
    heights = [0.16, 0.30, 0.48, 0.66, 0.84, 0.96, 1.0, 0.90, 0.74, 0.56, 0.40, 0.26, 0.14]
    n = len(heights)
    bw = side * 0.040; gap = side * 0.024
    total = n * bw + (n - 1) * gap
    x0 = cx - total / 2
    hmax = side * 0.66
    bars = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    bd = ImageDraw.Draw(bars)
    seg_gap = side * 0.006
    for i, h in enumerate(heights):
        H = hmax * h
        x = x0 + i * (bw + gap)
        ytop = cy - H / 2
        # La barra intera (capsula), poi le quattro fasce di colore dentro, separate da una linea sottile
        cap = Image.new("L", (S, S), 0)
        ImageDraw.Draw(cap).rounded_rectangle([x, ytop, x + bw, ytop + H], radius=bw / 2, fill=255)
        layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        ld = ImageDraw.Draw(layer)
        seg = H / 4
        for k, col in enumerate(colors):
            y = ytop + k * seg
            ld.rectangle([x, y + (seg_gap / 2 if k else 0), x + bw, y + seg - (seg_gap / 2 if k < 3 else 0)], fill=hexc(col))
        bars.paste(layer, mask=Image.composite(layer.split()[3], Image.new("L", (S, S), 0), cap))
    shadow = bars.copy().filter(ImageFilter.GaussianBlur(S * 0.012))
    sh = Image.new("RGBA", (S, S), (0, 0, 0, 0)); sh.paste((0, 0, 0, 120), mask=shadow.split()[3])
    bg = Image.alpha_composite(bg, sh.transform(sh.size, Image.AFFINE, (1, 0, 0, 0, 1, -S * 0.008)))
    bg = Image.alpha_composite(bg, bars)
    # Bordo sottile in ottone
    ring = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(ring).rounded_rectangle([m + 3, m + 3, m + side - 3, m + side - 3], r, outline=hexc(0xD6AA62, 90), width=6)
    bg = Image.alpha_composite(bg, ring)
    img.paste(bg, mask=mask)
    return img

big = make().resize((1024, 1024), Image.LANCZOS)
out = sys.argv[1]
big.save(f"{out}/icon_1024.png")
