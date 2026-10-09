"""Draw the demo pack's map ("Demo Map 1"), a made-up continent as a painted atlas map,
and the icon images for its custom marker types.

Original art, generated from noise with a fixed seed (the same every run): smooth
coastlines, blended terrain with hill shading, shallow seas with ripple lines,
mountain ranges, forests, dunes, marsh, rivers and a lake, a title and a compass.
Place names are markers (see markers/world.json), not painted on: every marker sits
on land, in a small clearing so it's easy to see.

    python make_demo_image.py
    python ../../tools/slicer/slice_map.py demo-map-1.png . --map-id world --zip

Then copy pack.json, markers/, icons/ and world-tiles.zip into app/assets/packs/tome.demo/.
"""

import json
import math
import random
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 2048, 1536
SS = 2  # vector details are drawn at 2x, then everything is scaled down
SEED = 11
HERE = Path(__file__).parent

# Every marker gets land under it and a clearing round it (read from the pack's markers).
MARKERS = [(m['x'], m['y']) for m in json.loads((HERE / 'markers' / 'world.json').read_text(encoding='utf-8'))]

# (x, y, radius, amount): raise islands and a peninsula, sink a lake.
BUMPS = [
    (155, 165, 105, 1.25),    # Isle of Thorns (north-west chest)
    (1910, 1396, 122, 1.6),   # Lantern Isle (south-east chest)
    (330, 1140, 165, 0.75),   # Mirewood peninsula (rusty key)
    (1650, 520, 110, 0.35),   # east coast (bench)
    (840, 640, 58, -1.7),     # Mirror Lake
]

LABELS = [  # (text, x, y, size, kind): only the seas; places are markers
    ('The Glass Sea', 1560, 150, 40, 'sea'),
    ('The Sunken Deep', 700, 1440, 40, 'sea'),
]

DEEP, SHALLOW, LAKE_COLOUR = np.array((30, 72, 116)), np.array((78, 140, 186)), np.array((86, 150, 196))
BIOMES = {  # id: colour
    0: (236, 240, 242),   # snow
    1: (160, 166, 140),   # tundra
    2: (112, 160, 76),    # grassland
    3: (184, 176, 96),    # plains
    4: (226, 198, 120),   # desert
    5: (92, 138, 82),     # marsh
}

# ---- noise ---------------------------------------------------------------------------

YS, XS = np.mgrid[0:H, 0:W].astype(np.float64) + 0.5


def value_noise(seed, cells, u, v):
    """Smooth value noise in [0, 1] for arrays u, v (lattice of `cells` across the width)."""
    g = np.random.default_rng(seed).random((cells + 2, cells + 2))
    x = np.clip(u, 0, 0.999999) * cells
    y = np.clip(v, 0, 0.999999) * cells
    i, j = x.astype(int), y.astype(int)
    fx, fy = x - i, y - j
    sx, sy = fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy)
    a = g[j, i] + (g[j, i + 1] - g[j, i]) * sx
    b = g[j + 1, i] + (g[j + 1, i + 1] - g[j + 1, i]) * sx
    return a + (b - a) * sy


def fbm(seed, octaves=5, base=3, x=XS, y=YS):
    u, v = x / W, y / W
    total, norm, amp = 0.0, 0.0, 1.0
    for o in range(octaves):
        total = total + amp * value_noise(seed * 31 + o, base * 2 ** o, u, v)
        norm += amp
        amp *= 0.5
    return total / norm


def blur(a, radius):
    """Gaussian blur of a 0-1 array (via an 8-bit image, plenty for masks and fields)."""
    img = Image.fromarray(np.clip(a * 255, 0, 255).astype(np.uint8), 'L')
    return np.asarray(img.filter(ImageFilter.GaussianBlur(radius)), dtype=np.float64) / 255


def smooth(a, radius):
    """Gaussian-like blur in full precision (three box blurs), for heights: an 8-bit blur
    would step the hill shading into visible contour bands."""
    r = max(1, int(radius))
    for _ in range(3):
        for axis in (0, 1):
            pad = [(0, 0), (0, 0)]
            pad[axis] = (r + 1, r)
            c = np.cumsum(np.pad(a, pad, mode='edge'), axis=axis)
            hi = np.take(c, np.arange(2 * r + 1, c.shape[axis]), axis=axis)
            lo = np.take(c, np.arange(0, c.shape[axis] - 2 * r - 1), axis=axis)
            a = (hi - lo) / (2 * r + 1)
    return a


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)


