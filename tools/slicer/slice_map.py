"""Slice a large map image into a TOME tile pyramid.

The highest zoom level (maxZoom) is the image at native resolution; each lower
level halves it, down to minZoom. Tiles are written as {z}/{x}/{y}.png and
edge tiles are padded with transparency to a full tile.

Usage:
    python slice_map.py world.png out/ --map-id world --zip
"""

import argparse
import json
import math
import shutil
from pathlib import Path

from PIL import Image

# Game maps routinely exceed Pillow's decompression-bomb guard.
Image.MAX_IMAGE_PIXELS = None


def native_max_zoom(width: int, height: int, tile_size: int) -> int:
    """Smallest zoom at which the whole image fits in one tile at zoom 0."""
    return max(0, math.ceil(math.log2(max(width, height) / tile_size)))


def slice_map(image_path: Path, out_dir: Path, tile_size: int = 256, min_zoom: int = 0,
              max_zoom: int | None = None) -> dict:
    img = Image.open(image_path).convert("RGBA")
    width, height = img.size
    if max_zoom is None:
        max_zoom = native_max_zoom(width, height, tile_size)

    level = img
    tile_count = 0
    for z in range(max_zoom, min_zoom - 1, -1):
        if z != max_zoom:
            # Halve the previous level rather than resizing from the original each time.
            level = level.resize((max(1, math.ceil(level.width / 2)), max(1, math.ceil(level.height / 2))),
                                 Image.Resampling.LANCZOS)
        cols = math.ceil(level.width / tile_size)
        rows = math.ceil(level.height / tile_size)
        for x in range(cols):
            col_dir = out_dir / str(z) / str(x)
            col_dir.mkdir(parents=True, exist_ok=True)
            for y in range(rows):
                box = (x * tile_size, y * tile_size, (x + 1) * tile_size, (y + 1) * tile_size)
                tile = level.crop(box)  # crop pads out-of-bounds areas with transparency
                tile.save(col_dir / f"{y}.png", optimize=True)
                tile_count += 1
        print(f"zoom {z}: {cols}x{rows} tiles ({level.width}x{level.height}px)")

    return {
        "image": {"width": width, "height": height},
        "tileSize": tile_size,
        "minZoom": min_zoom,
        "maxZoom": max_zoom,
        "tileCount": tile_count,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("image", type=Path, help="Full-resolution map image")
    parser.add_argument("out", type=Path, help="Output directory")
    parser.add_argument("--map-id", default="world", help="Map id, used for the tiles folder and zip name")
    parser.add_argument("--tile-size", type=int, default=256)
    parser.add_argument("--min-zoom", type=int, default=0)
    parser.add_argument("--max-zoom", type=int, default=None,
                        help="Defaults to the native-resolution zoom. Values above it upscale the image.")
    parser.add_argument("--zip", action="store_true", help="Also produce <map-id>-tiles.zip for a GitHub Release")
    args = parser.parse_args()

    tiles_dir = args.out / f"{args.map_id}-tiles"
    if tiles_dir.exists():
        shutil.rmtree(tiles_dir)
    info = slice_map(args.image, tiles_dir, args.tile_size, args.min_zoom, args.max_zoom)

    map_entry = {
        "id": args.map_id,
        "name": args.map_id,
        "image": info["image"],
        "tileSize": info["tileSize"],
        "minZoom": info["minZoom"],
        "maxZoom": info["maxZoom"],
        "tiles": {"archive": f"{args.map_id}-tiles.zip", "path": "{z}/{x}/{y}.png"},
        "markers": f"markers/{args.map_id}.json",
    }

    if args.zip:
        archive = shutil.make_archive(str(args.out / f"{args.map_id}-tiles"), "zip", tiles_dir)
        map_entry["tiles"]["archiveBytes"] = Path(archive).stat().st_size
        print(f"wrote {archive}")

    print(f"\n{info['tileCount']} tiles. Add this to the \"maps\" array in pack.json:\n")
    print(json.dumps(map_entry, indent=2))


if __name__ == "__main__":
    main()
