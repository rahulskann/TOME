# Roadmap

## Phase 0 — Foundations
- [x] Repo, docs, pack format v1
- [x] Tile slicer tool
- [x] Install Flutter, scaffold `app/`
- [ ] CI: lint + test on push (GitHub Actions)

## Phase 1 — Offline map viewer
- [x] Load a map from a pack bundled in the app's assets
- [x] `flutter_map` + `CrsSimple`, smooth pan/zoom (tested on Android phone; iPad untested)
- [x] Render markers from the markers file, filter by category
- [x] Tap marker → details sheet

## Phase 2 — Make it a real tracker (current)
Modelled on what makes MapGenie / mapsilksong / the Genshin maps useful, without copying them.
- [x] Category groups, icons, filter panel with counts, remembered filters
- [x] Edit mode: add, edit, move, delete markers; export; pull edits to PC
- [x] Wiki links per pack / category / marker; content stays offline
- [x] World overview with regions: tap or zoom in to open a region's detailed map, zoom out to return
- [x] Progress tracking: long-press or details button to mark found, found/total per category,
      group, map and pack, hide found, export progress (stored by `(packId, markerId)`)
- [ ] Import progress from a file
- [x] Search markers by name, type, map/region and notes across the whole pack; jump to and highlight the result
- [x] Credited wiki text: region/area descriptions, "What's here" lists, "About <type>" notes
- [x] Map info sheet: map description, regions/areas with notes, found counts, Go there / Open map
- [ ] "Show only this region" filter
- [ ] Tap a marker → highlight all markers of the same type
- [ ] Marker clustering when zoomed out on dense maps

## Phase 3 — Sharing packs (the travel use case)
- [ ] Add a pack by GitHub URL, including a subfolder (e.g. `owner/demo_maps/silksong`); preview size
- [ ] Download + extract tile zips with progress and resume; installed packs list, delete, update
- [ ] Download a region's detailed map only when wanted (big games stay small on the phone)
- [ ] Fully usable in airplane mode

## Phase 4 — Seamless detailed maps
For games whose in-game map is geometrically consistent when zoomed in (Silksong is):
- [ ] Stitch tool: combine overlapping zoomed-in screenshots into one large map
- [ ] Slicer support for very large images (sparse tiles, streaming) so a whole world zooms
      continuously from overview to individual rooms
- [ ] Optional schematic overview kept as a separate map

## Phase 5 — Sync & more
- [ ] Cross-device progress sync (see architecture.md)
- [ ] In-app region outline drawing for pack authors
- [ ] Layers (e.g. underground) as switchable maps sharing markers
- [ ] DM mode (see dm-mode.md)