# ---- the world -----------------------------------------------------------------------

def build_fields():
    # Warp the coordinates with noise (broad and fine) so coasts wander into bays and capes.
    xw = XS + (fbm(5, octaves=3, base=4) - 0.5) * 170 + (fbm(7, octaves=3, base=10) - 0.5) * 90
    yw = YS + (fbm(6, octaves=3, base=4) - 0.5) * 170 + (fbm(8, octaves=3, base=10) - 0.5) * 90
    n = fbm(1, x=xw, y=yw)
    fine = fbm(9, octaves=4, base=14, x=xw, y=yw)
    dx, dy = (xw - 1010) / 790, (yw - 770) / 545
    e = 0.62 * (1 - (dx * dx + dy * dy)) + 0.85 * (n - 0.5) + 0.40 * (fine - 0.5)
    for bx, by, br, amt in BUMPS:
        # Placed by true position (so islands and the lake stay where their labels and markers
        # are); the noise only roughens their edges.
        lumpy = 0.7 + 0.6 * fine if amt > 0 else 1
        e += amt * lumpy * np.exp(-((XS - bx) ** 2 + (YS - by) ** 2) / (2 * br * br))
    for mx, my in MARKERS:  # a gentle rise under each marker, so each sits on land
        e += 0.2 * np.exp(-((XS - mx) ** 2 + (YS - my) ** 2) / (2 * 42 ** 2))

    temp = np.clip(0.02 + YS / H + 0.22 * (fbm(2) - 0.5) - 0.25 * np.maximum(0, e - 0.5), 0, 1)
    land = e > 0
    coast = blur(land.astype(float), 18)  # ~1 at the shore inland, ~0 far out
    moist = fbm(3) + 0.12 * np.clip(1 - coast, 0, 1) * land
    ridge = 1 - np.abs(2 * fbm(4, octaves=4, base=2) - 1)
    # Lakes: water that isn't connected to the sea (flood the sea from a corner).
    # (.copy(): an image made from an array is read-only, and floodfill would silently do nothing)
    water = Image.fromarray(np.where(land, 0, 255).astype(np.uint8), 'L').copy()
    ImageDraw.floodfill(water, (0, 0), 128)
    lake = np.asarray(water) == 255
    return dict(e=e, land=land, temp=temp, moist=moist, ridge=ridge, lake=lake)


def biome_map(f):
    t, m = f['temp'], f['moist']
    b = np.full(t.shape, 2)                       # grassland
    b = np.where(m < 0.47, 3, b)                  # plains
    b = np.where((t > 0.68) & (m < 0.50), 4, b)   # desert
    b = np.where((b == 2) & (m > 0.55) & (f['e'] < 0.10), 5, b)  # marsh by the low coasts
    b = np.where(t < 0.33, 1, b)                  # tundra
    b = np.where(t < 0.14, 0, b)                  # snow
    return b


