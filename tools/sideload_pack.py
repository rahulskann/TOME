"""Install a pack folder onto an Android device running a debug build of TOME.

Builds the app's on-device pack layout (see app/lib/pack/pack_store.dart) from a
pack folder whose tile archives are local files, then copies it into the app's
private storage over adb. Nothing is uploaded anywhere.

Usage:
    python sideload_pack.py ../tome-silksong [--serial DEVICE]

Pull down to refresh the pack list in the app afterwards.
"""

import argparse
import json
import os
import shutil
import subprocess
import tempfile
import zipfile
from pathlib import Path

APP_ID = "com.tomemaps.tome"
DEVICE_TMP = "/data/local/tmp/tome-sideload"


def find_adb() -> str:
    sdk = os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT")
    if sdk:
        exe = Path(sdk) / "platform-tools" / ("adb.exe" if os.name == "nt" else "adb")
        if exe.exists():
            return str(exe)
    found = shutil.which("adb")
    if not found:
        raise SystemExit("adb not found: set ANDROID_HOME or put platform-tools on PATH")
    return found


def stage(pack_dir: Path, out: Path) -> dict:
    """Write the installed layout for pack_dir into out. Returns the manifest."""
    manifest_text = (pack_dir / "pack.json").read_text(encoding="utf-8")
    manifest = json.loads(manifest_text)
    for m in manifest["maps"]:
        archive = m["tiles"]["archive"]
        if "://" in archive:
            raise SystemExit(f"map {m['id']}: tiles.archive is a URL; sideloading needs a local zip")
        src = pack_dir / archive
        if not src.exists():
            raise SystemExit(f"map {m['id']}: {src} not found - run the slicer with --zip first")
        with zipfile.ZipFile(src) as z:
            z.extractall(out / m["id"] / "tiles")
        if m.get("markers"):
            dst = out / m["markers"]
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(pack_dir / m["markers"], dst)
            snapshot = out / SNAPSHOT_DIR / m["markers"]
            snapshot.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(pack_dir / m["markers"], snapshot)
    # Written last, matching the app: a pack folder without pack.json is incomplete.
    (out / "pack.json").write_text(manifest_text, encoding="utf-8")
    return manifest


SNAPSHOT_DIR = ".sideloaded"  # copy of the markers as last sideloaded; the app ignores it


def phone_file(adb: list[str], pack_id: str, rel: str) -> object | None:
    """Parsed JSON of a file in the installed pack, or None if absent/unreadable."""
    result = subprocess.run(
        adb + ["exec-out", "run-as", APP_ID, "cat", f"files/packs/{pack_id}/{rel}"],
        capture_output=True,
    )
    if result.returncode != 0 or not result.stdout.strip():
        return None
    try:
        return json.loads(result.stdout.decode("utf-8"))
    except ValueError:
        return None


def unpulled_edits(adb: list[str], pack_dir: Path, manifest: dict) -> list[str]:
    """Maps whose markers were changed on the phone since they were sideloaded."""
    differing = []
    for m in manifest["maps"]:
        rel = m.get("markers") or f"markers/{m['id']}.json"
        current = phone_file(adb, manifest["id"], rel)
        if current is None:
            continue  # not installed yet
        baseline = phone_file(adb, manifest["id"], f"{SNAPSHOT_DIR}/{rel}")
        if baseline is None:
            # Installed before snapshots existed: compare with this folder instead.
            local = pack_dir / rel
            baseline = json.loads(local.read_text(encoding="utf-8")) if local.exists() else None
        if current != baseline:
            differing.append(m["id"])
    return differing


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("pack", type=Path, help="Pack folder containing pack.json")
    parser.add_argument("--serial", help="adb device serial, if more than one is connected")
    parser.add_argument("--force", action="store_true",
                        help="Overwrite marker edits made on the phone that haven't been pulled")
    args = parser.parse_args()

    adb = [find_adb()] + (["-s", args.serial] if args.serial else [])

    manifest = json.loads((args.pack / "pack.json").read_text(encoding="utf-8"))
    if not args.force:
        differing = unpulled_edits(adb, args.pack, manifest)
        if differing:
            raise SystemExit(
                f"The phone has marker edits that haven't been pulled (maps: {', '.join(differing)}).\n"
                f"Run: python tools/pull_markers.py {args.pack}\n"
                "then sideload again, or pass --force to discard the phone's edits.")

    def run(*cmd: str) -> None:
        subprocess.run(adb + list(cmd), check=True)

    with tempfile.TemporaryDirectory() as tmp:
        manifest = stage(args.pack, Path(tmp) / "pack")
        pack_id = manifest["id"]
        print(f"staged {manifest['name']} ({pack_id}) v{manifest['version']}")

        run("shell", "rm", "-rf", DEVICE_TMP)
        run("push", str(Path(tmp) / "pack"), DEVICE_TMP)

    # run-as works for debuggable builds and starts in the app's data directory.
    target = f"files/packs/{pack_id}"
    run("shell", "run-as", APP_ID, "sh", "-c",
        f"'rm -rf {target} && mkdir -p files/packs && cp -r {DEVICE_TMP} {target}'")
    run("shell", "rm", "-rf", DEVICE_TMP)
    print(f"installed to {APP_ID}/{target}. Pull down to refresh the pack list in TOME.")


if __name__ == "__main__":
    main()
