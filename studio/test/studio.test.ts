import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import JSZip from 'jszip';
import { describe, expect, it } from 'vitest';
import { CATEGORY_ICONS } from '../src/icons';
import { packFolderCandidates } from '../src/location';
import { mapForImage, nativeMaxZoom, newPack, slugify, uniqueId, validate, type Marker } from '../src/model';
import { exportFolderName, exportPack, importPackZip, openFromLink } from '../src/packio';
import { tilePattern } from '../src/tiles';
import { pyramid, tileCount } from '../src/slicer';

const repo = resolve(__dirname, '../..');

describe('matches the Python slicer', () => {
  // Counts printed by tools/slicer/slice_map.py for real maps.
  it.each([
    [2048, 1536, 3, 65], // examples/demo-pack
    [1792, 1152, 3, 52], // Silksong overview
    [7680, 5376, 5, 860], // Silksong full map
    [969, 677, 2, 17], // moss-grotto.png
  ])('%ix%i -> maxZoom %i, %i tiles', (w, h, maxZoom, tiles) => {
    expect(nativeMaxZoom(w, h)).toBe(maxZoom);
    expect(tileCount(pyramid(w, h))).toBe(tiles);
  });

  it('halves each level, rounding up', () => {
    expect(pyramid(1300, 813).map((l) => [l.zoom, l.width, l.height])).toEqual([
      [3, 1300, 813], [2, 650, 407], [1, 325, 204], [0, 163, 102],
    ]);
  });
});

describe('matches the app', () => {
  it('has the same icon names as category_icons.dart', () => {
    const dart = readFileSync(resolve(repo, 'app/lib/pack/category_icons.dart'), 'utf8');
    const names = [...dart.matchAll(/^ {2}'([a-z]+)': Icons\./gm)].map((m) => m[1]);
    expect(Object.keys(CATEGORY_ICONS)).toEqual(names);
  });

  it('parses links like pack_location.dart', () => {
    const raw = 'https://raw.githubusercontent.com';
    expect(packFolderCandidates('rahulskann/demo_maps/silksong')).toEqual([
      `${raw}/rahulskann/demo_maps/main/silksong/`,
      `${raw}/rahulskann/demo_maps/master/silksong/`,
    ]);
    expect(packFolderCandidates('https://github.com/a/b/tree/dev/packs/x')).toEqual([`${raw}/a/b/dev/packs/x/`]);
    expect(packFolderCandidates('https://github.com/a/b/blob/v2/x/pack.json')).toEqual([`${raw}/a/b/v2/x/`]);
    expect(packFolderCandidates('https://example.com/maps/x')).toEqual(['https://example.com/maps/x/']);
    expect(packFolderCandidates('hello')).toEqual([]);
    expect(packFolderCandidates('https://github.com/onlyowner')).toEqual([]);
  });
});

describe('model', () => {
  it('slugify and uniqueId', () => {
    expect(slugify("Hunter's March #2")).toBe('hunters_march_2');
    expect(uniqueId('bench', ['bench', 'bench_2'])).toBe('bench_3');
    expect(uniqueId('', [])).toBe('item');
  });

  it('a new map gets conventional paths and a sensible start view', () => {
    const m = mapForImage('world', 'World', 2048, 1536);
    expect(m.maxZoom).toBe(3);
    expect(m.tiles.archive).toBe('out/world-tiles.zip');
    expect(m.markers).toBe('markers/world.json');
    expect(m.initialView).toEqual({ x: 1024, y: 768, zoom: 1 });
  });

  it('validate catches what would break the app', () => {
    const pack = newPack();
    expect(validate(pack, {}).map((p) => p.level)).toContain('error'); // no maps
    pack.id = 'Bad Id';
    pack.maps.push(mapForImage('w', 'W', 100, 100));
    pack.maps[0].regions = [{ id: 'r', name: 'R', outline: [[0, 0], [1, 1]] }];
    const markers: Record<string, Marker[]> = {
      w: [
        { id: 'a', name: 'A', x: 5, y: 5 },
        { id: 'a', name: 'A again', x: 500, y: 5 },
      ],
    };
    const messages = validate(pack, markers).map((p) => p.message).join('\n');
    expect(messages).toMatch(/Pack id "Bad Id"/);
    expect(messages).toMatch(/used twice/);
    expect(messages).toMatch(/outside/);
    expect(messages).toMatch(/at least 3 outline points/);
  });
});

