"""TOME icon, flat style, and the shared drawing helpers (wax blob, leather, the book-T).

The app uses the 3D version (make_icon_3d.py); run this directly for the flat ones.

Writes SVGs for each style: full icon (store/preview), and adaptive-icon
foreground/background layers for Android.
"""
import math
from pathlib import Path

OUT = Path(__file__).parent / 'build' / 'svg'


def wax_blob(cx, cy, r):
    """An irregular wax-seal outline."""
    pts = []
    for i in range(180):
        t = i / 180 * 2 * math.pi
        rr = r * (1 + 0.035 * math.sin(5 * t + 0.6) + 0.02 * math.sin(9 * t + 2.1) + 0.012 * math.sin(14 * t))
        pts.append((cx + rr * math.cos(t), cy + rr * math.sin(t)))
    return 'M' + ' L'.join(f'{x:.1f} {y:.1f}' for x, y in pts) + ' Z'


def emblem(c, s=1.0, cx=512, cy=512):
    """The T: open book on top, spine below. `c` is the palette; scaled by s about the centre."""
    def T(x, y):
        return f'{cx + (x - 512) * s:.1f} {cy + (y - 512) * s:.1f}'
    sw = 14 * s
    left = f'M{T(506, 372)} Q{T(400, 300)} {T(262, 318)} L{T(262, 414)} Q{T(400, 398)} {T(506, 452)} Z'
    right = f'M{T(518, 372)} Q{T(624, 300)} {T(762, 318)} L{T(762, 414)} Q{T(624, 398)} {T(518, 452)} Z'
    lline = f'M{T(292, 344)} Q{T(410, 322)} {T(488, 382)}'
    rline = f'M{T(732, 344)} Q{T(614, 322)} {T(536, 382)}'
    x, y, w, h = cx + (462 - 512) * s, cy + (428 - 512) * s, 100 * s, 330 * s
    bands = ''.join(
        f'<line x1="{x + 10 * s:.1f}" y1="{cy + (yy - 512) * s:.1f}" x2="{x + w - 10 * s:.1f}" y2="{cy + (yy - 512) * s:.1f}" '
        f'stroke="{c["line"]}" stroke-width="{10 * s:.1f}" stroke-linecap="round"/>'
        for yy in (474, 496, 690, 712))
    return f'''
  <g stroke="{c['edge']}" stroke-width="{sw:.1f}" stroke-linejoin="round" fill="url(#mark)">
    <path d="{left}"/><path d="{right}"/>
    <rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" rx="{24 * s:.1f}"/>
  </g>
  <g fill="none" stroke="{c['line']}" stroke-width="{9 * s:.1f}" stroke-linecap="round">
    <path d="{lline}"/><path d="{rline}"/>
  </g>
  {bands}'''


