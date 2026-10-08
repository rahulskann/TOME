# TOME Studio

A website for making TOME map packs without the command line: add a map image, define
marker types, place markers and regions, then export a pack ready to publish. Everything
runs in the browser (tiles are cut on your machine); there's no server.

## Use it

1. **Maps → Add map from image.** Use the biggest, cleanest image you can.
2. **Types:** add groups (Collectibles, Navigation…) and marker types with a colour and icon.
3. **Markers → Add marker**, click the map, fill in the name, type and notes. Drag to move.
4. **Regions:** name areas (a point) or draw outlines; an outline can open another map.
5. **Pack:** set the name and id (`yourname.gamename`).
6. **Export → Download pack.** The zip has `pack.json`, `markers/`, the tile zips in `out/`,
   and `PUBLISHING.md` with the steps to put it on GitHub.

Work is saved in your browser as you go (map images aren't, so re-add them after a reload).
Ids follow names until you export, then stay fixed: players' progress is saved under them.

**Editing a pack you've already published** (round trip through a zip):

1. Zip the pack folder from your repo, including `out/*-tiles.zip` if you have them locally,
   or use GitHub's **Code → Download ZIP** (a whole repo is fine; you pick the pack).
2. **Pack → Open a pack zip.** Maps are rebuilt from their tiles. Packs downloaded from
   GitHub won't have the tiles (they're in releases): use **Maps → Load tiles zip** with the
   zip from the release.
3. Edit, then **Export**. The zip unpacks to the same folder name (e.g. `silksong`), keeps
   release links and carries the tile zips through unchanged unless you tick
   *Build new tiles*. Unzip it over the folder in your repo, check `git diff`, commit.

You can also load just `pack.json` and markers with *Open link*.

**A map built from pieces** (e.g. one clean image per region), in the **Pieces** tab:

- **Maps → Map from pieces** starts one; **Pieces → Compose this map from pieces** turns an
  existing map into one (its current image becomes a locked first piece, so nothing moves).
- **Add pieces**, then drag them into place; arrow keys nudge the selected piece (Shift: 10px).
  Set *Scale* if a piece was captured at a different size.
- **Lock** a piece once it's right; **Link with** makes pieces move as one.
- **Add reference image**: a see-through guide (say, a full community map) to line pieces up
  against. It's never exported.
- **Fit canvas to pieces** grows or shrinks the canvas; markers, areas and zoom points shift
  with it so they stay on the art. Markers on a piece also move with it (switchable).
- Export writes `layout.json` (the same format as `tools/compose_map.py`), the piece images
  under `source/`, and new tiles.

**Zooming between maps**, in the **Zoom** tab of the overview:

1. *Continue on*: the detailed map. Zooming in past the overview's sharpest level then carries
   on there; zooming out of the detailed map comes back by itself.
2. Add 4+ **matching points**: click a spot on the overview, then the same spot on the detailed
   map. *Match regions by name* pairs regions named the same on both. Drag the numbers to adjust.
3. Optionally tick the regions the detailed map covers so far.
4. **Try it**: click anywhere to jump to where the app would land.

## Develop

    npm install
    npm run dev      # http://localhost:5173
    npm test
    npm run build    # -> dist/

Keep in step with the app: `src/icons.ts` and `src/location.ts` mirror
`app/lib/pack/category_icons.dart` and `pack_location.dart`; tests check the icons and the
slicer's tile layout against `tools/slicer`.

## Deploy (Vercel)

1. Vercel → **Add New → Project** → import `rahulskann/TOME`.
2. Set **Root Directory** to `studio`. Vercel detects Vite; `vercel.json` sets the build.
3. Deploy. Every push to `main` redeploys.
4. Optional custom domain: Project → Settings → Domains → add e.g. `tome.rahulkannan.com`,
   then in Cloudflare DNS add a **CNAME** `tome` → the target Vercel shows (usually
   `cname.vercel-dns.com`), with the proxy **off** (grey cloud).
