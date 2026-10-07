// Opening packs from a link and exporting them as a ready-to-publish zip.
import JSZip from 'jszip';
import { packFolderCandidates } from './location';
import { type Marker, type Pack, markersPath } from './model';

export interface OpenedPack {
  pack: Pack;
  markers: Record<string, Marker[]>;
  /** Where it came from: a URL folder, or the folder path inside a zip. */
  folder: string;
  /** Tile zips found alongside the pack (zip import only), by map id. */
  tileZips?: Record<string, Blob>;
}

/**
 * Every pack in a zip: a zipped pack folder, a whole repo from GitHub's
 * "Download ZIP" (packs in subfolders), or a TOME Studio export.
 * Tile zips are picked up from each map's relative archive path, or from
 * out/<map>-tiles.zip / the archive URL's file name for released packs.
 */
export async function importPackZip(data: Blob | ArrayBuffer): Promise<OpenedPack[]> {
  const zip = await JSZip.loadAsync(data);
  const manifests = Object.keys(zip.files).filter(
    (f) => (f === 'pack.json' || f.endsWith('/pack.json')) && !f.startsWith('__MACOSX/'),
  );
  if (manifests.length === 0) throw new Error('No pack.json in that zip.');

  const packs: OpenedPack[] = [];
  for (const path of manifests.sort()) {
    const folder = path.slice(0, -'pack.json'.length); // '' or 'a/b/'
    let pack: Pack;
    try {
      pack = JSON.parse(await zip.file(path)!.async('string')) as Pack;
    } catch {
      continue; // not JSON: not a pack
    }
    if (pack.schemaVersion !== 1 || !Array.isArray(pack.maps)) continue;

    const markers: Record<string, Marker[]> = {};
    const tileZips: Record<string, Blob> = {};
    for (const m of pack.maps) {
      const mk = zip.file(folder + markersPath(m));
      markers[m.id] = mk ? (JSON.parse(await mk.async('string')) as Marker[]) : [];
      const archive = m.tiles.archive;
      const candidates = archive.includes('://')
        ? [`out/${m.id}-tiles.zip`, `out/${archive.split('/').pop()}`]
        : [archive, `out/${m.id}-tiles.zip`];
      for (const c of candidates) {
        const f = zip.file(folder + c);
        if (f) {
          tileZips[m.id] = await f.async('blob');
          break;
        }
      }
    }
    packs.push({ pack, markers, folder, tileZips });
  }
  if (packs.length === 0) throw new Error('The pack.json files in that zip aren\'t TOME packs.');
  return packs;
}

/** A folder name for exporting: the folder a pack came from, else its id. */
export function exportFolderName(opened: { folder: string } | undefined, pack: Pack): string {
  const last = opened?.folder.split('/').filter(Boolean).pop();
  if (last && !last.includes(':') && !last.includes('.githubusercontent')) return last;
  return pack.id;
}

/** Fetches pack.json and its markers files from what the user typed. */
export async function openFromLink(input: string, fetcher: typeof fetch = fetch): Promise<OpenedPack> {
  const candidates = packFolderCandidates(input);
  if (candidates.length === 0) throw new Error('That doesn\'t look like a link. Try owner/repo/folder.');
  for (const folder of candidates) {
    const resp = await fetcher(folder + 'pack.json');
    if (resp.status === 404) continue;
    if (!resp.ok) throw new Error(`Couldn't download pack.json (HTTP ${resp.status}).`);
    const pack = (await resp.json()) as Pack;
    if (pack.schemaVersion !== 1) throw new Error(`This pack uses schemaVersion ${pack.schemaVersion}.`);
    const markers: Record<string, Marker[]> = {};
    for (const m of pack.maps) {
      const r = await fetcher(folder + markersPath(m));
      markers[m.id] = r.ok ? ((await r.json()) as Marker[]) : [];
    }
    return { pack, markers, folder };
  }
  throw new Error(`No pack.json found at ${candidates[0]}`);
}

const json = (value: unknown) => JSON.stringify(value, null, 2) + '\n';

/**
 * A zip laid out like a pack folder: pack.json, markers/, out/<map>-tiles.zip,
 * and PUBLISHING.md with next steps.
 *
 * `newTiles` are tile zips made here: the map now points at them. `keptTiles`
 * are existing tile zips carried through unchanged (a released map keeps its
 * release URL; the zip is included so publishing tools find it in out/).
 */
export async function exportPack(
  pack: Pack,
  markers: Record<string, Marker[]>,
  newTiles: Record<string, Blob>,
  options: { folderName?: string; keptTiles?: Record<string, Blob>; notes?: boolean } = {},
): Promise<Blob> {
  const zip = new JSZip();
  const folder = zip.folder(options.folderName || pack.id)!;
  const finalPack: Pack = structuredClone(pack);
  for (const m of finalPack.maps) {
    const tiles = newTiles[m.id];
    const kept = options.keptTiles?.[m.id];
    if (tiles) {
      m.tiles.archive = `out/${m.id}-tiles.zip`;
      m.tiles.archiveBytes = tiles.size;
      folder.file(m.tiles.archive, tiles);
    } else if (kept) {
      const local = m.tiles.archive.includes('://') ? `out/${m.id}-tiles.zip` : m.tiles.archive;
      folder.file(local, kept);
    }
    m.markers = markersPath(m);
    folder.file(m.markers, json(markers[m.id] ?? []));
  }
  folder.file('pack.json', json(finalPack));
  if (options.notes ?? true) folder.file('PUBLISHING.md', publishingNotes(finalPack, Object.keys(newTiles)));
  return zip.generateAsync({ type: 'blob' });
}

function publishingNotes(pack: Pack, sliced: string[]): string {
  const zips = sliced.map((id) => `out/${id}-tiles.zip`).join(' ');
  return `# Publishing ${pack.name}

1. Put this folder in a public GitHub repo (it can be a subfolder), e.g. \`yourname/yourrepo/${pack.id}\`.
   Keep \`out/\` out of git (add \`out/\` to .gitignore): tile zips go in a release instead.
2. From the TOME repo, point pack.json at a release and get the upload command:

       python tools/publish_pack.py path/to/${pack.id} --repo yourname/yourrepo

3. Commit and push pack.json and markers/, then run the printed \`gh release create\` command${
    zips ? ` (it uploads ${zips})` : ''
  }.
4. Anyone can now add the pack in TOME with: yourname/yourrepo/${pack.id}

To update later: bump "version" in pack.json, and repeat steps 2-3.
`;
}
