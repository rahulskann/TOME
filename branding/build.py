"""Regenerate TOME's icon everywhere it's used.

    cd branding
    npm install                      # once: the SVG renderer
    ../.venv/Scripts/python build.py # needs Pillow

Writes:
  app launcher icons   app/android/app/src/main/res/mipmap-*/ic_launcher*.png
  website icons        studio/public/favicon.png, apple-touch-icon.png
  store graphics       branding/play-icon-512.png, play-feature-1024x500.png
  masters              branding/icon.svg, icon-foreground.svg, icon-background.svg, icon-1024.png
"""
import shutil
import subprocess
from pathlib import Path

from PIL import Image

import make_icon_3d

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
RES = ROOT / 'app' / 'android' / 'app' / 'src' / 'main' / 'res'
PUBLIC = ROOT / 'studio' / 'public'
PNG = HERE / 'build' / 'png'
SVG = HERE / 'build' / 'svg'

# Android densities: launcher icons are 48dp; adaptive layers are 108dp.
DENSITIES = {'mdpi': 1, 'hdpi': 1.5, 'xhdpi': 2, 'xxhdpi': 3, 'xxxhdpi': 4}


def scaled(name: str, size: int) -> Image.Image:
    return Image.open(PNG / f'{name}.png').convert('RGBA').resize((size, size), Image.LANCZOS)


def feature_graphic(seal_name: str = 'icon-seal') -> Image.Image:
    """Leather banner with the title, and the seal composited on the left."""
    banner = Image.open(PNG / 'feature-bg.png').convert('RGBA')
    seal = Image.open(PNG / f'{seal_name}.png').convert('RGBA')
    seal = seal.crop(seal.getbbox())  # the seal and its cast shadow
    k = 440 / seal.height
    seal = seal.resize((round(seal.width * k), round(seal.height * k)), Image.LANCZOS)
    banner.alpha_composite(seal, (280 - seal.width // 2, 262 - seal.height // 2))
    return banner


def main() -> None:
    make_icon_3d.write_all()
    subprocess.run(['node', 'render.mjs'], cwd=HERE, check=True, shell=False)

    for density, k in DENSITIES.items():
        out = RES / f'mipmap-{density}'
        out.mkdir(parents=True, exist_ok=True)
        scaled('icon-preview', round(48 * k)).save(out / 'ic_launcher.png')
        scaled('icon-fg', round(108 * k)).save(out / 'ic_launcher_foreground.png')
        scaled('icon-bg', round(108 * k)).save(out / 'ic_launcher_background.png')

    scaled('icon-preview', 64).save(PUBLIC / 'favicon.png')
    scaled('icon-full', 180).save(PUBLIC / 'apple-touch-icon.png')

    scaled('icon-full', 512).convert('RGB').save(HERE / 'play-icon-512.png')
    feature_graphic().convert('RGB').save(HERE / 'play-feature-1024x500.png')
    shutil.copy(PNG / 'icon-full.png', HERE / 'icon-1024.png')
    for src, dst in (('icon-full', 'icon'), ('icon-fg', 'icon-foreground'), ('icon-bg', 'icon-background')):
        shutil.copy(SVG / f'{src}.svg', HERE / f'{dst}.svg')
    print('icons, favicon and store graphics updated')


if __name__ == '__main__':
    main()
