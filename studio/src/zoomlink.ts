// Zoom links: carrying a position between an overview and its detailed map.
// Same maths as ZoomLink in app/lib/pack/pack.dart, so "Try it" here lands
// where the app will.
import type { MapDef, Region, ZoomLink } from './model';

type Pt = [number, number, number, number];

/** Detailed-map pixels per overview pixel, from the spread of the points. */
export function linkScale(points: Pt[]): number {
  const n = points.length;
  if (n === 0) return 1;
  const mean = [0, 1, 2, 3].map((i) => points.reduce((a, p) => a + p[i] / n, 0));
  let src = 0;
  let dst = 0;
  for (const p of points) {
    src += Math.hypot(p[0] - mean[0], p[1] - mean[1]);
    dst += Math.hypot(p[2] - mean[2], p[3] - mean[3]);
  }
  return src === 0 ? 1 : dst / src;
}

function blend(points: Pt[], x: number, y: number, from: 0 | 2, k: number): [number, number] {
  const to = from === 0 ? 2 : 0;
  let wx = 0;
  let wy = 0;
  let wsum = 0;
  for (const p of points) {
    const fx = p[from];
    const fy = p[from + 1];
    const d2 = (x - fx) ** 2 + (y - fy) ** 2;
    if (d2 < 1e-9) return [p[to], p[to + 1]];
    const w = 1 / (d2 * d2); // sharp falloff: the nearest points dominate
    wx += w * (p[to] + k * (x - fx));
    wy += w * (p[to + 1] + k * (y - fy));
    wsum += w;
  }
  return [wx / wsum, wy / wsum];
}

/** A point on the overview carried to the detailed map. */
export const toDetail = (link: ZoomLink, x: number, y: number) =>
  blend(link.points, x, y, 0, linkScale(link.points));

/** A point on the detailed map carried back to the overview. */
export const fromDetail = (link: ZoomLink, x: number, y: number) =>
  blend(link.points, x, y, 2, 1 / linkScale(link.points));

/** Where a region sits: its label point, else the middle of its outline. */
export function regionCenter(r: Region): [number, number] | undefined {
  if (r.x !== undefined && r.y !== undefined) return [r.x, r.y];
  if (!r.outline?.length) return undefined;
  const xs = r.outline.map((p) => p[0]);
  const ys = r.outline.map((p) => p[1]);
  return [(Math.min(...xs) + Math.max(...xs)) / 2, (Math.min(...ys) + Math.max(...ys)) / 2];
}

const norm = (s: string) => s.toLowerCase().replace(/[^a-z0-9]+/g, '');

/**
 * Matching points from regions with the same name (or id) on both maps,
 * skipping ones already linked. A quick start: drag them to fine-tune.
 */
export function matchByRegions(overview: MapDef, detail: MapDef, existing: Pt[] = []): Pt[] {
  const found: Pt[] = [];
  const taken = new Set(existing.map((p) => `${Math.round(p[0])},${Math.round(p[1])}`));
  for (const a of overview.regions ?? []) {
    const b = (detail.regions ?? []).find((r) => r.id === a.id || norm(r.name) === norm(a.name));
    const ca = regionCenter(a);
    const cb = b && regionCenter(b);
    if (!ca || !cb || taken.has(`${Math.round(ca[0])},${Math.round(ca[1])}`)) continue;
    found.push([Math.round(ca[0]), Math.round(ca[1]), Math.round(cb[0]), Math.round(cb[1])]);
  }
  return found;
}

/** The map whose zoomsInto names `child`, if any. */
export const zoomParent = (maps: MapDef[], child: string) =>
  maps.find((m) => m.zoomsInto?.map === child && m.id !== child);