def paint_terrain(f):
    """The raster: blended land colours with hill shading, and graded water."""
    land = f['land']
    b = biome_map(f)
    colour = np.zeros((H, W, 3))
    for k, rgb in BIOMES.items():
        colour[b == k] = rgb
    # Soft transitions between biomes (blurred within the land only).
    mask = land.astype(float)
    weight = blur(mask, 7) + 1e-6
    soft = np.stack([blur(colour[..., c] * mask / 255, 7) for c in range(3)], -1) * 255 / weight[..., None]

    # Hill shading from a relief height: the land, plus raised mountain ranges.
    mountains = smoothstep(0.82, 0.95, f['ridge']) * smoothstep(0.1, 0.3, f['e'])
    relief = smooth(np.clip(f['e'] * 0.6 + 0.5 * mountains, 0, 1), 3)
    gy, gx = np.gradient(relief)
    shade = np.clip(1 + 55 * (gx + gy) * 0.707, 0.72, 1.22)
    grain = 1 + 0.035 * (fbm(21, octaves=2, base=256) - 0.5)
    landc = np.clip(soft * shade[..., None] * grain[..., None], 0, 255)

    # Water: deep to shallow towards the shore, ripple lines along it, a lake.
    near = blur(mask, 30)
    shallow = np.clip(near * 2.8, 0, 1)[..., None]
    water = DEEP * (1 - shallow) + SHALLOW * shallow
    for level in (0.30, 0.15, 0.06):
        line = np.clip(1 - np.abs(near - level) / 0.010, 0, 1) * (~land) * (~f['lake'])
        water = water + line[..., None] * 26
    water = np.where(f['lake'][..., None], LAKE_COLOUR * (0.9 + 0.1 * shallow), water)

    # Anti-aliased coastline, with a pale beach edge.
    alpha = np.clip(f['e'] / 0.012 + 0.5, 0, 1)[..., None]
    beach = np.clip(1 - np.abs(f['e'] - 0.004) / 0.012, 0, 1)[..., None] * 0.55
    out = water * (1 - alpha) + landc * alpha
    out = out * (1 - beach) + np.array((236, 226, 190)) * beach
    return Image.fromarray(np.clip(out, 0, 255).astype(np.uint8), 'RGB')


# ---- symbols ----------------------------------------------------------------------------

def scatter(step, keep, rnd):
    """Jittered-grid points where keep(x, y) holds: natural-looking, never in a grid."""
    pts = []
    for gy in range(0, H, step):
        for gx in range(0, W, step):
            x, y = gx + rnd.uniform(0, step), gy + rnd.uniform(0, step)
            if 0 <= x < W and 0 <= y < H and keep(int(x), int(y)):
                pts.append((x, y))
    return pts


def clear_of_markers(x, y, r=46):
    return all((x - mx) ** 2 + (y - my) ** 2 > r * r for mx, my in MARKERS)


def shade(rgb, k):
    return tuple(max(0, min(255, round(c * k))) for c in rgb)


