# app/

TOME's Flutter app (Android, iOS, iPadOS).

## Setup (Windows)

Flutter and the Android SDK must live in paths **without spaces**, or native build
steps fail. Recommended layout:

| What | Where | Env var |
| --- | --- | --- |
| Flutter SDK | `C:\dev\flutter` (add `C:\dev\flutter\bin` to `PATH`) | |
| Pub cache | `C:\dev\pub-cache` | `PUB_CACHE` |
| Android SDK | `C:\Android\Sdk` | `ANDROID_HOME` |

Then:

    cd app
    flutter pub get
    flutter test
    flutter run          # with an emulator running or a phone connected

## Layout

| Path | What |
| --- | --- |
| `lib/pack/pack.dart` | Models for `pack.json` and markers files ([pack format](../docs/pack-format.md)) |
| `lib/pack/pack_store.dart` | On-device pack layout: install bundled packs, list and open installed ones |
| `lib/pack/packs_screen.dart` | Home screen listing installed packs; add, update, delete |
| `lib/pack/pack_location.dart` | Turns a pasted link into the pack's folder URL(s) |
| `lib/pack/pack_installer.dart` | Fetch, download (resumable), extract, install, update checks |
| `lib/pack/add_pack_screen.dart` | Add-a-pack / update screen with preview and progress |
| `lib/pack/category_icons.dart` | Built-in icon names packs can use |
| `lib/map/filter_sheet.dart`, `marker_filter.dart` | Category filter panel and remembered choices |
| `lib/map/image_coords.dart` | Image pixel ↔ map coordinate conversion |
| `lib/map/map_screen.dart` | Map view, markers, details, edit mode, export |
| `lib/map/marker_editor.dart` | Add/edit marker form |
| `assets/packs/tome.demo/` | Copy of [`examples/demo-pack`](../examples/demo-pack) bundled for Phase 1 |

Tiles are always read from files on the device (`FileTileProvider`), even for the
bundled pack, so Phase 2's downloaded packs use the same rendering path.

## Testing a pack on a phone

With a debug build installed and the phone connected over USB, copy any local pack
folder (tile zips built by the slicer) into the app, then pull down to refresh:

    python tools/sideload_pack.py ../path/to/pack

Markers added or changed in the app's edit mode are saved on the phone. Pull them
back into the pack folder before committing (sideloading refuses to overwrite
unpulled edits):

    python tools/pull_markers.py ../path/to/pack
