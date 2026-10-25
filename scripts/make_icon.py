from PIL import Image, ImageDraw, ImageFilter, ImageChops
S = 2048                      # Supersampling, am Ende 1024
def sc(v): return int(v * S / 1024)

def lin_gradient(size, c1, c2, vertical=True):
    w, h = size
    g = Image.new("RGBA", size)
    px = g.load()
    n = h if vertical else w
    for i in range(n):
        t = i / max(1, n - 1)
        col = tuple(int(c1[k] + (c2[k] - c1[k]) * t) for k in range(4))
        if vertical:
            for x in range(w): px[x, i] = col
        else:
            for y in range(h): px[i, y] = col
    return g

def rounded_mask(size, box, r):
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).rounded_rectangle(box, r, fill=255)
    return m

canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))

# --- Squircle (macOS-Raster: 824 px, Ecke ~185) mit Schatten
sq = (sc(100), sc(100), sc(924), sc(924))
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(shadow).rounded_rectangle((sq[0], sq[1] + sc(14), sq[2], sq[3] + sc(14)), sc(185), fill=(0, 0, 0, 120))
shadow = shadow.filter(ImageFilter.GaussianBlur(sc(18)))
canvas.alpha_composite(shadow)

bg = lin_gradient((S, S), (30, 22, 74, 255), (12, 10, 32, 255))
# leichter Farbschimmer oben links
glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(glow).ellipse((sc(60), sc(20), sc(700), sc(560)), fill=(120, 80, 255, 90))
glow = glow.filter(ImageFilter.GaussianBlur(sc(120)))
bg.alpha_composite(glow)
canvas.paste(bg, (0, 0), rounded_mask((S, S), sq, sc(185)))

# --- Spiegelfläche / "Bildschirm"
pane = (sc(222), sc(250), sc(802), sc(612))
pr = sc(54)
pane_grad = lin_gradient((S, S), (70, 205, 255, 255), (148, 72, 255, 255), vertical=False)
diag = lin_gradient((S, S), (255, 255, 255, 0), (30, 0, 110, 90))
pane_grad.alpha_composite(diag)
pane_mask = rounded_mask((S, S), pane, pr)

# Glanzstreifen (diagonal), nur innerhalb der Fläche
streak = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(streak)
d.polygon([(sc(360), sc(250)), (sc(470), sc(250)), (sc(330), sc(612)), (sc(220), sc(612))], fill=(255, 255, 255, 70))
d.polygon([(sc(500), sc(250)), (sc(540), sc(250)), (sc(400), sc(612)), (sc(360), sc(612))], fill=(255, 255, 255, 45))
streak = streak.filter(ImageFilter.GaussianBlur(sc(3)))
pane_img = pane_grad.copy()
pane_img.alpha_composite(streak)

# Pane-Schatten
ps = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(ps).rounded_rectangle((pane[0], pane[1] + sc(16), pane[2], pane[3] + sc(16)), pr, fill=(0, 0, 0, 140))
ps = ps.filter(ImageFilter.GaussianBlur(sc(22)))
canvas.alpha_composite(ps)

layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
layer.paste(pane_img, (0, 0), pane_mask)
canvas.alpha_composite(layer)

# Kleine "Titelleiste" oben in der Fläche – Anspielung auf das Overlay
bar = Image.new("RGBA", (S, S), (0, 0, 0, 0))
bd = ImageDraw.Draw(bar)
bd.rounded_rectangle((pane[0], pane[1], pane[2], pane[1] + sc(46)), pr, fill=(10, 8, 30, 90))
bd.rectangle((pane[0], pane[1] + sc(24), pane[2], pane[1] + sc(46)), fill=(10, 8, 30, 90))
for i, col in enumerate([(255, 255, 255, 200), (255, 255, 255, 140), (255, 255, 255, 90)]):
    cx = pane[0] + sc(40) + i * sc(30); cy = pane[1] + sc(23)
    bd.ellipse((cx - sc(8), cy - sc(8), cx + sc(8), cy + sc(8)), fill=col)
bar_masked = Image.new("RGBA", (S, S), (0, 0, 0, 0))
bar_masked.paste(bar, (0, 0), ImageChops.multiply(pane_mask, bar.split()[3]))
canvas.alpha_composite(bar_masked)

# Feiner heller Rand
border = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(border).rounded_rectangle(pane, pr, outline=(255, 255, 255, 150), width=sc(4))
canvas.alpha_composite(border)

# --- Spiegelung (鏡): umgedrehte, ausblendende Kopie unter einer "Wasserlinie"
gap = sc(26)
refl_top = pane[3] + gap
refl_h = sc(210)
pane_only = layer.copy(); pane_only.alpha_composite(bar_masked); pane_only.alpha_composite(border)
src = pane_only.crop((pane[0] - sc(4), pane[3] - refl_h, pane[2] + sc(4), pane[3] + sc(4))).transpose(Image.FLIP_TOP_BOTTOM)
fade = lin_gradient(src.size, (0, 0, 0, 175), (0, 0, 0, 0))
alpha = ImageChops.multiply(src.split()[3], fade.split()[3])
src.putalpha(alpha)
src = src.filter(ImageFilter.GaussianBlur(sc(2)))
refl_layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
refl_layer.paste(src, (pane[0] - sc(4), refl_top), src)
# auf den Squircle beschränken
clip = rounded_mask((S, S), sq, sc(185))
refl_layer.putalpha(ImageChops.multiply(refl_layer.split()[3], clip))
canvas.alpha_composite(refl_layer)

# Wasserlinie
line = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ld = ImageDraw.Draw(line)
y = pane[3] + gap // 2
ld.line((pane[0] - sc(40), y, pane[2] + sc(40), y), fill=(200, 190, 255, 120), width=sc(3))
line = line.filter(ImageFilter.GaussianBlur(sc(1.5)))
canvas.alpha_composite(line)

# Innerer Rand des Squircles
edge = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(edge).rounded_rectangle(sq, sc(185), outline=(255, 255, 255, 40), width=sc(3))
canvas.alpha_composite(edge)

icon = canvas.resize((1024, 1024), Image.LANCZOS)
icon.save("AppIcon.png")
icon.save("AppIcon.icns", sizes=[(16,16),(32,32),(64,64),(128,128),(256,256),(512,512),(1024,1024)])
print("ok")
