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
import re
import shutil
import subprocess
import tempfile
import zipfile
from pathlib import Path

# The development build (flutter run / debug APK): run-as only works on debuggable
# apps, and debug builds use their own id so they sit beside the Play version.
APP_ID = "com.rahulkannan.tome.dev"
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


def guess_pack_link(manifest: dict) -> str | None:
    """owner/repo/folder from a release URL named <folder>-v<version> (as publish_pack.py does)."""
    for m in manifest["maps"]:
        match = re.match(r"^https://github\.com/([^/]+)/([^/]+)/releases/download/([^/]+)/",
                         m["tiles"]["archive"])
        if match:
            owner, repo, tag = match.groups()
            folder = re.match(r"^(.+)-v\d", tag)
            return "/".join([owner, repo] + ([folder.group(1)] if folder else []))
    return None


def stage(pack_dir: Path, out: Path) -> dict:
    """Write the installed layout for pack_dir into out. Returns the manifest."""
    manifest_text = (pack_dir / "pack.json").read_text(encoding="utf-8")
    manifest = json.loads(manifest_text)
    for m in manifest["maps"]:
        archive = m["tiles"]["archive"]
        # Published packs point at a release URL; use the local build of it.
        src = pack_dir / "out" / archive.rsplit("/", 1)[-1] if "://" in archive else pack_dir / archive
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
    # Custom type icons and marker photos (optional, like in the app: a missing
    # icon falls back to the built-in one, a missing photo isn't shown).
    images = [c.get("iconImage") for c in manifest.get("categories", [])]
    for m in manifest["maps"]:
        markers_file = pack_dir / m["markers"] if m.get("markers") else None
        if markers_file and markers_file.is_file():
            images += [mk.get("photo") for mk in json.loads(markers_file.read_text(encoding="utf-8"))]
    for image in {i for i in images if i}:
        if ".." not in image.split("/") and (pack_dir / image).is_file():
            dst = out / image
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(pack_dir / image, dst)
    # Record where the pack is published (from its release URLs), so the app's
    # "Check for update" works on sideloaded packs too.
    link = guess_pack_link(manifest)
    if link:
        (out / ".source.json").write_text(json.dumps({"input": link, "sideloaded": True}), encoding="utf-8")
    # Written last, matching the app: a pack folder without pack.json is incomplete.
    (out / "pack.json").write_text(manifest_text, encoding="utf-8")
    return manifest


SNAPSHOT_DIR = ".sideloaded"  # copy of the markers as last sideloaded; the app ignores it


def phone_json(adb: list[str], path: str) -> object | None:
    """Parsed JSON of a file in the app's data folder, or None if absent/unreadable."""
    result = subprocess.run(adb + ["exec-out", "run-as", APP_ID, "cat", path], capture_output=True)
    if result.returncode != 0 or not result.stdout.strip():
        return None
    try:
        return json.loads(result.stdout.decode("utf-8"))
    except ValueError:
        return None


def phone_file(adb: list[str], pack_id: str, rel: str) -> object | None:
    """Parsed JSON of a file in the installed pack, or None if absent/unreadable."""
    return phone_json(adb, f"files/packs/{pack_id}/{rel}")


def phone_photo(adb: list[str], pack_id: str, rel: str) -> bytes | None:
    """A photo added on the phone (kept beside the edits at its pack path), or None."""
    if ".." in rel.split("/"):
        return None
    result = subprocess.run(
        adb + ["exec-out", "run-as", APP_ID, "cat", f"files/photos/{pack_id}/{rel}"], capture_output=True)
    return result.stdout if result.returncode == 0 and result.stdout else None


def phone_edits(adb: list[str], pack_id: str) -> dict:
    """Marker edits made on the phone (files/edits/<pack>.json), kept apart from the pack."""
    edits = phone_json(adb, f"files/edits/{pack_id}.json")
    return edits if isinstance(edits, dict) else {}


def apply_edits(map_id: str, pack_markers: list, edits: dict) -> list:
    """The markers TOME shows for a map: the pack's, with the phone's edits applied
    (the same rules as app/lib/pack/marker_edits.dart: edited versions in place,
    deleted ones left out, markers only the phone has at the end)."""
    entries = edits.get("markers", {})
    in_pack = {m["id"] for m in pack_markers}
    shown = []
    for m in pack_markers:
        edit = entries.get(m["id"])
        if edit is None:
            shown.append(m)
        elif edit.get("marker") is not None:
            shown.append(edit["marker"])
    for marker_id, edit in entries.items():
        if edit.get("map") == map_id and marker_id not in in_pack and edit.get("marker") is not None:
            shown.append(edit["marker"])
    return shown


def phone_markers(adb: list[str], pack_id: str, map_id: str, rel: str, edits: dict) -> list | None:
    """What TOME shows for a map on the phone, or None if the pack isn't installed."""
    pack_markers = phone_file(adb, pack_id, rel)
    if pack_markers is None:
        return None
    return apply_edits(map_id, pack_markers, edits)


def unpulled_edits(adb: list[str], pack_dir: Path, manifest: dict) -> list[str]:
    """Maps where what the phone shows (its pack plus its marker edits) differs
    from this folder: edits made on the phone that haven't been pulled."""
    edits = phone_edits(adb, manifest["id"])
    differing = []
    for m in manifest["maps"]:
        rel = m.get("markers") or f"markers/{m['id']}.json"
        shown = phone_markers(adb, manifest["id"], m["id"], rel, edits)
        if shown is None:
            continue  # not installed yet
        local = pack_dir / rel
        here = json.loads(local.read_text(encoding="utf-8")) if local.exists() else []
        if shown != here:
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
    # The phone's marker edits and photos are now part of this folder (or were
    # discarded with --force), so they're cleared too.
    target = f"files/packs/{pack_id}"
    run("shell", "run-as", APP_ID, "sh", "-c",
        f"'rm -rf {target} files/edits/{pack_id}.json files/photos/{pack_id} "
        f"&& mkdir -p files/packs && cp -r {DEVICE_TMP} {target}'")
    run("shell", "rm", "-rf", DEVICE_TMP)
    print(f"installed to {APP_ID}/{target}. Pull down to refresh the pack list in TOME.")


if __name__ == "__main__":
    main()
