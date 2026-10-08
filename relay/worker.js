// TOME tile relay: a Cloudflare Worker that lets TOME Studio (a website) read
// GitHub release downloads, which browsers otherwise block (GitHub's storage
// doesn't send CORS headers). It only relays public GitHub *release .zip*
// files, and only to the studio's own origins, so it isn't an open proxy.
//
//   GET https://<worker>/?url=https://github.com/<owner>/<repo>/releases/download/<tag>/<file>.zip
//
// Set ALLOWED_ORIGINS (comma-separated) in the Worker's settings, e.g.
//   https://tome.rahulkannan.com,https://tome-studio.vercel.app,http://localhost:5173

const RELEASE_ZIP = /^https:\/\/github\.com\/[\w.-]+\/[\w.-]+\/releases\/download\/[^/?#]+\/[^/?#]+\.zip$/;

export function allowedOrigin(origin, setting) {
  if (!origin) return null;
  const allowed = (setting ?? '').split(',').map((s) => s.trim()).filter(Boolean);
  return allowed.includes(origin) ? origin : null;
}

function withCors(response, origin) {
  const r = new Response(response.body, response);
  if (origin) {
    r.headers.set('Access-Control-Allow-Origin', origin);
    r.headers.set('Vary', 'Origin');
    r.headers.set('Access-Control-Expose-Headers', 'Content-Length');
  }
  return r;
}

export default {
  async fetch(request, env, _ctx, fetcher = fetch) {
    const origin = allowedOrigin(request.headers.get('Origin'), env?.ALLOWED_ORIGINS);
    if (request.method === 'OPTIONS') {
      return withCors(new Response(null, {
        status: 204,
        headers: { 'Access-Control-Allow-Methods': 'GET', 'Access-Control-Max-Age': '86400' },
      }), origin);
    }
    if (request.method !== 'GET') return withCors(new Response('Method not allowed', { status: 405 }), origin);
    if (!origin) {
      // Readable by any page (it carries no data), so the studio can say why.
      const from = request.headers.get('Origin');
      return new Response(`Origin not allowed${from ? `: add ${from} to ALLOWED_ORIGINS` : ''}`, {
        status: 403,
        headers: { 'Access-Control-Allow-Origin': '*' },
      });
    }

    const target = new URL(request.url).searchParams.get('url') ?? '';
    if (!RELEASE_ZIP.test(target)) {
      return withCors(new Response('Only GitHub release .zip downloads can be relayed', { status: 400 }), origin);
    }

    // Follows GitHub's redirect to its storage server; the body streams straight
    // through, so big tile archives work within the free plan's CPU limits.
    const upstream = await fetcher(target, { redirect: 'follow', cf: { cacheEverything: true, cacheTtl: 86400 } });
    if (!upstream.ok) {
      return withCors(new Response(`GitHub returned ${upstream.status}`, { status: upstream.status === 404 ? 404 : 502 }), origin);
    }
    const headers = new Headers({ 'Content-Type': 'application/zip', 'Cache-Control': 'public, max-age=86400' });
    const length = upstream.headers.get('Content-Length');
    if (length) headers.set('Content-Length', length);
    return withCors(new Response(upstream.body, { status: 200, headers }), origin);
  },
};