def draw_symbols(d, f, rnd):
    e, ridge, land, temp, moist = f['e'], f['ridge'], f['land'], f['temp'], f['moist']
    b = biome_map(f)
    S = SS
    inland = lambda x, y: land[y, x] and e[y, x] > 0.035

    peaks = scatter(36, lambda x, y: inland(x, y) and ridge[y, x] > 0.925 and e[y, x] > 0.15
                    and clear_of_markers(x, y), rnd)
    hills = scatter(46, lambda x, y: inland(x, y) and (0.86 < ridge[y, x] <= 0.925 or e[y, x] > 0.72)
                    and clear_of_markers(x, y), rnd)
    trees = scatter(20, lambda x, y: inland(x, y) and moist[y, x] > 0.63 and ridge[y, x] < 0.86
                    and b[y, x] in (1, 2, 3) and clear_of_markers(x, y, 30), rnd)
    dunes = scatter(46, lambda x, y: inland(x, y) and b[y, x] == 4 and ridge[y, x] < 0.86
                    and clear_of_markers(x, y), rnd)
    reeds = scatter(26, lambda x, y: inland(x, y) and b[y, x] == 5 and clear_of_markers(x, y, 30), rnd)

    items = ([('hill', p) for p in hills] + [('tree', p) for p in trees] + [('peak', p) for p in peaks]
             + [('dune', p) for p in dunes] + [('reed', p) for p in reeds])
    items.sort(key=lambda it: it[1][1])  # back to front
    for kind, (x, y) in items:
        cx, cy = x * S, y * S
        cold = temp[int(y), int(x)] < 0.35
        if kind == 'peak':
            h, w = rnd.uniform(26, 38) * S, rnd.uniform(17, 24) * S
            top = (cx, cy - h)
            d.polygon([top, (cx - w, cy), (cx, cy)], fill=(178, 170, 156, 255))
            d.polygon([top, (cx, cy), (cx + w, cy)], fill=(110, 102, 92, 255))
            cap = 0.36 if cold or e[int(y), int(x)] > 0.45 else 0.24
            d.polygon([top, (cx - w * cap, cy - h * (1 - cap)), (cx + w * cap * 0.8, cy - h * (1 - cap))],
                      fill=(246, 248, 250, 255))
            d.line([(cx - w, cy), top, (cx + w, cy)], fill=(58, 52, 46, 170), width=int(1.4 * S))
        elif kind == 'hill':
            w = rnd.uniform(16, 22) * S
            base = BIOMES[int(b[int(y), int(x)])]
            box = [cx - w, cy - w * 0.62, cx + w, cy + w * 0.62]
            d.pieslice(box, 180, 360, fill=shade(base, 0.84) + (255,))
            d.arc(box, 205, 300, fill=shade(base, 1.2) + (255,), width=int(2.4 * S))
        elif kind == 'tree':
            if cold:
                h = rnd.uniform(15, 19) * S
                d.polygon([(cx, cy - h), (cx - h * 0.42, cy), (cx + h * 0.42, cy)],
                          fill=(46, 86, 66, 255), outline=(26, 50, 38, 255))
            else:
                r = rnd.uniform(6.5, 8.5) * S
                leaf = (48, 108, 54) if temp[int(y), int(x)] < 0.7 else (54, 124, 60)
                d.ellipse([cx - r, cy - r * 1.6, cx + r, cy + r * 0.2], fill=leaf + (255,), outline=(26, 58, 30, 255))
                d.ellipse([cx - r * 0.55, cy - r * 1.4, cx + r * 0.1, cy - r * 0.7], fill=shade(leaf, 1.35) + (255,))
        elif kind == 'dune':
            w = rnd.uniform(16, 22) * S
            d.arc([cx - w, cy - w * 0.4, cx + w, cy + w * 0.5], 200, 340, fill=(198, 162, 80, 255), width=int(2.6 * S))
        elif kind == 'reed':
            d.line([(cx - 7 * S, cy), (cx + 7 * S, cy)], fill=(74, 126, 168, 255), width=int(2.4 * S))
            d.line([(cx - 2 * S, cy), (cx - 4 * S, cy - 10 * S)], fill=(58, 92, 50, 255), width=int(1.8 * S))
            d.line([(cx + 2 * S, cy), (cx + 4 * S, cy - 8 * S)], fill=(58, 92, 50, 255), width=int(1.8 * S))


def trace_rivers(f, rnd, count=3):
    """Rivers run downhill from the mountains to the nearest water, on a coarse grid."""
    e = blur(np.clip(f['e'] * 0.6 + 0.3, 0, 1), 6)  # smoothed height
    land, ridge = f['land'], f['ridge']
    step = 8
    sources = [(x, y) for y in range(200, H - 200, 40) for x in range(200, W - 200, 40)
               if land[y, x] and ridge[y, x] > 0.9 and f['e'][y, x] > 0.3]
    rnd.shuffle(sources)
    rivers = []
    for sx, sy in sources:
        if len(rivers) == count:
            break
        if any(min(math.dist((sx, sy), p) for p in r) < 160 for r in rivers):
            continue
        path, (x, y) = [(sx, sy)], (sx, sy)
        heading = None
        for _ in range(400):
            best = None
            for a in range(0, 360, 20):
                nx = int(x + step * math.cos(math.radians(a)))
                ny = int(y + step * math.sin(math.radians(a)))
                if not (0 <= nx < W and 0 <= ny < H):
                    continue
                turn = 0 if heading is None else 0.0006 * (1 - math.cos(math.radians(a - heading)))
                score = e[ny, nx] + turn + rnd.uniform(0, 0.0004)
                if best is None or score < best[0]:
                    best = (score, nx, ny, a)
            if best is None or best[0] > e[y, x] + 0.0015:
                break  # stuck in a hollow
            _, x, y, heading = best
            path.append((x, y))
            if not land[y, x]:
                break
        if len(path) > 25 and not land[path[-1][1], path[-1][0]] and all(
                min(math.dist(p, q) for q in r) > 60 for r in rivers for p in path[::5]):
            rivers.append(path)
    return rivers