def book_t(c, s=1.0):
    """Rahul's second sketch: a bold serif T standing over an open book, its stem
    running down the gutter. Drawn in a 1024 box and scaled by s about the centre."""
    page = c.get('page', '#f3e2b8')
    page_lo = c.get('page_lo', '#d9bf86')
    ink = c.get('ink', '#8a6a3a')
    t_fill = c.get('t_fill', '#2a0a08')
    lines = []
    for i, y in enumerate((456, 498, 540, 582, 624)):
        w = 92 if i % 2 == 0 else 74
        lines.append(f'<path d="M{362} {y} Q{362 + w / 2} {y - 8} {362 + w} {y}"/>')
        lines.append(f'<path d="M{662} {y} Q{662 - w / 2} {y - 8} {662 - w} {y}"/>')
    return f'''
  <g transform="translate(512 512) scale({s}) translate(-512 -519)">
    <g filter="url(#shadow)">
      <!-- cover, peeking out under the pages -->
      <path d="M296 404 L296 696 Q420 692 512 714 Q604 692 728 696 L728 404 Z" fill="{c['mark']}" stroke="{c['edge']}" stroke-width="12" stroke-linejoin="round"/>
      <!-- page blocks, hanging from the T's bar -->
      <path d="M512 404 Q444 388 364 388 Q334 388 312 394 L312 680 Q410 670 512 698 Z" fill="url(#page)" stroke="{c['edge']}" stroke-width="10" stroke-linejoin="round"/>
      <path d="M512 404 Q580 388 660 388 Q690 388 712 394 L712 680 Q614 670 512 698 Z" fill="url(#page)" stroke="{c['edge']}" stroke-width="10" stroke-linejoin="round"/>
    </g>
    <!-- stacked page edges -->
    <g fill="none" stroke="{page_lo}" stroke-width="5" stroke-linecap="round">
      <path d="M328 404 L328 670"/><path d="M342 402 L342 666"/>
      <path d="M696 404 L696 670"/><path d="M682 402 L682 666"/>
    </g>
    <!-- text lines -->
    <g fill="none" stroke="{ink}" stroke-width="8" stroke-linecap="round" opacity="0.7">{''.join(lines)}</g>
    <!-- the T: its bar is the book's top edge (dipping to the gutter, curling up at
         the ends like page corners); its stem runs down the gutter. Outlined as one
         letter: both parts stroked first, then both filled, so the gold edge runs
         round the outside only, with no line where the bar meets the stem. -->
    <g fill="{c['mark_hi']}" stroke="{c['mark_hi']}" stroke-width="22" stroke-linejoin="round">
      <path d="M486 396 L538 396 Q536 560 556 708 L468 708 Q488 560 486 396 Z"/>
      <path d="M304 330 Q314 344 350 344 Q440 344 512 358 Q584 344 674 344 Q710 344 720 330 L722 398 Q694 386 660 388 Q580 390 512 408 Q444 390 364 388 Q330 386 302 398 Z"/>
    </g>
    <g fill="{t_fill}">
      <path d="M486 396 L538 396 Q536 560 556 708 L468 708 Q488 560 486 396 Z"/>
      <path d="M304 330 Q314 344 350 344 Q440 344 512 358 Q584 344 674 344 Q710 344 720 330 L722 398 Q694 386 660 388 Q580 390 512 408 Q444 390 364 388 Q330 386 302 398 Z"/>
    </g>
  </g>'''


def defs(c):
    return f'''<defs>
    <radialGradient id="wax" cx="40%" cy="35%" r="75%">
      <stop offset="0" stop-color="{c['wax_hi']}"/><stop offset="1" stop-color="{c['wax']}"/>
    </radialGradient>
    <radialGradient id="disc" cx="45%" cy="40%" r="70%">
      <stop offset="0" stop-color="{c['disc_hi']}"/><stop offset="1" stop-color="{c['disc']}"/>
    </radialGradient>
    <linearGradient id="mark" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{c['mark_hi']}"/><stop offset="1" stop-color="{c['mark']}"/>
    </linearGradient>
    <radialGradient id="leather" cx="45%" cy="40%" r="80%">
      <stop offset="0" stop-color="{c.get('bg_hi', c['bg'])}"/><stop offset="1" stop-color="{c['bg']}"/>
    </radialGradient>
    <linearGradient id="page" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{c.get('page', '#f3e2b8')}"/><stop offset="1" stop-color="{c.get('page_lo', '#d9bf86')}"/>
    </linearGradient>
    <filter id="grain" x="0" y="0" width="100%" height="100%">
      <feTurbulence type="fractalNoise" baseFrequency="0.9" numOctaves="3" seed="7" result="n"/>
      <feColorMatrix in="n" type="matrix" values="0 0 0 0 0  0 0 0 0 0  0 0 0 0 0  0 0 0 {c.get('grain', 0)} 0"/>
      <feComposite in2="SourceGraphic" operator="in"/>
    </filter>
    <filter id="shadow" x="-20%" y="-20%" width="140%" height="140%">
      <feDropShadow dx="0" dy="10" stdDeviation="14" flood-color="#000" flood-opacity="0.45"/>
    </filter>
  </defs>'''


