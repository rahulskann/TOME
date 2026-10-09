"""TOME's icon: a red wax seal with depth (thickness, a pressed-in centre with a
squeezed-up lip) on a leather cover, stamped with Rahul's book-T: the T's bar is
the open book's top edge and its stem the gutter. The book is gilded; the T is
near-black with a thick gold edge, and the page lines are soft, so the T still
reads at launcher sizes.

How it works: the seal is drawn twice.
  * an "albedo" layer: the colours (red wax, optionally a gilded emblem);
  * a height map (grey = height), turned into shading by SVG lighting filters
    and laid over the colours (multiply for shadows, plain for highlights).
Render at 1024 px and scale down: lighting filters work per pixel, so the
relief only looks the same at every size if it's computed at one size.
"""
import importlib.util
from pathlib import Path

HERE = Path(__file__).parent
spec = importlib.util.spec_from_file_location('mk', HERE / 'make_icon.py')
mk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mk)
OUT = HERE / 'build' / 'svg'

LEATHER = mk.STYLES['final']


def gray(v):
    x = round(max(0.0, min(1.0, v)) * 255)
    return f'#{x:02x}{x:02x}{x:02x}'


# The emblem (same geometry as the flat icon), in its own 1024 box.
COVER = 'M304 404 L304 690 Q420 686 512 706 Q604 686 720 690 L720 404 Z'
PAGES = ['M512 404 Q444 388 364 388 Q334 388 312 394 L312 680 Q410 670 512 698 Z',
         'M512 404 Q580 388 660 388 Q690 388 712 394 L712 680 Q614 670 512 698 Z']
STACKS = ['M328 404 L328 670', 'M342 402 L342 666', 'M696 404 L696 670', 'M682 402 L682 666']
TEXT = []
for y, w in ((462, 78), (516, 62), (570, 78), (624, 58)):
    TEXT += [f'M360 {y} Q{360 + w / 2} {y - 8} {360 + w} {y}', f'M664 {y} Q{664 - w / 2} {y - 8} {664 - w} {y}']
# The stem runs past the book and is cut along the pages' bottom edge (BOOK_CUT), so it
# ends where the book does, with the cover running on underneath.
STEM = 'M482 400 L542 400 Q540 556 560 730 L464 730 Q484 556 482 400 Z'
BOOK_LEFT, BOOK_RIGHT = 304, 720  # the cover's sides

# The T's gold edge: how far it shows outside the letter, in emblem units (0 = none).
T_EDGE = 10


def t_parts(edge):
    """The stem and the bar. The bar is the book's top edge, sized so the whole letter,
    gold edge included, is exactly as wide as the book (never past it, clear of the dots)."""
    x0, x1 = BOOK_LEFT + edge, BOOK_RIGHT - edge  # the bar's bottom corners
    bar = (f'M{x0 + 2} 332 Q{x0 + 10} 344 {x0 + 44} 344 Q440 344 512 358 Q584 344 {x1 - 44} 344 '
           f'Q{x1 - 10} 344 {x1 - 2} 332 L{x1} 404 Q{x1 - 26} 392 {x1 - 56} 394 Q580 396 512 416 '
           f'Q444 396 {x0 + 56} 394 Q{x0 + 26} 392 {x0} 404 Z')
    return [STEM, bar]


BOOK_CUT = 'M0 0 L1024 0 L1024 680 L712 680 Q614 670 512 698 Q410 670 312 680 L0 680 Z'  # above the pages' bottom edge


