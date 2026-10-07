"""Place separate region images onto one canvas, so neighbouring regions line up.

Useful when a game's map comes as clean per-region images rather than one big
picture: each region keeps its own art, and the composed canvas is sliced like
any other map. Positions are in canvas pixels (top-left of each image); keep
the canvas size fixed as regions are added so marker positions never move.

Layout file (JSON):
    {
      "size": [4163, 2914],
      "images": [
        {"file": "source/moss-grotto.png", "x": 217, "y": 1653},
        {"file": "source/the-marrow.png",  "x": 1053, "y": 1884, "scale": 1.0}
      ]
    }

Usage:
    python compose_map.py layout.json out/composed.png

Later images are drawn over earlier ones; transparent pixels let what's
underneath show through.
"""

import argparse
import json
from pathlib import Path

from PIL import Image

Image.MAX_IMAGE_PIXELS = None


def compose(layout: dict, base_dir: Path) -> Image.Image:
    w, h = layout["size"]
    canvas = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    for item in layout["images"]:
        img = Image.open(base_dir / item["file"]).convert("RGBA")
        scale = item.get("scale", 1.0)
        if scale != 1.0:
            img = img.resize((round(img.width * scale), round(img.height * scale)), Image.Resampling.LANCZOS)
        layer = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        layer.paste(img, (round(item["x"]), round(item["y"])))
        canvas = Image.alpha_composite(canvas, layer)
        print(f"placed {item['file']} at ({item['x']}, {item['y']}) size {img.size}")
    return canvas


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("layout", type=Path)
    parser.add_argument("out", type=Path)
    args = parser.parse_args()
    layout = json.loads(args.layout.read_text(encoding="utf-8"))
    args.out.parent.mkdir(parents=True, exist_ok=True)
    compose(layout, args.layout.parent).save(args.out, optimize=True)
    print(f"wrote {args.out}")


if __name__ == "__main__":
    main()
