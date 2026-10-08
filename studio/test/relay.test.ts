import { describe, expect, it } from 'vitest';
// The Cloudflare Worker lives in ../relay; it's plain JS with a fetch handler.
// @ts-expect-error untyped JS module
import worker, { allowedOrigin } from '../../relay/worker.js';

const ENV = { ALLOWED_ORIGINS: 'https://tome.rahulkannan.com,http://localhost:5173' };
const RELEASE = 'https://github.com/rahulskann/demo_maps/releases/download/silksong-v0.8.0/world-tiles.zip';

function call(url: string, init: RequestInit & { origin?: string } = {}, upstream?: Response) {
  const headers = new Headers(init.headers);
  if (init.origin !== undefined) headers.set('Origin', init.origin);
  const seen: string[] = [];
  const fetcher = async (u: string) => {
    seen.push(u);
    return upstream ?? new Response('ZIPBYTES', { status: 200, headers: { 'Content-Length': '8' } });
  };
  const res = worker.fetch(new Request(url, { ...init, headers }), ENV, {}, fetcher) as Promise<Response>;
  return { res, seen };
}

const relayUrl = (target: string) => `https://relay.example/?url=${encodeURIComponent(target)}`;

describe('tile relay worker', () => {
  it('relays a GitHub release zip to an allowed origin, with CORS', async () => {
    const { res, seen } = call(relayUrl(RELEASE), { origin: 'https://tome.rahulkannan.com' });
    const r = await res;
    expect(r.status).toBe(200);
    expect(await r.text()).toBe('ZIPBYTES');
    expect(r.headers.get('Access-Control-Allow-Origin')).toBe('https://tome.rahulkannan.com');
    expect(r.headers.get('Content-Type')).toBe('application/zip');
    expect(seen).toEqual([RELEASE]);
  });

  it('refuses other origins and anything that isn\'t a release zip', async () => {
    const refused = await call(relayUrl(RELEASE), { origin: 'https://evil.example' }).res;
    expect(refused.status).toBe(403);
    expect(await refused.text()).toContain('add https://evil.example to ALLOWED_ORIGINS');
    expect((await call(relayUrl(RELEASE)).res).status).toBe(403); // no Origin
    for (const bad of [
      'https://example.com/file.zip',
      'https://github.com/a/b/archive/refs/heads/main.zip',
      'https://github.com/a/b/releases/download/v1/notes.txt',
      'https://github.com/a/b/releases/download/v1/x.zip?redirect=https://evil',
    ]) {
      const { res, seen } = call(relayUrl(bad), { origin: 'http://localhost:5173' });
      expect((await res).status, bad).toBe(400);
      expect(seen).toEqual([]);
    }
  });

  it('answers CORS preflight and passes GitHub errors through', async () => {
    const pre = await call(relayUrl(RELEASE), { method: 'OPTIONS', origin: 'http://localhost:5173' }).res;
    expect(pre.status).toBe(204);
    expect(pre.headers.get('Access-Control-Allow-Origin')).toBe('http://localhost:5173');
    const missing = await call(relayUrl(RELEASE), { origin: 'http://localhost:5173' }, new Response('', { status: 404 })).res;
    expect(missing.status).toBe(404);
  });

  it('origin list parsing', () => {
    expect(allowedOrigin('http://localhost:5173', ' http://localhost:5173 , https://x ')).toBe('http://localhost:5173');
    expect(allowedOrigin('https://y', 'https://x')).toBeNull();
    expect(allowedOrigin(null, 'https://x')).toBeNull();
    const vercel = 'https://*-rahul-kannan-s-projects.vercel.app';
    expect(allowedOrigin('https://tome-b74gflp74-rahul-kannan-s-projects.vercel.app', vercel)).not.toBeNull();
    expect(allowedOrigin('https://evil.com/x-rahul-kannan-s-projects.vercel.app', vercel)).toBeNull();
    expect(allowedOrigin('https://a.evil-rahul-kannan-s-projects.vercel.app', vercel)).toBeNull();
    expect(allowedOrigin('https://x-rahul-kannan-s-projects.vercel.app.evil.com', vercel)).toBeNull();
  });
});

describe('relay address', () => {
  it('adds https:// and drops trailing slashes', async () => {
    const { relayAddress } = await import('../src/relay');
    expect(relayAddress('tome-relay.x.workers.dev')).toBe('https://tome-relay.x.workers.dev');
    expect(relayAddress(' https://r.example/ ')).toBe('https://r.example');
    expect(relayAddress('')).toBeUndefined();
    expect(relayAddress(undefined)).toBeUndefined();
  });
});

describe('relay origin wildcards', () => {
  it('treats dots literally', () => {
    expect(allowedOrigin('https://axvercel.app', 'https://*.vercel.app')).toBeNull();
    expect(allowedOrigin('https://tomeXrahulkannanXcom', 'https://tome.rahulkannan.com')).toBeNull();
    expect(allowedOrigin('https://a-b.vercel.app', 'https://*.vercel.app')).toBe('https://a-b.vercel.app');
  });
});
