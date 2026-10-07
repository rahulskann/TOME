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
- [x] Add a pack by GitHub link (owner/repo[/folder], github.com, tree/blob, raw, any https folder);
      preview name, maps and download size
- [x] Download tile zips with progress, cancel and resume; extract streaming; swap in atomically so a
      failed download never breaks the installed version
- [x] Check for update (version compare), warn before replacing on-device marker edits; delete
- [x] `tools/publish_pack.py`: point pack.json at a GitHub Release and print the `gh` commands
- [ ] Download a region's detailed map only when wanted (big games stay small on the phone)
- [ ] Fully usable in airplane mode

## Phase 3.5 — TOME Studio (website)
- [x] Browser-based pack maker in `studio/`: add map images (tiles cut in the browser), types,
      markers, regions; open a published pack by link; export a ready-to-publish zip
- [ ] Deploy on Vercel (`tome.rahulkannan.com`)
- [ ] Place region images on a canvas (compose) in the browser
- [ ] Sign in with GitHub to publish directly (small serverless function)

## Phase 4 — Seamless detailed maps
For games whose in-game map is geometrically consistent when zoomed in (Silksong is):
- [ ] Stitch tool: combine overlapping zoomed-in screenshots into one large map
- [ ] Slicer support for very large images (sparse tiles, streaming) so a whole world zooms
      continuously from overview to individual rooms
- [x] Overview zooms seamlessly into a detailed whole-world map (`zoomsInto` matching points)

## Phase 5 — Sync & more
- [ ] Cross-device progress sync (see architecture.md)
- [ ] In-app region outline drawing for pack authors
- [ ] Layers (e.g. underground) as switchable maps sharing markers
- [ ] DM mode (see dm-mode.md)
