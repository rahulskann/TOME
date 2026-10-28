# Architecture

## Goals, in priority order

1. **Works fully offline** once a pack is downloaded. This is the reason the project exists.
2. **Native rendering** — no WebView.
3. **Any game, any map** — flat pixel coordinates, not latitude/longitude.
4. **No servers** — content is hosted on GitHub; progress lives on the device (and later
   in the user's own cloud storage).

## Stack

| Concern | Choice | Why |
| --- | --- | --- |
| App framework | Flutter (Dart) | One codebase for iOS, iPadOS and Android; renders natively with its own engine, no WebView. |
| Map widget | [`flutter_map`](https://pub.dev/packages/flutter_map) with `CrsSimple` | `CrsSimple` is a flat, non-geographic coordinate system built for exactly this. Supports tile layers, markers, polygons. |
| Tile source | `FileTileProvider` reading from app storage | Tiles are files on disk after download, so offline is the default, not a cache. |
| Local data | SQLite (`drift` or `sqflite`) | Installed packs, marker progress, user notes. |
| Pack download | GitHub Release asset (zip) + raw files | One HTTP download per map instead of thousands of tile requests. |

## How a pack gets onto the device

```
GitHub repo (owner/repo)
├── pack.json          ← fetched from raw.githubusercontent.com
├── markers/*.json     ← fetched from raw.githubusercontent.com
└── Release v1.0.0
    └── world-tiles.zip  ← downloaded once, extracted to app storage
```

1. User pastes `github.com/owner/repo` (or picks from a list).
2. App fetches `pack.json` from `https://raw.githubusercontent.com/owner/repo/<ref>/pack.json`.
3. App shows the pack's maps and total download size; user taps *Download*.
4. App downloads each map's tile zip from the release URL in `pack.json`, extracts it to
   `<app documents>/packs/<packId>/<mapId>/tiles/`, and fetches markers.
5. From then on everything is read from disk. *Check for updates* compares `pack.json`
   `version` against the installed one.

Why release assets for tiles: a map at 5 zoom levels can be thousands of PNGs. Committing
them to git bloats the repo, and fetching them one by one hits rate limits and is slow on
mobile. A single zip per map is fast to download, easy to resume, and release assets can
be up to 2 GB.

## Coordinates

Markers use **pixel coordinates of the original full-resolution image**: `x` grows right,
`y` grows down, origin at the top-left. An author can open the image in any editor, hover
over a spot, and copy the numbers.

The slicer makes `maxZoom` the zoom level where one tile pixel = one image pixel.
flutter_map's `CrsSimple` places a coordinate at `coord · 256 · 2^zoom` screen pixels, so
the app converts an image pixel `(px, py)` to map coordinates as:

```
LatLng(-py / (256 · 2^maxZoom), px / (256 · 2^maxZoom))
```

(`CrsSimple` treats latitude as "up", hence the negation.) Because the slicer picks the
smallest `maxZoom` that fits the image in one tile at zoom 0, every coordinate lands
within about ±1, well inside `latlong2`'s ±90 latitude limit, so stock `CrsSimple` works
with no custom CRS. The conversion lives in one place,
[`app/lib/map/image_coords.dart`](../app/lib/map/image_coords.dart), so authors never
deal with it.

## Progress & identity

- Each pack has a globally unique `id` (convention: `githubuser.packname`).
- Each marker has an `id` unique within its pack.
- Progress is stored keyed by `(packId, markerId)`, so packs can never collide and marker
  ids don't need a namespace prefix.
- Each pack has **save slots**, like save files in a game. On the device they live outside the
  pack folder, so installing a new pack version or sideloading never touches them:
  - `<app support>/progress/<packId>/slots.json`: `{"format": "tome-slots", "version": 1,
    "active": "<slotId>", "slots": [{"id": "main", "name": null}, ...]}`. The first slot has no
    name until a second one is added.
  - `<app support>/progress/<packId>/<slotId>.json`: `{"format": "tome-progress", "version": 2,
    "pack": "<id>", "slot": "<slotId>", "slotName": "<name>" | null,
    "markers": {"<markerId>": {"done": true | false, "updatedAt": "<ISO time>"}}}`.
    Un-ticking keeps the marker with `done: false`, so a merge can tell "never found" from
    "un-found since". This file is what "Export progress" shares, and what sync would merge.
  - Version 1 (`<app support>/progress/<packId>.json`, `"found": {"<markerId>": "<ISO time>"}`)
    becomes the first slot the first time the pack is opened.
- `<app support>/known-packs.json` lists the packs the user added and their links. Android's
  backup keeps it and the progress folder but not the packs (see `res/xml/*_rules.xml`), so a
  restored phone offers the packs for download again.

## Sync (later)

Progress is local first. Cross-device sync options to evaluate in a later phase:

- **Google Drive `appDataFolder`** (the original plan): hidden per-app folder, the user's
  own storage, free.
- **iCloud key-value / CloudKit** on Apple devices.
- **A private GitHub Gist** for users who already have GitHub signed in.

Whatever is chosen, slots are merged per marker by latest `updatedAt` (the slot files above
already have that shape). Not planned for now: Android's backup covers moving to a new phone.

## DM mode (later)

See [dm-mode.md](dm-mode.md).
