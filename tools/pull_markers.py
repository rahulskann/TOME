"""Copy markers edited on the phone back into a local pack folder.

The counterpart of sideload_pack.py: after adding or fixing markers in TOME's
edit mode, run this to overwrite the pack folder's markers files with the
phone's versions, then review with `git diff` and commit.

Usage:
    python pull_markers.py ../demo_maps/silksong [--serial DEVICE]
"""

import argparse
import json
import subprocess
from pathlib import Path

from sideload_pack import APP_ID, find_adb


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("pack", type=Path, help="Pack folder containing pack.json")
    parser.add_argument("--serial", help="adb device serial, if more than one is connected")
    args = parser.parse_args()

    adb = [find_adb()] + (["-s", args.serial] if args.serial else [])
    manifest = json.loads((args.pack / "pack.json").read_text(encoding="utf-8"))
    pack_id = manifest["id"]

    for m in manifest["maps"]:
        rel = m.get("markers") or f"markers/{m['id']}.json"
        result = subprocess.run(
            adb + ["exec-out", "run-as", APP_ID, "cat", f"files/packs/{pack_id}/{rel}"],
            capture_output=True,
        )
        if result.returncode != 0 or not result.stdout.strip():
            print(f"{m['id']}: nothing on the phone, skipped")
            continue
        markers = json.loads(result.stdout.decode("utf-8"))  # refuse to write a broken file
        out = args.pack / rel
        out.parent.mkdir(parents=True, exist_ok=True)
        before = out.read_text(encoding="utf-8") if out.exists() else None
        text = json.dumps(markers, indent=2, ensure_ascii=False) + "\n"
        out.write_text(text, encoding="utf-8", newline="\n")
        status = "unchanged" if before == text else "updated"
        print(f"{m['id']}: {len(markers)} markers, {status} -> {out}")


if __name__ == "__main__":
    main()