def draw_rivers(d, rivers):
    for path in rivers:
        pts = path
        for _ in range(3):  # Chaikin smoothing
            pts = [pts[0]] + [p for a, b in zip(pts, pts[1:])
                              for p in ((0.75 * a[0] + 0.25 * b[0], 0.75 * a[1] + 0.25 * b[1]),
                                        (0.25 * a[0] + 0.75 * b[0], 0.25 * a[1] + 0.75 * b[1]))] + [pts[-1]]
        n = len(pts)
        for i in range(n - 1):  # widening towards the mouth
            t = i / (n - 1)
            seg = [(pts[i][0] * SS, pts[i][1] * SS), (pts[i + 1][0] * SS, pts[i + 1][1] * SS)]
            d.line(seg, fill=(38, 82, 128, 255), width=int((3.2 + 4.5 * t) * SS))
        for i in range(n - 1):
            t = i / (n - 1)
            seg = [(pts[i][0] * SS, pts[i][1] * SS), (pts[i + 1][0] * SS, pts[i + 1][1] * SS)]
            d.line(seg, fill=(86, 156, 212, 255), width=int((1.6 + 3.0 * t) * SS))


# ---- labels, title, compass, frame -------------------------------------------------------

def font(name, size):
    for candidate in (name, 'DejaVuSerif-Bold.ttf', 'DejaVuSerif.ttf'):
        try:
            return ImageFont.truetype(candidate, size)
        except OSError:
            continue
    return ImageFont.load_default()


def draw_label(d, text, x, y, size, kind):
    if kind in ('sea', 'water'):
        f = font('georgiai.ttf', int(size))
        fill, stroke, spacing = (220, 234, 248, 225), None, 0.08
    elif kind == 'title':
        f = font('georgiab.ttf', int(size))
        fill, stroke, spacing = (241, 212, 138, 255), (40, 28, 16, 255), 0.30
    elif kind == 'island':
        f = font('georgiab.ttf', int(size))
        fill, stroke, spacing = (250, 242, 222, 255), (52, 38, 24, 255), 0.04
    else:
        f = font('georgiab.ttf', int(size))
        fill, stroke, spacing = (250, 242, 222, 255), (52, 38, 24, 255), 0.22
    widths = [d.textlength(ch, font=f) for ch in text]
    total = sum(widths) + spacing * size * (len(text) - 1)
    cx = x - total / 2
    for ch, w in zip(text, widths):
        d.text((cx, y), ch, font=f, fill=fill, anchor='lm',
               stroke_width=int(size * 0.09) if stroke else 0, stroke_fill=stroke)
        cx += w + spacing * size


def draw_title(d, title, subtitle, cx, cy):
    """The map's name in the open sea, with a gold rule and a small subtitle."""
    draw_label(d, title, cx, cy, 60 * SS, 'title')
    f = font('georgiai.ttf', int(24 * SS))
    d.text((cx, cy + 62 * SS), subtitle, font=f, fill=(226, 214, 180, 230), anchor='mm')
    for side in (-1, 1):
        x0, x1 = cx + side * 132 * SS, cx + side * 262 * SS
        d.line([(x0, cy + 62 * SS), (x1, cy + 62 * SS)], fill=(214, 178, 106, 220), width=int(2 * SS))
    for x in (cx - 122 * SS, cx + 122 * SS):
        r = 5 * SS
        d.polygon([(x, cy + 62 * SS - r), (x + r, cy + 62 * SS), (x, cy + 62 * SS + r), (x - r, cy + 62 * SS)],
                  fill=(214, 178, 106, 255))


def draw_compass(d, cx, cy, r):
    d.ellipse([cx - r * 0.78, cy - r * 0.78, cx + r * 0.78, cy + r * 0.78], outline=(230, 214, 170, 200), width=4)
    for i in range(8):
        a = math.radians(i * 45 - 90)
        length = r if i % 2 == 0 else r * 0.55
        tip = (cx + length * math.cos(a), cy + length * math.sin(a))
        left = (cx + r * 0.12 * math.cos(a - math.pi / 2), cy + r * 0.12 * math.sin(a - math.pi / 2))
        right = (cx + r * 0.12 * math.cos(a + math.pi / 2), cy + r * 0.12 * math.sin(a + math.pi / 2))
        d.polygon([tip, left, (cx, cy)], fill=(240, 228, 196, 255))
        d.polygon([tip, right, (cx, cy)], fill=(150, 120, 70, 255))
    f = font('georgiab.ttf', int(r * 0.42))
    d.text((cx, cy - r * 1.22), 'N', font=f, fill=(250, 242, 222, 255), anchor='mm',
           stroke_width=3, stroke_fill=(52, 38, 24, 255))


