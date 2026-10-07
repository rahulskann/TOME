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

**Editing a published pack:** Pack → *Open a published pack* with `owner/repo/folder`. The
markers and settings load from GitHub; add the map image yourself to see it (browsers can't
read GitHub release downloads). Uncheck *Build new tiles* if you only want to edit markers.

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
