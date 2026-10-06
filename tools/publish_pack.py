"""Point a pack at its GitHub Release and print the commands to publish it.

Tile archives are too big to commit, so they're attached to a GitHub Release
and pack.json links to them. This script:

  1. checks each map's tile zip exists in <pack>/out/ (build them with the slicer),
  2. rewrites each map's tiles.archive to the release download URL and
     tiles.archiveBytes to the zip's size,
  3. prints the git and gh commands for you to run. It doesn't run them.

Usage:
    python publish_pack.py ../demo_maps/silksong --repo rahulskann/demo_maps [--tag silksong-v0.6.0]

The tag defaults to "<folder>-v<version>", so several packs can live in one repo.
Bump "version" in pack.json before publishing an update: that's what tells the
app an update exists.
"""

import argparse
import json
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("pack", type=Path, help="Pack folder containing pack.json")
    parser.add_argument("--repo", required=True, help="GitHub owner/repo the release is in")
    parser.add_argument("--tag", help="Release tag (default: <folder>-v<version>)")
    args = parser.parse_args()

    pack_dir = args.pack.resolve()
    manifest_path = pack_dir / "pack.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    tag = args.tag or f"{pack_dir.name}-v{manifest['version']}"

    zips = []
    for m in manifest["maps"]:
        name = f"{m['id']}-tiles.zip"
        zip_path = pack_dir / "out" / name
        if not zip_path.exists():
            raise SystemExit(f"{zip_path} not found. Build it with tools/slicer/slice_map.py ... --zip")
        m["tiles"]["archive"] = f"https://github.com/{args.repo}/releases/download/{tag}/{name}"
        m["tiles"]["archiveBytes"] = zip_path.stat().st_size
        zips.append(zip_path)

    manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n",
                             encoding="utf-8", newline="\n")
    total = sum(z.stat().st_size for z in zips) / 1024 / 1024
    rel = lambda path: path.relative_to(pack_dir).as_posix()  # noqa: E731

    print(f"Updated {manifest_path} for release {tag} ({len(zips)} archives, {total:.1f} MB).\n")
    print("Now, from the pack folder:\n")
    print("  # 1. Commit and push pack.json and markers (git add / commit / push)")
    print(f"  # 2. Create the release with the tile archives:")
    print(f"  gh release create {tag} {' '.join(rel(z) for z in zips)} \\")
    print(f"      --repo {args.repo} --title \"{manifest['name']} v{manifest['version']}\" \\")
    print(f"      --notes \"Tiles for {manifest['name']} v{manifest['version']}\"")
    folder = pack_dir.name
    print(f"\nPeople can then add it in TOME with: {args.repo}/{folder}")


if __name__ == "__main__":
    main()
