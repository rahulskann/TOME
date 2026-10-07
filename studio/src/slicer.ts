// Cut an image into a TOME tile pyramid in the browser.
// Same rules as tools/slicer/slice_map.py: maxZoom is native resolution; each
// lower level halves the previous one (rounding up); edge tiles are padded
// with transparency to a full tile; tiles are {z}/{x}/{y}.png.
import JSZip from 'jszip';
import { TILE_SIZE, nativeMaxZoom } from './model';

export interface Level {
  zoom: number;
  width: number;
  height: number;
  cols: number;
  rows: number;
}

/** The size of every zoom level, from maxZoom down to minZoom. */
export function pyramid(width: number, height: number, minZoom = 0, tileSize = TILE_SIZE): Level[] {
  const maxZoom = nativeMaxZoom(width, height, tileSize);
  const levels: Level[] = [];
  let w = width;
  let h = height;
  for (let z = maxZoom; z >= minZoom; z--) {
    if (z !== maxZoom) {
      w = Math.max(1, Math.ceil(w / 2));
      h = Math.max(1, Math.ceil(h / 2));
    }
    levels.push({ zoom: z, width: w, height: h, cols: Math.ceil(w / tileSize), rows: Math.ceil(h / tileSize) });
  }
  return levels;
}

export const tileCount = (levels: Level[]) => levels.reduce((n, l) => n + l.cols * l.rows, 0);

function canvas(w: number, h: number): HTMLCanvasElement {
  const c = document.createElement('canvas');
  c.width = w;
  c.height = h;
  return c;
}

const toBlob = (c: HTMLCanvasElement) =>
  new Promise<Blob>((resolve, reject) =>
    c.toBlob((b) => (b ? resolve(b) : reject(new Error('Could not encode a tile'))), 'image/png'));

/**
 * Slices `image` into a zip of tiles. Reports progress as (done, total) tiles.
 * Each level is drawn from the previous one, halving, which looks much
 * better than one big downscale.
 */
export async function sliceToZip(
  image: CanvasImageSource & { width: number; height: number },
  onProgress?: (done: number, total: number) => void,
): Promise<Blob> {
  const levels = pyramid(image.width, image.height);
  const total = tileCount(levels);
  const zip = new JSZip();
  let done = 0;

  let source = canvas(image.width, image.height);
  source.getContext('2d')!.drawImage(image, 0, 0);

  for (const level of levels) {
    if (level.width !== source.width || level.height !== source.height) {
      const smaller = canvas(level.width, level.height);
      const ctx = smaller.getContext('2d')!;
      ctx.imageSmoothingQuality = 'high';
      ctx.drawImage(source, 0, 0, level.width, level.height);
      source = smaller;
    }
    for (let x = 0; x < level.cols; x++) {
      for (let y = 0; y < level.rows; y++) {
        const tile = canvas(TILE_SIZE, TILE_SIZE);
        tile.getContext('2d')!.drawImage(source, -x * TILE_SIZE, -y * TILE_SIZE);
        zip.file(`${level.zoom}/${x}/${y}.png`, await toBlob(tile));
        onProgress?.(++done, total);
      }
      // Let the page repaint between columns.
      await new Promise((r) => setTimeout(r, 0));
    }
  }
  // PNGs are already compressed; storing them is faster and barely bigger.
  return zip.generateAsync({ type: 'blob', compression: 'STORE' });
}