describe('packs in and out', () => {
  it('opens a pack and its markers from a link, falling back to master', async () => {
    const files: Record<string, unknown> = {
      'https://raw.githubusercontent.com/a/b/master/x/pack.json': {
        ...newPack(), id: 'a.x', maps: [mapForImage('w', 'W', 100, 100)],
      },
      'https://raw.githubusercontent.com/a/b/master/x/markers/w.json': [{ id: 'm', name: 'M', x: 1, y: 2 }],
    };
    const fakeFetch = (async (url: string) =>
      url in files
        ? new Response(JSON.stringify(files[url]), { status: 200 })
        : new Response('nope', { status: 404 })) as unknown as typeof fetch;
    const opened = await openFromLink('a/b/x', fakeFetch);
    expect(opened.pack.id).toBe('a.x');
    expect(opened.markers.w[0].id).toBe('m');
  });

  it('exports a pack folder with tiles, markers and publishing notes', async () => {
    const pack = { ...newPack(), id: 'me.game', maps: [mapForImage('w', 'W', 100, 100), mapForImage('v', 'V', 50, 50)] };
    pack.maps[1].tiles.archive = 'https://github.com/me/r/releases/download/t/v-tiles.zip';
    const blob = await exportPack(pack, { w: [{ id: 'm', name: 'M', x: 1, y: 2 }] }, { w: new Blob(['tiles']) });
    const zip = await JSZip.loadAsync(await blob.arrayBuffer());
    expect(Object.keys(zip.files).filter((f) => !f.endsWith('/')).sort()).toEqual([
      'me.game/PUBLISHING.md', 'me.game/markers/v.json', 'me.game/markers/w.json',
      'me.game/out/w-tiles.zip', 'me.game/pack.json',
    ]);
    const out = JSON.parse(await zip.file('me.game/pack.json')!.async('string'));
    expect(out.maps[0].tiles).toMatchObject({ archive: 'out/w-tiles.zip', archiveBytes: 5 });
    expect(out.maps[1].tiles.archive).toBe('https://github.com/me/r/releases/download/t/v-tiles.zip');
    expect(pack.maps[0].tiles.archiveBytes).toBeUndefined(); // the editor's copy isn't mutated
  });
});

describe('zip round trip', () => {
  // A repo zip like GitHub's "Download ZIP": two packs in subfolders, one with local tiles.
  async function repoZip() {
    const zip = new JSZip();
    const silk = { ...newPack(), id: 'me.silksong', maps: [mapForImage('world', 'World', 300, 200)] };
    silk.maps[0].tiles.archive = 'https://github.com/me/demo_maps/releases/download/silksong-v1.0.0/world-tiles.zip';
    zip.file('demo_maps-main/silksong/pack.json', JSON.stringify(silk));
    zip.file('demo_maps-main/silksong/markers/world.json', JSON.stringify([{ id: 'b', name: 'Bench', x: 5, y: 6 }]));
    zip.file('demo_maps-main/silksong/out/world-tiles.zip', 'TILES');
    const other = { ...newPack(), id: 'me.other', maps: [mapForImage('m', 'M', 10, 10)] };
    zip.file('demo_maps-main/other/pack.json', JSON.stringify(other));
    zip.file('demo_maps-main/README.md', '# not a pack');
    return zip.generateAsync({ type: 'arraybuffer' });
  }

  it('finds every pack, its markers and its local tiles', async () => {
    const packs = await importPackZip(await repoZip());
    expect(packs.map((p) => [p.pack.id, p.folder])).toEqual([
      ['me.other', 'demo_maps-main/other/'],
      ['me.silksong', 'demo_maps-main/silksong/'],
    ]);
    const silk = packs[1];
    expect(silk.markers.world[0].name).toBe('Bench');
    expect(await silk.tileZips!.world.text()).toBe('TILES');
    expect(exportFolderName(silk, silk.pack)).toBe('silksong');
    expect(packs[0].tileZips).toEqual({});
  });

  it('exports back into the same folder, keeping release links and tiles', async () => {
    const silk = (await importPackZip(await repoZip()))[1];
    silk.markers.world.push({ id: 'n', name: 'New', x: 1, y: 1 });
    const out = await exportPack(silk.pack, silk.markers, {}, {
      folderName: 'silksong', keptTiles: silk.tileZips, notes: false,
    });
    const zip = await JSZip.loadAsync(await out.arrayBuffer());
    expect(Object.keys(zip.files).filter((f) => !f.endsWith('/')).sort()).toEqual([
      'silksong/markers/world.json', 'silksong/out/world-tiles.zip', 'silksong/pack.json',
    ]);
    const again = (await importPackZip(await out.arrayBuffer()))[0];
    expect(again.pack.maps[0].tiles.archive).toBe(silk.pack.maps[0].tiles.archive);
    expect(again.markers.world.map((m) => m.id)).toEqual(['b', 'n']);
    expect(await again.tileZips!.world.text()).toBe('TILES');
  });

  it('rejects zips without a pack in them', async () => {
    const zip = new JSZip();
    zip.file('a/pack.json', '{"name": "npm thing"}');
    await expect(importPackZip(await zip.generateAsync({ type: 'arraybuffer' }))).rejects.toThrow(/aren't TOME packs/);
  });

  it('tile paths match the map\'s template at one zoom', () => {
    const re = tilePattern('{z}/{x}/{y}.png', 3);
    expect(re.exec('3/12/7.png')?.groups).toEqual({ x: '12', y: '7' });
    expect(re.exec('world-tiles/3/1/2.png')?.groups).toEqual({ x: '1', y: '2' });
    expect(re.exec('2/1/1.png')).toBeNull();
    expect(re.exec('3/1/1.pngx')).toBeNull();
  });
});
