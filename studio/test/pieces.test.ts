import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import JSZip from 'jszip';
import { describe, expect, it } from 'vitest';
import {
  contentBounds, fitCanvas, groupOf, layoutForExport, overflows, pieceAt, shiftMapContent,
} from '../src/compose';
import { type Layout, type Marker, type Pack, mapForImage, newPack, validate } from '../src/model';
import { exportPack, importPackZip, layoutFileFor, layoutOwner } from '../src/packio';
import { fromDetail, linkScale, matchByRegions, toDetail, zoomParent } from '../src/zoomlink';

const silksong = resolve(__dirname, '../../../demo_maps/silksong');

function twoMaps(): { pack: Pack; markers: Record<string, Marker[]> } {
  const pack = newPack();
  const world = mapForImage('world', 'World', 1000, 800);
  const detail = mapForImage('detail', 'Detail', 2000, 1600);
  world.zoomsInto = { map: 'detail', points: [[100, 100, 200, 200], [900, 700, 1800, 1400]] };
  pack.maps.push(world, detail);
  return { pack, markers: { world: [], detail: [] } };
}

describe('zoom links (same maths as the app)', () => {
  it('lands exactly on matching points, and scales between them', () => {
    const { pack } = twoMaps();
    const link = pack.maps[0].zoomsInto!;
    expect(linkScale(link.points)).toBeCloseTo(2);
    expect(toDetail(link, 100, 100)).toEqual([200, 200]);
    const [x, y] = toDetail(link, 500, 400);
    expect(x).toBeCloseTo(1000);
    expect(y).toBeCloseTo(800);
    const back = fromDetail(link, x, y);
    expect(back[0]).toBeCloseTo(500);
    expect(back[1]).toBeCloseTo(400);
    expect(zoomParent(pack.maps, 'detail')?.id).toBe('world');
  });

  it.runIf(existsSync(silksong))('round-trips the Silksong points', () => {
    const pack = JSON.parse(readFileSync(resolve(silksong, 'pack.json'), 'utf8')) as Pack;
    const link = pack.maps.find((m) => m.id === 'world')!.zoomsInto!;
    for (const p of link.points) expect(toDetail(link, p[0], p[1])).toEqual([p[2], p[3]]);
    const [x, y] = toDetail(link, 600, 500);
    const [bx, by] = fromDetail(link, x, y);
    expect(Math.abs(bx - 600)).toBeLessThan(30);
    expect(Math.abs(by - 500)).toBeLessThan(30);
  });

  it('pairs regions named the same on both maps', () => {
    const { pack } = twoMaps();
    const [world, detail] = pack.maps;
    world.regions = [{ id: 'moss', name: 'Moss Grotto', x: 10, y: 20 }, { id: 'x', name: 'Only here', x: 1, y: 1 }];
    detail.regions = [{ id: 'mg', name: 'moss grotto', outline: [[0, 0], [100, 0], [100, 50]] }];
    expect(matchByRegions(world, detail)).toEqual([[10, 20, 50, 25]]);
    expect(matchByRegions(world, detail, [[10, 20, 0, 0]])).toEqual([]);
  });

  it('validates links', () => {
    const { pack, markers } = twoMaps();
    expect(validate(pack, markers).filter((p) => p.level === 'error')).toEqual([]);
    pack.maps[0].zoomsInto!.points.pop();
    pack.maps[0].zoomsInto!.regions = ['nope'];
    const errors = validate(pack, markers).filter((p) => p.level === 'error').map((p) => p.message);
    expect(errors.join('\n')).toMatch(/at least 2 matching points/);
    expect(errors.join('\n')).toMatch(/no longer exists/);
  });
});