# ---- icon images for the custom marker types -------------------------------------------

def outlined(shape: Image.Image, size=128) -> Image.Image:
    """A white glyph with a dark outline (reads on any marker colour), scaled down."""
    alpha = shape.split()[-1]
    edge = alpha.filter(ImageFilter.MaxFilter(25))
    out = Image.new('RGBA', shape.size, (0, 0, 0, 0))
    out.paste((32, 26, 22, 255), (0, 0), edge)
    out.paste((255, 255, 255, 255), (0, 0), alpha)
    return out.resize((size, size), Image.LANCZOS)


def make_icons():
    (HERE / 'icons').mkdir(exist_ok=True)
    # A fish, for fishing spots.
    fish = Image.new('RGBA', (512, 512), (0, 0, 0, 0))
    d = ImageDraw.Draw(fish)
    d.ellipse([70, 166, 370, 346], fill=(255, 255, 255, 255))
    d.polygon([(340, 256), (466, 150), (440, 256), (466, 362)], fill=(255, 255, 255, 255))
    d.polygon([(200, 175), (260, 110), (290, 180)], fill=(255, 255, 255, 255))  # fin
    icon = outlined(fish)
    di = ImageDraw.Draw(icon)
    di.ellipse([33, 52, 45, 64], fill=(32, 26, 22, 255))  # eye
    di.arc([46, 46, 76, 82], 300, 60, fill=(32, 26, 22, 255), width=4)  # gill
    icon.save(HERE / 'icons' / 'fishing.png')
    # A pickaxe, for mines: a curved head on a handle, drawn upright, then tilted.
    pick = Image.new('RGBA', (512, 512), (0, 0, 0, 0))
    d = ImageDraw.Draw(pick)
    d.rounded_rectangle([234, 150, 278, 470], radius=18, fill=(255, 255, 255, 255))  # handle
    d.arc([66, 116, 446, 436], 196, 344, fill=(255, 255, 255, 255), width=54)  # head
    d.rounded_rectangle([212, 112, 300, 178], radius=14, fill=(255, 255, 255, 255))  # socket
    pick = pick.rotate(-38, resample=Image.BICUBIC, center=(256, 290))
    outlined(pick).save(HERE / 'icons' / 'mine.png')


def main():
    make_icons()
    rnd = random.Random(SEED)
    fields = build_fields()
    base = paint_terrain(fields)
    # Vector details at 2x on top of the raster (an RGB canvas, so translucent strokes blend).
    canvas = base.resize((W * SS, H * SS), Image.BICUBIC)
    d = ImageDraw.Draw(canvas, 'RGBA')
    draw_rivers(d, trace_rivers(fields, rnd))
    draw_symbols(d, fields, rnd)
    for text, x, y, size, kind in LABELS:
        draw_label(d, text, x * SS, y * SS, size * SS, kind)
    draw_compass(d, 1880 * SS, 185 * SS, 92 * SS)
    draw_title(d, 'DEMO MAP 1', 'TOME demo', 830 * SS, 92 * SS)
    for inset, width, col in ((6, 4, (40, 30, 20, 255)), (14, 2, (214, 178, 106, 255))):
        d.rectangle([inset * SS, inset * SS, (W - inset) * SS, (H - inset) * SS], outline=col, width=int(width * SS))
    canvas.resize((W, H), Image.LANCZOS).save(HERE / 'demo-map-1.png', optimize=True)
    dry = [(x, y) for x, y in MARKERS if not fields['land'][y, x]]
    assert not dry, f'markers in the water: {dry}'
    print(f"wrote demo-map-1.png ({fields['land'].mean():.0%} land)")


if __name__ == '__main__':
    main()
