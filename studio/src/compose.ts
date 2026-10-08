// Composed maps: separate images placed on one canvas (tools/compose_map.py),
// and keeping everything on the map in step when pieces or the canvas move.
import type { Layout, Marker, Pack, Piece } from './model';

export interface Rect {
  x: number;
  y: number;
  w: number;
  h: number;
}

/** Where a piece covers the canvas (0×0 until its size is known). */
export function pieceRect(p: Piece): Rect {
  const s = p.scale ?? 1;
  return { x: p.x, y: p.y, w: (p.width ?? 0) * s, h: (p.height ?? 0) * s };
}

const inside = (r: Rect, x: number, y: number) => x >= r.x && y >= r.y && x < r.x + r.w && y < r.y + r.h;

/** The real (non-reference) pieces. */
export const artPieces = (layout: Layout) => layout.images.filter((p) => !p.reference);

/** The topmost art piece at a canvas point (later pieces draw on top). */
export function pieceAt(layout: Layout, x: number, y: number): Piece | undefined {
  return artPieces(layout).filter((p) => inside(pieceRect(p), x, y)).pop();
}

/** The pieces that move with `p`: its linked group, or just itself. */
export const groupOf = (layout: Layout, p: Piece) =>
  p.group ? layout.images.filter((q) => q.group === p.group) : [p];

/** Bounding box of the art pieces, or undefined if none has a size yet. */
export function contentBounds(layout: Layout): Rect | undefined {
  const rects = artPieces(layout).map(pieceRect).filter((r) => r.w > 0 && r.h > 0);
  if (!rects.length) return undefined;
  const x0 = Math.min(...rects.map((r) => r.x));
  const y0 = Math.min(...rects.map((r) => r.y));
  const x1 = Math.max(...rects.map((r) => r.x + r.w));
  const y1 = Math.max(...rects.map((r) => r.y + r.h));
  return { x: x0, y: y0, w: x1 - x0, h: y1 - y0 };
}

/** Whether any art piece sticks out past the canvas edge. */
export function overflows(layout: Layout): boolean {
  const b = contentBounds(layout);
  if (!b) return false;
  return b.x < 0 || b.y < 0 || b.x + b.w > layout.size[0] || b.y + b.h > layout.size[1];
}

/**
 * Moves what's on map `mapId` by (dx, dy): markers, region points and outlines,
 * zoom-link points on either side, and the start view. With `where`, only
 * things at points it accepts move (an outline moves if its middle does).
 * Returns how many things moved.
 */
export function shiftMapContent(
  pack: Pack,
  markers: Record<string, Marker[]>,
  mapId: string,
  dx: number,
  dy: number,
  where: (x: number, y: number) => boolean = () => true,
): number {
  let moved = 0;
  const m = pack.maps.find((x) => x.id === mapId);
  if (!m || (dx === 0 && dy === 0)) return 0;
  for (const mk of markers[mapId] ?? []) {
    if (!where(mk.x, mk.y)) continue;
    mk.x += dx;
    mk.y += dy;
    moved++;
  }
  for (const r of m.regions ?? []) {
    const hasPoint = r.x !== undefined && r.y !== undefined;
    const outlineMid = r.outline?.length
      ? [
        (Math.min(...r.outline.map((p) => p[0])) + Math.max(...r.outline.map((p) => p[0]))) / 2,
        (Math.min(...r.outline.map((p) => p[1])) + Math.max(...r.outline.map((p) => p[1]))) / 2,
      ]
      : undefined;
    const anchor = hasPoint ? [r.x!, r.y!] : outlineMid;
    if (!anchor || !where(anchor[0], anchor[1])) continue;
    if (hasPoint) {
      r.x! += dx;
      r.y! += dy;
    }
    if (r.outline) r.outline = r.outline.map(([x, y]) => [x + dx, y + dy]);
    moved++;
  }
  for (const p of m.zoomsInto?.points ?? []) {
    if (!where(p[0], p[1])) continue;
    p[0] += dx;
    p[1] += dy;
    moved++;
  }
  for (const other of pack.maps) {
    if (other.zoomsInto?.map !== mapId) continue;
    for (const p of other.zoomsInto.points) {
      if (!where(p[2], p[3])) continue;
      p[2] += dx;
      p[3] += dy;
      moved++;
    }
  }
  const v = m.initialView;
  if (v && where(v.x, v.y)) {
    v.x += dx;
    v.y += dy;
  }
  return moved;
}

/**
 * Grows the canvas so every art piece fits (or with `trim`, shrinks it to just
 * the pieces), shifting pieces and everything on the map so nothing moves
 * relative to the art. Returns the shift applied, or undefined if there's nothing to fit.
 */
export function fitCanvas(
  pack: Pack,
  markers: Record<string, Marker[]>,
  mapId: string,
  layout: Layout,
  trim = false,
): [number, number] | undefined {
  const art = contentBounds(layout);
  if (!art) return undefined;
  const b = trim ? art : (() => {
    const x0 = Math.min(0, art.x);
    const y0 = Math.min(0, art.y);
    const x1 = Math.max(layout.size[0], art.x + art.w);
    const y1 = Math.max(layout.size[1], art.y + art.h);
    return { x: x0, y: y0, w: x1 - x0, h: y1 - y0 };
  })();
  const dx = -Math.floor(b.x) || 0; // never -0
  const dy = -Math.floor(b.y) || 0;
  for (const p of layout.images) {
    p.x += dx;
    p.y += dy;
  }
  shiftMapContent(pack, markers, mapId, dx, dy);
  layout.size = [Math.ceil(b.x + b.w) + dx, Math.ceil(b.y + b.h) + dy];
  return [dx, dy];
}

/** The layout as written to layout.json: no reference guides or studio-only view settings. */
export function layoutForExport(layout: Layout, mapId: string): Layout {
  return {
    ...layout,
    map: mapId,
    images: artPieces(layout).map(({ opacity: _o, reference: _r, ...rest }) => rest),
  };
}

/** Draws the art pieces onto one canvas, like compose_map.py (browser only). */
export function composeImage(layout: Layout, images: Record<string, CanvasImageSource>): HTMLCanvasElement {
  const canvas = document.createElement('canvas');
  [canvas.width, canvas.height] = layout.size;
  const ctx = canvas.getContext('2d');
  if (!ctx) throw new Error(`This browser can't make a ${layout.size[0]}×${layout.size[1]} canvas.`);
  ctx.imageSmoothingQuality = 'high';
  for (const p of artPieces(layout)) {
    const img = images[p.file];
    if (!img) throw new Error(`The image for piece ${p.file} isn't loaded.`);
    const r = pieceRect(p);
    ctx.drawImage(img, Math.round(r.x), Math.round(r.y), Math.round(r.w), Math.round(r.h));
  }
  return canvas;
}