def seal(c, s=1.0):
    """Seal (blob, ring, stitching, emblem) scaled by s about the centre."""
    r = 440 * s
    return f'''
  <g filter="url(#shadow)">
    <path d="{wax_blob(512, 512, r)}" fill="url(#wax)"/>
  </g>
  <circle cx="512" cy="512" r="{360 * s:.1f}" fill="url(#disc)" stroke="{c['edge']}" stroke-width="{16 * s:.1f}"/>
  <circle cx="512" cy="512" r="{332 * s:.1f}" fill="none" stroke="{c['dots']}" stroke-width="{7 * s:.1f}"
    stroke-dasharray="{0.1 * s:.2f} {24 * s:.1f}" stroke-linecap="round" opacity="0.85"/>
  {book_t(c, 1.05 * s) if c.get('book') else emblem(c, s)}'''


def background(c, rounded=False):
    shape = '<rect width="1024" height="1024" rx="{}" fill="url(#leather)"/>'.format(180 if rounded else 0)
    grain = (f'<rect width="1024" height="1024" rx="{180 if rounded else 0}" fill="#000" filter="url(#grain)"/>'
             if c.get('grain') else '')
    stitch = ''
    if c.get('stitch'):
        stitch = (f'<rect x="70" y="70" width="884" height="884" rx="{130 if rounded else 40}" fill="none" '
                  f'stroke="{c["stitch"]}" stroke-width="10" stroke-dasharray="26 18" stroke-linecap="round" opacity="0.8"/>')
    return shape + grain + stitch


STYLES = {
    # Blue wax seal on dark, with gold stitching (the original design, recoloured).
    'blue': dict(bg='#1c1a19', bg_hi='#2a2725', wax='#1f4a85', wax_hi='#3a6fb8', disc='#1b3f73', disc_hi='#2b5c9e',
                 edge='#0f2547', dots='#e2c47a', mark='#7fa6dc', mark_hi='#b4cdf0', line='#163463'),
    # Brown leather cover, stitched edge, a blind-stamped seal with a gold-foil T.
    'leather': dict(bg='#4a2c1a', bg_hi='#7a4a2c', grain=0.22, stitch='#d8b46a',
                    wax='#5a341f', wax_hi='#7d4b2c', disc='#4f2d1a', disc_hi='#6b3e24',
                    edge='#2b170c', dots='#d8b46a', mark='#c99a3e', mark_hi='#f1d48a', line='#7a5520'),
    # Leather cover with a red wax seal and a gold T (chosen).
    'final': dict(book=True, bg='#4a2c1a', bg_hi='#7a4a2c', grain=0.22, stitch='#d8b46a',
                  wax='#7e1c1c', wax_hi='#b0352f', disc='#701818', disc_hi='#952824',
                  edge='#3a0a0a', dots='#e2c47a', mark='#c99a3e', mark_hi='#f1d48a', line='#7a4a14'),
}

if __name__ == '__main__':
    OUT.mkdir(parents=True, exist_ok=True)
    for name, c in STYLES.items():
        head = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">'
        # Store / preview icon: full square (Play rounds the corners itself).
        (OUT / f'{name}-full.svg').write_text(head + defs(c) + background(c) + seal(c, 0.92) + '</svg>')
        # Rounded preview, roughly how a launcher shows it.
        (OUT / f'{name}-preview.svg').write_text(head + defs(c) + background(c, rounded=True) + seal(c, 0.92) + '</svg>')
        # Adaptive icon layers: the foreground must fit the central 66% safe zone.
        (OUT / f'{name}-fg.svg').write_text(head + defs(c) + seal(c, 0.6) + '</svg>')
        (OUT / f'{name}-bg.svg').write_text(head + defs(c) + background(c) + '</svg>')
    print('ok')
