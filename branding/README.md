# TOME branding

The icon: a red wax seal with depth (a thick rim, a pressed-in centre with a squeezed-up
lip) on a stitched leather cover. It's stamped with Rahul's book-T: the T's bar is the open
book's top edge and its stem the gutter. The book is gilded; the T is near-black with a thick
gold edge, and the page lines are soft, so the T still reads at launcher sizes.

| File | Use |
| --- | --- |
| `icon.svg`, `icon-1024.png` | Master icon |
| `icon-foreground.svg`, `icon-background.svg` | Android adaptive-icon layers (the seal sits inside the 66% safe zone) |
| `play-icon-512.png` | Google Play store icon |
| `play-feature-1024x500.png` | Google Play feature graphic |

## Changing it

Edit `make_icon_3d.py` (seal, relief, the book-T and colours) or `make_icon.py` (shared
helpers: leather, the wax outline), then rebuild everything that uses the icon:

    cd branding
    npm install                      # once: the SVG renderer
    ../.venv/Scripts/python build.py # needs Pillow

That rewrites the app's launcher icons (`app/android/app/src/main/res/mipmap-*`), the
website's `favicon.png` and `apple-touch-icon.png`, and the store graphics here.

Earlier versions live in git history: check out an older `make_icon_3d.py` and rebuild to get
one back.

The relief comes from SVG lighting filters on a height map, which work per pixel, so
everything is rendered once at 1024 px and scaled down rather than rendered small.
