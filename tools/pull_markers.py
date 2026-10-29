"""Copy markers edited on the phone back into a local pack folder.

The counterpart of sideload_pack.py: after adding or fixing markers in TOME's
edit mode, run this to overwrite the pack folder's markers files with what the
phone shows (its copy of the pack with the edits made there applied), and copy
in the photos added on the phone, then review with `git diff` and commit.
Sideloading afterwards clears the phone's edits and photos, since they're now
part of the pack.

Usage:
    python pull_markers.py ../demo_maps/silksong [--serial DEVICE]
"""

import argparse
import json
from pathlib import Path

from sideload_pack import find_adb, phone_edits, phone_markers, phone_photo


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("pack", type=Path, help="Pack folder containing pack.json")
    parser.add_argument("--serial", help="adb device serial, if more than one is connected")
    args = parser.parse_args()

    adb = [find_adb()] + (["-s", args.serial] if args.serial else [])
    manifest = json.loads((args.pack / "pack.json").read_text(encoding="utf-8"))
    pack_id = manifest["id"]

    edits = phone_edits(adb, pack_id)
    for m in manifest["maps"]:
        rel = m.get("markers") or f"markers/{m['id']}.json"
        markers = phone_markers(adb, pack_id, m["id"], rel, edits)
        if markers is None:
            print(f"{m['id']}: nothing on the phone, skipped")
            continue
        out = args.pack / rel
        out.parent.mkdir(parents=True, exist_ok=True)
        before = out.read_text(encoding="utf-8") if out.exists() else None
        text = json.dumps(markers, indent=2, ensure_ascii=False) + "\n"
        out.write_text(text, encoding="utf-8", newline="\n")
        status = "unchanged" if before == text else "updated"
        print(f"{m['id']}: {len(markers)} markers, {status} -> {out}")

        # Photos taken or chosen on the phone go to the same path in the pack.
        for marker in markers:
            photo = marker.get("photo")
            data = phone_photo(adb, pack_id, photo) if photo else None
            if data is None:
                continue
            dst = args.pack / photo
            if dst.exists() and dst.read_bytes() == data:
                continue
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_bytes(data)
            print(f"  photo for {marker['name']} -> {dst}")


if __name__ == "__main__":
    main()