def emblem(paint, k, uid, edge=T_EDGE):
    """paint: part -> (fill, stroke, width); for 't', (fill, edge colour). k: scale about
    the centre. uid: keeps ids unique. edge: the T's gold edge (see T_EDGE)."""
    def shape(d, part):
        fill, stroke, width = paint[part]
        return (f'<path d="{d}" fill="{fill or "none"}" stroke="{stroke}" stroke-width="{width}" '
                f'stroke-linejoin="round" stroke-linecap="round"/>')
    body = shape(COVER, 'cover') + ''.join(shape(d, 'page') for d in PAGES)
    body += ''.join(shape(d, 'stack') for d in STACKS) + ''.join(shape(d, 'text') for d in TEXT)
    # The T as one letter: outline both parts, then fill both on top, so the edge
    # runs round the outside only (no line where the bar meets the stem). The stroke
    # is centred on the outline, so it's twice the visible edge.
    t_fill, t_edge = paint['t']
    parts = t_parts(edge)
    defs = f'<clipPath id="book-{uid}" clipPathUnits="userSpaceOnUse"><path d="{BOOK_CUT}"/></clipPath>'
    letter = ''.join(f'<path d="{d}" fill="{t_edge}" stroke="{t_edge}" stroke-width="{2 * edge}" '
                     f'stroke-linejoin="round"/>' for d in parts) if edge else ''
    letter += ''.join(f'<path d="{d}" fill="{t_fill}"/>' for d in parts)
    body += f'<defs>{defs}</defs><g clip-path="url(#book-{uid})">{letter}</g>'
    return f'<g transform="translate(512 512) scale({k:.4f}) translate(-512 -519)">{body}</g>'


# Heights (0-1) for the relief; grooves are lower than what they outline.
HEIGHT = dict(
    wax=0.55, lip=0.84, disc=0.28, ring=0.46, dots=0.48,
    cover=(gray(0.40), gray(0.30), 10), page=(gray(0.52), gray(0.33), 10),
    stack=(None, gray(0.48), 5), text=(None, gray(0.42), 14), t=(gray(0.92), gray(0.80)),
)
GILT = dict(cover=('#a87a2a', '#6e4a14', 10), page=('#ecd59e', '#9c7633', 10),
            stack=(None, '#dcc185', 5), text=(None, '#a78442', 14), t=('#1e0605', '#f0c766'))


def height_group(s, blob, hid, edge=T_EDGE):
    r = lambda v: f'{v * s:.1f}'
    h = HEIGHT
    return f'''<g id="{hid}">
    <path d="{blob}" fill="{gray(h['wax'])}"/>
    <circle cx="512" cy="512" r="{r(360)}" fill="{gray(h['disc'])}"/>
    <circle cx="512" cy="512" r="{r(360)}" fill="none" stroke="{gray(h['lip'])}" stroke-width="{r(30)}"/>
    <circle cx="512" cy="512" r="{r(334)}" fill="none" stroke="{gray(h['ring'])}" stroke-width="{r(8)}"/>
    <circle cx="512" cy="512" r="{r(312)}" fill="none" stroke="{gray(h['dots'])}" stroke-width="{r(11)}"
      stroke-dasharray="0.1 {r(26)}" stroke-linecap="round"/>
    {emblem(HEIGHT, 1.05 * s, 'h', edge)}
  </g>'''


def albedo_group(s, blob, gilded, edge=T_EDGE):
    r = lambda v: f'{v * s:.1f}'
    extra = ''
    if gilded:
        extra = f'''
    <circle cx="512" cy="512" r="{r(334)}" fill="none" stroke="#c99a3e" stroke-width="{r(8)}"/>
    <circle cx="512" cy="512" r="{r(312)}" fill="none" stroke="#e2c47a" stroke-width="{r(11)}"
      stroke-dasharray="0.1 {r(26)}" stroke-linecap="round"/>
    {emblem(GILT, 1.05 * s, 'a', edge)}'''
    return f'''<g>
    <path d="{blob}" fill="url(#wax3d)"/>{extra}
  </g>'''


