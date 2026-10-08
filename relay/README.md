# TOME tile relay (Cloudflare Worker)

Browsers can't read GitHub release downloads (GitHub's storage doesn't send CORS headers),
so TOME Studio can't load a published pack's map tiles by itself. This Worker fetches
**GitHub release `.zip` files only**, for **the studio's own addresses only**, and streams
them back with the right headers. The TOME app doesn't need it (apps aren't browsers).

Free plan: 100,000 requests a day; files stream through, so large tile zips are fine.

## Deploy (dashboard, no tools needed)

1. Cloudflare dashboard → **Workers & Pages** → **Create** → **Start with Hello World!**
2. Name it `tome-relay` → **Deploy** → **Edit code**. Replace all the code with
   [`worker.js`](worker.js) → **Deploy**.
3. Worker → **Settings → Variables and Secrets** → add a **Text** variable
   `ALLOWED_ORIGINS` = `https://tome.rahulkannan.com,https://*-rahul-kannan-s-projects.vercel.app,http://localhost:5173`
   (`*` matches one part of a name without dots, so it covers Vercel's per-deployment links).
4. Optional: **Settings → Domains & Routes → Add → Custom domain** `relay.rahulkannan.com`.
   Otherwise use the `https://tome-relay.<you>.workers.dev` address it shows.
5. In Vercel → the studio project → **Settings → Environment Variables**, add
   `VITE_TILE_RELAY` = the Worker's address, then **Redeploy** (it's read at build time).

Check it: opening `https://<worker>/?url=https://github.com/rahulskann/demo_maps/releases/download/silksong-v0.8.0/world-tiles.zip`
directly in a browser tab should say **Origin not allowed** (tabs don't send an Origin);
the studio is allowed.

## Or deploy with Wrangler

    npx wrangler login
    npx wrangler deploy        # uses wrangler.toml, including ALLOWED_ORIGINS

Tests run with the studio's: `cd ../studio && npm test`.
