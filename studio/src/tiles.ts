// Rebuild a map image from its tile zip (browser only: uses canvas).
import JSZip from 'jszip';
import type { MapDef } from './model';

/** Matches tile paths for a map's template, e.g. "{z}/{x}/{y}.png" at one zoom. */
export function tilePattern(template: string, zoom: number): RegExp {
  const escaped = template.replace(/[.*+?^${}()|[\]\\]/g, (c) => (c === '{' || c === '}' ? c : `\\${c}`));
  const source = escaped
    .replace('{z}', String(zoom))
    .replace('{x}', '(?<x>\\d+)')
    .replace('{y}', '(?<y>\\d+)');
  return new RegExp(`(?:^|/)${source}$`);
}

/** Draws the native-resolution tiles back into one image (a PNG blob). */
export async function imageFromTiles(tileZip: Blob, m: MapDef): Promise<Blob> {
  const zip = await JSZip.loadAsync(tileZip);
  const pattern = tilePattern(m.tiles.path, m.maxZoom);
  const canvas = document.createElement('canvas');
  canvas.width = m.image.width;
  canvas.height = m.image.height;
  const ctx = canvas.getContext('2d')!;
  let drawn = 0;
  for (const [name, file] of Object.entries(zip.files)) {
    const match = pattern.exec(name);
    if (!match?.groups || file.dir) continue;
    const tile = await createImageBitmap(await file.async('blob'));
    ctx.drawImage(tile, Number(match.groups.x) * m.tileSize, Number(match.groups.y) * m.tileSize);
    tile.close();
    drawn++;
  }
  if (drawn === 0) throw new Error(`No zoom-${m.maxZoom} tiles matching "${m.tiles.path}" in that zip.`);
  return new Promise((resolve, reject) =>
    canvas.toBlob((b) => (b ? resolve(b) : reject(new Error('Could not rebuild the image'))), 'image/png'));
}