def filters(s, relief=26):
    chain = f'''
      <feMorphology in="SourceAlpha" operator="erode" radius="{18 * s:.1f}" result="er"/>
      <feGaussianBlur in="er" stdDeviation="{16 * s:.1f}" result="dome"/>
      <feColorMatrix in="SourceGraphic" type="luminanceToAlpha" result="lum"/>
      <feGaussianBlur in="lum" stdDeviation="{2.6 * s:.2f}" result="detail"/>
      <feComposite in="dome" in2="detail" operator="arithmetic" k1="0.6" k2="0.4" k3="0" k4="0" result="height"/>'''
    region = 'filterUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024" color-interpolation-filters="sRGB"'
    return f'''
    <radialGradient id="wax3d" cx="36%" cy="30%" r="85%">
      <stop offset="0" stop-color="#cf3b30"/><stop offset="0.55" stop-color="#a8231e"/><stop offset="1" stop-color="#7c1513"/>
    </radialGradient>
    <filter id="cast" {region}>
      <feGaussianBlur in="SourceAlpha" stdDeviation="{18 * s:.1f}"/>
      <feOffset dx="{8 * s:.1f}" dy="{26 * s:.1f}" result="b"/>
      <feFlood flood-color="#140804" flood-opacity="0.6"/>
      <feComposite in2="b" operator="in"/>
    </filter>
    <filter id="shade" {region}>{chain}
      <feDiffuseLighting in="height" surfaceScale="{relief}" diffuseConstant="1.3" lighting-color="#ffffff" result="d">
        <feDistantLight azimuth="225" elevation="50"/>
      </feDiffuseLighting>
      <feComposite in="d" in2="SourceAlpha" operator="in"/>
    </filter>
    <filter id="gloss" {region}>{chain}
      <feSpecularLighting in="height" surfaceScale="{relief}" specularConstant="1" specularExponent="34"
        lighting-color="#fff3e2" result="sp">
        <feDistantLight azimuth="225" elevation="50"/>
      </feSpecularLighting>
      <feComponentTransfer in="sp" result="sp2"><feFuncA type="linear" slope="1.25" intercept="-0.12"/></feComponentTransfer>
      <feComposite in="sp2" in2="SourceAlpha" operator="in"/>
    </filter>'''


def seal3d(s, gilded, edge=T_EDGE):
    blob = mk.wax_blob(512, 512, 440 * s)
    return f'''
  <defs>{filters(s)}
  {height_group(s, blob, 'h', edge)}
  </defs>
  <path d="{blob}" fill="#000" filter="url(#cast)"/>
  <path d="{blob}" transform="translate(0 {13 * s:.1f})" fill="#5a0e0c"/>
  {albedo_group(s, blob, gilded, edge)}
  <use href="#h" filter="url(#shade)" style="mix-blend-mode:multiply"/>
  <use href="#h" filter="url(#gloss)" opacity="0.85"/>'''


HEAD = '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 1024 1024" width="1024" height="1024">'

FEATURE_TEXT = """
<text x="556" y="226" font-family="Georgia, 'Times New Roman', serif" font-size="102" font-weight="700" letter-spacing="14" fill="#f1d48a">TOME</text>
<text x="564" y="300" font-family="Georgia, 'Times New Roman', serif" font-size="36" fill="#e9d9b8">The Offline Map Engine</text>
<text x="564" y="352" font-family="Segoe UI, Arial, sans-serif" font-size="24" fill="#cdb894">Games · hunts · local favourites</text>"""


def write_all(gilded=True, edge=T_EDGE, prefix='icon'):
    """SVGs for build.py: full/rounded icon, adaptive layers, the seal alone, the feature background.
    `prefix` lets previews of other settings sit beside the real ones."""
    OUT.mkdir(parents=True, exist_ok=True)
    c = LEATHER
    files = {
        f'{prefix}-full': mk.defs(c) + mk.background(c) + seal3d(0.92, gilded, edge),
        f'{prefix}-preview': mk.defs(c) + mk.background(c, rounded=True) + seal3d(0.92, gilded, edge),
        f'{prefix}-fg': mk.defs(c) + seal3d(0.6, gilded, edge),  # adaptive foreground: inside the 66% safe zone
        f'{prefix}-bg': mk.defs(c) + mk.background(c),
        f'{prefix}-seal': mk.defs(c) + seal3d(0.92, gilded, edge),  # for compositing (feature graphic)
    }
    for name, body in files.items():
        (OUT / f'{name}.svg').write_text(HEAD + body + '</svg>', encoding='utf-8')
    feature = (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 500" width="1024" height="500">'
        + mk.defs(c)
        + '<rect width="1024" height="500" fill="url(#leather)"/>'
        + '<rect width="1024" height="500" fill="#000" filter="url(#grain)"/>'
        + f'<rect x="24" y="24" width="976" height="452" rx="26" fill="none" stroke="{c["stitch"]}" stroke-width="5" '
        + 'stroke-dasharray="16 11" stroke-linecap="round" opacity="0.8"/>'
        + FEATURE_TEXT + '</svg>')
    (OUT / 'feature-bg.svg').write_text(feature, encoding='utf-8')


if __name__ == '__main__':
    write_all()
    print('ok')
