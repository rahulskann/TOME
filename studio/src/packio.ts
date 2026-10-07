// Opening packs from a link and exporting them as a ready-to-publish zip.
import JSZip from 'jszip';
import { packFolderCandidates } from './location';
import { type Marker, type Pack, markersPath } from './model';

export interface OpenedPack {
  pack: Pack;
  markers: Record<string, Marker[]>;
  folder: string;
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
 * A zip laid out like a pack folder: pack.json, markers/, out/<map>-tiles.zip
 * for maps sliced here, and PUBLISHING.md with next steps.
 */
export async function exportPack(
  pack: Pack,
  markers: Record<string, Marker[]>,
  tileZips: Record<string, Blob>,
): Promise<Blob> {
  const zip = new JSZip();
  const folder = zip.folder(pack.id)!;
  const finalPack: Pack = structuredClone(pack);
  for (const m of finalPack.maps) {
    const tiles = tileZips[m.id];
    if (tiles) {
      m.tiles.archive = `out/${m.id}-tiles.zip`;
      m.tiles.archiveBytes = tiles.size;
      folder.file(m.tiles.archive, tiles);
    }
    m.markers = markersPath(m);
    folder.file(m.markers, json(markers[m.id] ?? []));
  }
  folder.file('pack.json', json(finalPack));
  folder.file('PUBLISHING.md', publishingNotes(finalPack, Object.keys(tileZips)));
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