describe('composed maps', () => {
  const layout = (): Layout => ({
    size: [500, 400],
    images: [
      { file: 'source/a.png', x: 0, y: 0, width: 300, height: 300 },
      { file: 'source/b.png', x: 250, y: 100, width: 200, height: 200, group: 'A' },
      { file: 'source/c.png', x: 450, y: 100, width: 100, height: 100, group: 'A' },
      { file: 'reference/full.png', x: -50, y: -50, width: 1000, height: 1000, reference: true },
    ],
  });

  it('finds the topmost art piece and linked groups', () => {
    const l = layout();
    expect(pieceAt(l, 10, 10)?.file).toBe('source/a.png');
    expect(pieceAt(l, 260, 150)?.file).toBe('source/b.png'); // b is drawn over a
    expect(pieceAt(l, 900, 900)).toBeUndefined(); // only the guide is there
    expect(groupOf(l, l.images[1]).map((p) => p.file)).toEqual(['source/b.png', 'source/c.png']);
    expect(overflows(l)).toBe(true); // c reaches x=550
    expect(contentBounds(l)).toEqual({ x: 0, y: 0, w: 550, h: 300 });
  });

  it('moves only what sits on the moved pieces', () => {
    const { pack, markers } = twoMaps();
    markers.detail = [
      { id: 'on_b', name: 'b', x: 300, y: 150 },
      { id: 'on_a', name: 'a', x: 10, y: 10 },
    ];
    pack.maps[1].regions = [{ id: 'r', name: 'R', outline: [[260, 110], [320, 110], [320, 160]] }];
    const l = layout();
    const moving = new Set(groupOf(l, l.images[1]));
    const n = shiftMapContent(pack, markers, 'detail', 5, -3, (x, y) => moving.has(pieceAt(l, x, y)!));
    expect(markers.detail.map((m) => [m.x, m.y])).toEqual([[305, 147], [10, 10]]);
    expect(pack.maps[1].regions![0].outline![0]).toEqual([265, 107]);
    expect(n).toBe(2); // the marker and the region; zoom points sit elsewhere
  });

  it('fits the canvas and keeps everything on the art', () => {
    const { pack, markers } = twoMaps();
    markers.detail = [{ id: 'm', name: 'm', x: 300, y: 150 }];
    const l = layout();
    l.images[0].x = -40; // a piece dragged past the left edge
    const shift = fitCanvas(pack, markers, 'detail', l);
    expect(shift).toEqual([40, 0]);
    expect(l.size).toEqual([590, 400]); // grows to fit, never shrinks
    expect(fitCanvas(pack, markers, 'detail', l, true)).toEqual([0, 0]);
    expect(l.size).toEqual([590, 300]); // trimmed to the pieces
    expect(l.images[0].x).toBe(0);
    expect(markers.detail[0].x).toBe(340);
    // The overview's matching points into this map moved too.
    expect(pack.maps[0].zoomsInto!.points[0]).toEqual([100, 100, 240, 200]);
  });

  it('exports without guides or view settings', () => {
    const l = layout();
    l.images[0].opacity = 0.4;
    const out = layoutForExport(l, 'detail');
    expect(out.map).toBe('detail');
    expect(out.images.map((p) => p.file)).toEqual(['source/a.png', 'source/b.png', 'source/c.png']);
    expect(out.images[0]).not.toHaveProperty('opacity');
  });

  it('matches older layout.json files to maps by size', () => {
    const { pack } = twoMaps();
    expect(layoutOwner(pack.maps, 'layout.json', { size: [2000, 1600], images: [] })?.id).toBe('detail');
    expect(layoutOwner(pack.maps, 'layout.json', { map: 'world', size: [1, 1], images: [] })?.id).toBe('world');
    pack.maps[1].layout = 'layout.json';
    expect(layoutFileFor(pack, 'world')).toBe('layout-world.json');
  });

  it('round-trips a layout and its pieces through a zip', async () => {
    const { pack, markers } = twoMaps();
    const l = layout();
    const zipBlob = await exportPack(pack, markers, {}, {
      folderName: 'demo',
      layouts: { detail: l },
      pieces: { detail: { 'source/a.png': new Blob(['A']), 'reference/full.png': new Blob(['REF']) } },
    });
    const zip = await JSZip.loadAsync(await zipBlob.arrayBuffer());
    expect(zip.file('demo/reference/full.png')).toBeNull(); // guides stay in the studio
    expect(JSON.parse(await zip.file('demo/pack.json')!.async('string')).maps[1].layout).toBe('layout.json');
    const [opened] = await importPackZip(await zipBlob.arrayBuffer());
    expect(opened.layouts?.detail.images.map((p) => p.file)).toEqual(['source/a.png', 'source/b.png', 'source/c.png']);
    expect(Object.keys(opened.pieces?.detail ?? {})).toEqual(['source/a.png']);
  });

  it.runIf(existsSync(silksong))('opens the Silksong layout.json with the pack', async () => {
    const zip = new JSZip();
    for (const f of ['pack.json', 'layout.json', 'markers/pharloom.json', 'markers/world.json']) {
      if (existsSync(resolve(silksong, f))) zip.file(`silksong/${f}`, readFileSync(resolve(silksong, f)));
    }
    zip.file('silksong/source/moss-grotto.png', readFileSync(resolve(silksong, 'source/moss-grotto.png')));
    const [opened] = await importPackZip(await zip.generateAsync({ type: 'arraybuffer' }));
    expect(opened.pack.maps.find((m) => m.id === 'pharloom')?.layout).toBe('layout.json');
    expect(opened.layouts?.pharloom.images).toHaveLength(2);
    expect(Object.keys(opened.pieces?.pharloom ?? {})).toEqual(['source/moss-grotto.png']);
  });
});
