import 'leaflet/dist/leaflet.css';
import './style.css';
import L from 'leaflet';
import { field, h, icon, select } from './dom';
import { CATEGORY_ICONS, materialIcon } from './icons';
import {
  type Category,
  type MapDef,
  type Marker,
  type Pack,
  type Region,
  mapForImage,
  newPack,
  slugify,
  uniqueId,
  validate,
} from './model';
import { type OpenedPack, exportFolderName, exportPack, importPackZip, openFromLink } from './packio';
import { sliceToZip } from './slicer';
import { fetchViaRelay, relayable } from './relay';
import { imageFromTiles } from './tiles';

// ---- State ------------------------------------------------------------------

type Tab = 'pack' | 'types' | 'maps' | 'markers' | 'regions' | 'export';
type Mode = 'view' | 'addMarker' | 'addPoint' | 'drawOutline';

interface LoadedImage {
  url: string;
  width: number;
  height: number;
  bitmap: ImageBitmap;
  /** Build tiles from this image on export (off when it's only a preview). */
  buildTiles: boolean;
}

const STORAGE_KEY = 'tome-studio.v1';

const state = {
  pack: newPack() as Pack,
  markers: {} as Record<string, Marker[]>,
  images: {} as Record<string, LoadedImage>,
  activeMap: undefined as string | undefined,
  tab: 'pack' as Tab,
  mode: 'view' as Mode,
  selectedMarker: undefined as string | undefined,
  selectedRegion: undefined as string | undefined,
  draft: [] as [number, number][],
  status: '',
  /** Ids created in the studio and not yet exported ("kind:id"); they follow their names. */
  fresh: new Set<string>(),
  /** Existing tile zips (from an imported zip or loaded per map), carried through on export. */
  keptTiles: {} as Record<string, Blob>,
  /** Where the open pack came from: sets the export folder name. */
  origin: undefined as { folder: string; fromZip: boolean } | undefined,
  exportFolder: '',
  /** Packs found in an imported zip, waiting for the user to pick one. */
  choices: [] as OpenedPack[],
};

function restore() {
  try {
    const saved = localStorage.getItem(STORAGE_KEY);
    if (!saved) return;
    const data = JSON.parse(saved) as {
      pack: Pack; markers: Record<string, Marker[]>; activeMap?: string; fresh?: string[];
    };
    state.pack = data.pack;
    state.fresh = new Set(data.fresh ?? []);
    state.markers = data.markers ?? {};
    state.activeMap = data.activeMap ?? data.pack.maps[0]?.id;
    state.status = "Restored your last session. Maps that aren't published need their image re-added " +
      "(images aren't saved in the browser).";
  } catch {
    /* corrupt or blocked storage: start fresh */
  }
}

let saveTimer: number | undefined;
function save() {
  clearTimeout(saveTimer);
  saveTimer = window.setTimeout(() => {
    try {
      localStorage.setItem(
        STORAGE_KEY,
        JSON.stringify({
          pack: state.pack, markers: state.markers, activeMap: state.activeMap, fresh: [...state.fresh],
        }),
      );
    } catch {
      /* storage full or blocked; the export still works */
    }
  }, 300);
}

/** Change state, then redraw. `full` also rebuilds the map layers. */
function update(change: () => void, full = true) {
  change();
  save();
  renderSidebar();
  if (full) renderMapLayers();
}

const activeMap = (): MapDef | undefined => state.pack.maps.find((m) => m.id === state.activeMap);
const markersOf = (id: string) => (state.markers[id] ??= []);
const category = (id?: string): Category | undefined => state.pack.categories?.find((c) => c.id === id);
const allMarkerIds = () => Object.values(state.markers).flat().map((m) => m.id);

/**
 * Renames an item; if it was created here and not yet exported, its id follows
 * the new name (ids can't change once published, but nothing refers to it yet).
 */
function rename(
  kind: 'marker' | 'cat' | 'group' | 'region',
  item: { id: string; name: string },
  name: string,
  taken: string[],
  relink: (oldId: string, newId: string) => void = () => {},
) {
  item.name = name;
  if (!state.fresh.has(`${kind}:${item.id}`)) return;
  const next = uniqueId(slugify(name) || kind, taken.filter((t) => t !== item.id));
  if (next === item.id) return;
  state.fresh.delete(`${kind}:${item.id}`);
  state.fresh.add(`${kind}:${next}`);
  const old = item.id;
  item.id = next;
  relink(old, next);
}

// ---- Map view -----------------------------------------------------------------

const map = L.map('map', { crs: L.CRS.Simple, minZoom: -6, maxZoom: 6, zoomSnap: 0.25, attributionControl: false });
const layers = L.layerGroup().addTo(map);
let fittedFor: string | undefined;

// Image pixels <-> Leaflet coordinates, relative to the map's native zoom.
const toLatLng = (m: MapDef, x: number, y: number) => L.latLng(-y / 2 ** m.maxZoom, x / 2 ** m.maxZoom);
const toPixel = (m: MapDef, ll: L.LatLng): [number, number] => [
  Math.round(ll.lng * 2 ** m.maxZoom),
  Math.round(-ll.lat * 2 ** m.maxZoom),
];

function markerIcon(mk: Marker, selected: boolean): L.DivIcon {
  const c = category(mk.category);
  const el = h(
    'div',
    { class: `pin${selected ? ' selected' : ''}`, style: { background: c?.color ?? '#7fb2f0' } },
    icon(materialIcon(c?.icon)),
  );
  return L.divIcon({ html: el, className: '', iconSize: [28, 28], iconAnchor: [14, 14] });
}

function renderMapLayers() {
  layers.clearLayers();
  const m = activeMap();
  if (!m) return;
  const bounds = L.latLngBounds(toLatLng(m, 0, m.image.height), toLatLng(m, m.image.width, 0));
  const img = state.images[m.id];
  if (img) {
    L.imageOverlay(img.url, bounds).addTo(layers);
  } else {
    L.rectangle(bounds, { color: '#555', weight: 1, dashArray: '6 6', fill: false, interactive: false }).addTo(layers);
  }
  if (fittedFor !== m.id) {
    map.fitBounds(bounds, { padding: [20, 20] });
    fittedFor = m.id;
  }

  for (const r of m.regions ?? []) {
    const selected = r.id === state.selectedRegion;
    const style = { color: selected ? '#ffd166' : '#b9a8e0', weight: selected ? 3 : 2, fillOpacity: 0.08 };
    const select = () => update(() => ((state.selectedRegion = r.id), (state.tab = 'regions')));
    if (r.outline?.length) {
      L.polygon(r.outline.map(([x, y]) => toLatLng(m, x, y)), style).on('click', select).addTo(layers);
    }
    if (r.x !== undefined && r.y !== undefined) {
      L.circleMarker(toLatLng(m, r.x, r.y), { ...style, radius: 6, fillOpacity: 0.6 })
        .bindTooltip(r.name, { permanent: true, direction: 'right', className: 'region-label' })
        .on('click', select)
        .addTo(layers);
    }
  }
  if (state.draft.length) {
    L.polyline(state.draft.map(([x, y]) => toLatLng(m, x, y)), { color: '#ffd166', dashArray: '4 4' }).addTo(layers);
  }

  for (const mk of markersOf(m.id)) {
    const marker = L.marker(toLatLng(m, mk.x, mk.y), {
      icon: markerIcon(mk, mk.id === state.selectedMarker),
      draggable: true,
      title: mk.name,
    });
    marker.on('click', () => update(() => ((state.selectedMarker = mk.id), (state.tab = 'markers'))));
    marker.on('dragend', () => {
      const [x, y] = toPixel(m, marker.getLatLng());
      update(() => Object.assign(mk, { x, y }));
    });
    marker.addTo(layers);
  }
}

map.on('click', (e: L.LeafletMouseEvent) => {
  const m = activeMap();
  if (!m) return;
  const [x, y] = toPixel(m, e.latlng);
  if (x < 0 || y < 0 || x > m.image.width || y > m.image.height) return;
  switch (state.mode) {
    case 'addMarker': {
      const cat = state.pack.categories?.[0];
      const name = cat ? cat.name.replace(/s$/, '') : 'Marker';
      const id = uniqueId(slugify(`${cat?.id ?? 'marker'}_${name}`), allMarkerIds());
      update(() => {
        markersOf(m.id).push({ id, name, x, y, category: cat?.id });
        state.fresh.add(`marker:${id}`);
        state.selectedMarker = id;
        state.mode = 'view';
        state.tab = 'markers';
      });
      break;
    }
    case 'addPoint': {
      const id = uniqueId('area', (m.regions ?? []).map((r) => r.id));
      update(() => {
        (m.regions ??= []).push({ id, name: 'New area', x, y });
        state.fresh.add(`region:${id}`);
        state.selectedRegion = id;
        state.mode = 'view';
      });
      break;
    }
    case 'drawOutline':
      update(() => state.draft.push([x, y]));
      break;
  }
});

document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && state.mode !== 'view') update(() => ((state.mode = 'view'), (state.draft = [])));
});

// ---- Sidebar ------------------------------------------------------------------

const sidebar = document.getElementById('sidebar')!;
const TABS: [Tab, string, string][] = [
  ['pack', 'Pack', 'inventory_2'],
  ['types', 'Types', 'category'],
  ['maps', 'Maps', 'map'],
  ['markers', 'Markers', 'place'],
  ['regions', 'Regions', 'crop_free'],
  ['export', 'Export', 'download'],
];

function renderSidebar() {
  const focused = document.activeElement as HTMLElement | null;
  const focusKey = focused?.dataset?.key;
  const body = {
    pack: packTab,
    types: typesTab,
    maps: mapsTab,
    markers: markersTab,
    regions: regionsTab,
    export: exportTab,
  }[state.tab]();
  const parts = [
    h(
      'nav',
      { class: 'tabs' },
      ...TABS.map(([id, label, ic]) =>
        h('button', { class: state.tab === id ? 'active' : '', onclick: () => update(() => (state.tab = id), false) },
          icon(ic), label)),
    ),
    state.status || progressLines.size
      ? h('div', { class: 'status' }, state.status,
        h('div', { class: 'progress-lines' }, [...progressLines.values()].join('\n')))
      : null,
    modeBanner(),
    h('div', { class: 'tab-body' }, body),
  ];
  sidebar.replaceChildren(...parts.filter((p): p is HTMLElement => p !== null));
  // Keep typing focus across re-renders.
  if (focusKey) sidebar.querySelector<HTMLElement>(`[data-key="${focusKey}"]`)?.focus();
}

function modeBanner() {
  const text = {
    view: '',
    addMarker: 'Click the map to place the marker.',
    addPoint: 'Click the map to place the area\'s name point.',
    drawOutline: `Click the map to add outline points (${state.draft.length} so far).`,
  }[state.mode];
  if (!text) return null;
  return h('div', { class: 'mode' }, text,
    state.mode === 'drawOutline'
      ? h('button', { disabled: state.draft.length < 3, onclick: finishOutline }, 'Finish')
      : null,
    h('button', { class: 'ghost', onclick: () => update(() => ((state.mode = 'view'), (state.draft = []))) }, 'Cancel'));
}

/** A field that re-renders only the map (not the sidebar) as you type. */
const keyed = <T extends HTMLElement>(el: T, key: string): T => {
  el.querySelectorAll('input, textarea, select').forEach((i) => ((i as HTMLElement).dataset.key = key));
  return el;
};
const live = (change: () => void) => {
  change();
  save();
  renderMapLayers();
};

// -- Pack
function loadOpened(opened: OpenedPack, fromZip: boolean) {
  update(() => {
    for (const img of Object.values(state.images)) URL.revokeObjectURL(img.url);
    state.pack = opened.pack;
    state.markers = opened.markers;
    state.images = {};
    state.keptTiles = { ...(opened.tileZips ?? {}) };
    state.fresh.clear();
    state.choices = [];
    state.origin = { folder: opened.folder, fromZip };
    state.exportFolder = exportFolderName(opened, opened.pack);
    state.activeMap = opened.pack.maps[0]?.id;
    fittedFor = undefined;
    const withTiles = Object.keys(state.keptTiles).length;
    const fromRelease = opened.pack.maps.filter((m) => !state.keptTiles[m.id] && relayable(m.tiles.archive));
    const missing = opened.pack.maps.length - withTiles - fromRelease.length;
    state.status = [
      `Opened ${opened.pack.name}.`,
      withTiles + fromRelease.length ? 'Loading map images…' : '',
      missing
        ? `${missing} map(s) have no tiles here (GitHub keeps them in releases, not in the repo or its ` +
          'Download ZIP). In the Maps tab, use "Get tiles from release", then "Load tiles zip".'
        : '',
    ].filter(Boolean).join(' ');
  });
  for (const m of opened.pack.maps) {
    if (state.keptTiles[m.id]) void showTiles(m);
    else if (relayable(m.tiles.archive)) void loadFromRelease(m);
  }
}

/** Fetches a map's tile zip from its GitHub release (via the relay) and shows it. */
async function loadFromRelease(m: MapDef) {
  try {
    const blob = await fetchViaRelay(m.tiles.archive, (got, total) => {
      const mb = (n: number) => (n / 1048576).toFixed(1);
      setProgress(m.id, `${m.name}: downloading ${mb(got)}${total ? ` / ${mb(total)}` : ''} MB`);
    });
    state.keptTiles[m.id] = blob;
    setProgress(m.id, `${m.name}: building the image…`);
    await showTiles(m);
  } catch (e) {
    update(() => (state.status = `${m.name}: ${(e as Error).message}`), false);
  } finally {
    setProgress(m.id, undefined);
  }
}

/** Per-map progress lines, shown in the status box without re-rendering on every chunk. */
const progressLines = new Map<string, string>();
function setProgress(mapId: string, line: string | undefined) {
  if (line) progressLines.set(mapId, line);
  else progressLines.delete(mapId);
  const box = sidebar.querySelector<HTMLElement>('.progress-lines');
  if (box) box.textContent = [...progressLines.values()].join('\n');
}

/** Rebuilds a map's image from its tile zip so it can be seen and edited. */
async function showTiles(m: MapDef) {
  try {
    const blob = await imageFromTiles(state.keptTiles[m.id], m);
    const bitmap = await createImageBitmap(blob);
    update(() => {
      state.images[m.id] = { url: URL.createObjectURL(blob), bitmap, width: bitmap.width, height: bitmap.height, buildTiles: false };
      if (![...progressLines.keys()].some((id) => id !== m.id)) {
        state.status = state.status.replace(/(Loading map images…|Rebuilding .* from its tiles…)\s*/, '');
      }
      if (m.id === state.activeMap) fittedFor = undefined;
    });
  } catch (e) {
    update(() => (state.status = `${m.name}: ${(e as Error).message}`), false);
  }
}

function zipPicker(onFile: (f: File) => void) {
  const input = h('input', { type: 'file', accept: '.zip,application/zip' });
  input.addEventListener('change', () => input.files?.[0] && onFile(input.files[0]));
  input.click();
}

async function openZip(file: File) {
  try {
    update(() => (state.status = `Reading ${file.name}…`), false);
    const found = await importPackZip(file);
    if (found.length === 1) loadOpened(found[0], true);
    else update(() => ((state.choices = found), (state.status = `${found.length} packs in that zip: pick one.`)), false);
  } catch (e) {
    update(() => (state.status = (e as Error).message), false);
  }
}

function packTab() {
  const p = state.pack;
  const link = h('input', { type: 'text', placeholder: 'owner/repo/folder' });
  const open = async () => {
    try {
      update(() => (state.status = 'Opening…'), false);
      loadOpened(await openFromLink(link.value), false);
    } catch (e) {
      update(() => (state.status = (e as Error).message), false);
    }
  };
  return h('div', {},
    h('h2', {}, 'Pack'),
    keyed(field('Name', p.name, (v) => live(() => (p.name = v))), 'p.name'),
    keyed(field('Id', p.id, (v) => live(() => (p.id = v.toLowerCase())),
      { hint: 'yourname.gamename. Never change it after publishing: progress is saved under it.' }), 'p.id'),
    keyed(field('Game', p.game ?? '', (v) => live(() => (p.game = v))), 'p.game'),
    keyed(field('Author', p.author ?? '', (v) => live(() => (p.author = v))), 'p.author'),
    keyed(field('Version', p.version, (v) => live(() => (p.version = v)),
      { hint: 'Bump it (e.g. 1.0.0 → 1.1.0) to offer players an update.' }), 'p.version'),
    keyed(field('Description', p.description ?? '', (v) => live(() => (p.description = v)), { multiline: true }), 'p.desc'),
    keyed(field('Wiki base URL', p.wiki ?? '', (v) => live(() => (p.wiki = v || undefined)),
      { placeholder: 'https://example.wiki/w/', hint: 'Optional. Types and markers can then link wiki pages by name.' }), 'p.wiki'),
    h('h3', {}, 'Open a pack'),
    h('p', { class: 'help' },
      'A zip of the pack folder (or a whole repo from GitHub\'s Code → Download ZIP). ' +
      'Include out/*-tiles.zip to see the maps straight away.'),
    h('button', { onclick: () => zipPicker(openZip) }, icon('folder_zip'), 'Open a pack zip'),
    state.choices.length
      ? h('div', { class: 'card editing' },
        h('small', { class: 'muted' }, 'This zip has several packs:'),
        ...state.choices.map((c) => h('button', { class: 'item', onclick: () => loadOpened(c, true) },
          icon('inventory_2'), `${c.pack.name}`, h('small', { class: 'muted' }, ` ${c.folder || '(top level)'}`))))
      : null,
    h('p', { class: 'help' }, 'Or load just pack.json and markers from GitHub:'),
    h('div', { class: 'row' }, link, h('button', { onclick: open }, 'Open link')),
    h('h3', {}, 'Start over'),
    h('button', {
      class: 'danger',
      onclick: () => confirm('Start a new, empty pack? Unsaved changes are lost.') &&
        update(() => {
          state.pack = newPack();
          state.markers = {};
          state.images = {};
          state.fresh.clear();
          state.keptTiles = {};
          state.origin = undefined;
          state.exportFolder = '';
          state.choices = [];
          state.activeMap = undefined;
          state.status = '';
        }),
    }, 'New pack'),
  );
}

// -- Types
function typesTab() {
  const p = state.pack;
  const groups = (p.categoryGroups ??= []);
  const cats = (p.categories ??= []);
  const groupOptions: [string, string][] = [['', '(no group)'], ...groups.map((g): [string, string] => [g.id, g.name])];
  const iconOptions: [string, string][] = Object.keys(CATEGORY_ICONS).map((k) => [k, k]);
  return h('div', {},
    h('h2', {}, 'Groups'),
    h('p', { class: 'help' }, 'Headings for the filter panel, e.g. Collectibles, Navigation.'),
    ...groups.map((g, i) => h('div', { class: 'row' },
      keyed(field('', g.name, (v) => live(() => rename('group', g, v, groups.map((x) => x.id), (old, id) => {
        for (const c of cats) if (c.group === old) c.group = id;
      }))), `g${i}`),
      h('button', { class: 'ghost', title: 'Delete', onclick: () => update(() => groups.splice(i, 1)) }, icon('delete')))),
    h('button', {
      onclick: () => update(() => {
        const id = uniqueId('group', groups.map((g) => g.id));
        groups.push({ id, name: 'New group' });
        state.fresh.add(`group:${id}`);
      }),
    }, icon('add'), 'Add group'),
    h('h2', {}, 'Marker types'),
    h('p', { class: 'help' }, 'What players can filter and check off: benches, chests, keys…'),
    ...cats.map((c, i) => h('div', { class: 'card' },
      h('div', { class: 'row' },
        h('input', { type: 'color', value: c.color ?? '#7fb2f0', oninput: (e: Event) =>
          live(() => (c.color = (e.target as HTMLInputElement).value.toUpperCase())) }),
        icon(materialIcon(c.icon), c.color),
        keyed(field('', c.name, (v) => live(() => rename('cat', c, v, cats.map((x) => x.id), (old, id) => {
          for (const mk of Object.values(state.markers).flat()) if (mk.category === old) mk.category = id;
        }))), `c${i}`)),
      h('div', { class: 'row' },
        select('Icon', c.icon ?? 'circle', iconOptions, (v) => update(() => (c.icon = v))),
        select('Group', c.group ?? '', groupOptions, (v) => update(() => (c.group = v || undefined)))),
      keyed(field('Wiki page', c.wiki ?? '', (v) => live(() => (c.wiki = v || undefined)),
        { placeholder: 'optional' }), `cw${i}`),
      h('small', { class: 'muted' }, `id: ${c.id}`),
      h('button', {
        class: 'ghost danger', onclick: () => confirm(`Delete type "${c.name}"?`) && update(() => cats.splice(i, 1)),
      }, icon('delete'), 'Delete'))),
    h('button', {
      onclick: () => update(() => {
        const id = uniqueId('type', cats.map((c) => c.id));
        cats.push({ id, name: 'New type', icon: 'star', color: '#E8B04A', group: groups[0]?.id });
        state.fresh.add(`cat:${id}`);
      }),
    }, icon('add'), 'Add type'),
    h('p', { class: 'help' }, 'Ids follow names until you export; after that they stay fixed, because saved progress refers to them.'),
  );
}

// -- Maps
async function addImage(file: File, existing?: MapDef) {
  update(() => (state.status = `Reading ${file.name}…`), false);
  const bitmap = await createImageBitmap(file);
  const url = URL.createObjectURL(file);
  update(() => {
    let m = existing;
    if (!m) {
      const name = file.name.replace(/\.[^.]+$/, '').replace(/[-_]+/g, ' ');
      const id = uniqueId(slugify(name) || 'map', state.pack.maps.map((x) => x.id));
      m = mapForImage(id, name.replace(/\b\w/g, (ch) => ch.toUpperCase()), bitmap.width, bitmap.height);
      state.pack.maps.push(m);
      state.markers[m.id] = [];
    } else if (m.image.width !== bitmap.width || m.image.height !== bitmap.height) {
      state.status = `Note: this image is ${bitmap.width}×${bitmap.height}, but ${m.name} was ` +
        `${m.image.width}×${m.image.height}. Marker positions are in pixels, so they may be off.`;
    }
    if (!existing || state.status.startsWith('Reading')) state.status = '';
    const old = state.images[m.id];
    if (old) URL.revokeObjectURL(old.url);
    state.images[m.id] = { url, bitmap, width: bitmap.width, height: bitmap.height, buildTiles: !existing };
    state.activeMap = m.id;
    fittedFor = undefined;
  });
}

function filePicker(onFile: (f: File) => void) {
  const input = h('input', { type: 'file', accept: 'image/*' });
  input.addEventListener('change', () => input.files?.[0] && onFile(input.files[0]));
  input.click();
}

function mapsTab() {
  const maps = state.pack.maps;
  return h('div', {},
    h('h2', {}, 'Maps'),
    h('p', { class: 'help' }, 'Add a map image (PNG/JPG, as big and clean as you can). Tiles are made in your browser when you export.'),
    ...maps.map((m) => {
      const img = state.images[m.id];
      return h('div', { class: `card${m.id === state.activeMap ? ' active' : ''}` },
        h('div', { class: 'row' },
          h('button', { class: 'ghost', onclick: () => update(() => ((state.activeMap = m.id), (fittedFor = undefined))) },
            icon(m.id === state.activeMap ? 'radio_button_checked' : 'radio_button_unchecked')),
          keyed(field('', m.name, (v) => live(() => (m.name = v))), `m.${m.id}`)),
        h('small', { class: 'muted' },
          `${m.image.width}×${m.image.height}px · zoom 0–${m.maxZoom} · ${markersOf(m.id).length} markers · id ${m.id}`),
        img
          ? h('label', { class: 'check' },
            h('input', { type: 'checkbox', checked: img.buildTiles, onchange: (e: Event) =>
              update(() => (img.buildTiles = (e.target as HTMLInputElement).checked), false) }),
            'Build new tiles from this image on export')
          : h('small', { class: 'warn' }, 'No image loaded: markers show on a blank outline.'),
        !img && relayable(m.tiles.archive)
          ? h('button', { onclick: () => void loadFromRelease(m) }, icon('cloud_download'), 'Load from release')
          : !img && /^https?:\/\//.test(m.tiles.archive)
            ? h('a', { class: 'button', href: m.tiles.archive, target: '_blank', rel: 'noopener' },
              icon('cloud_download'), 'Get tiles from release')
            : null,
        !img
          ? h('button', {
            onclick: () => zipPicker((f) => {
              state.keptTiles[m.id] = f;
              update(() => (state.status = `Rebuilding ${m.name} from its tiles…`), false);
              void showTiles(m);
            }),
          }, icon('folder_zip'), 'Load tiles zip')
          : null,
        h('div', { class: 'row' },
          h('button', { onclick: () => filePicker((f) => addImage(f, m)) }, icon('image'), img ? 'Replace image' : 'Add image'),
          h('button', {
            class: 'ghost', title: 'Use the current view as where this map opens',
            onclick: () => update(() => {
              const [x, y] = toPixel(m, map.getCenter());
              m.initialView = { x, y, zoom: Math.round(map.getZoom() + m.maxZoom) };
            }, false),
          }, icon('center_focus_strong'), 'Set start view'),
          h('button', {
            class: 'ghost danger',
            onclick: () => confirm(`Delete map "${m.name}" and its markers?`) && update(() => {
              state.pack.maps.splice(state.pack.maps.indexOf(m), 1);
              delete state.markers[m.id];
              delete state.images[m.id];
              if (state.activeMap === m.id) state.activeMap = state.pack.maps[0]?.id;
            }),
          }, icon('delete'))),
      );
    }),
    h('button', { onclick: () => filePicker((f) => addImage(f)) }, icon('add_photo_alternate'), 'Add map from image'),
  );
}

// -- Markers
function markersTab() {
  const m = activeMap();
  if (!m) return h('p', { class: 'help' }, 'Add a map first (Maps tab).');
  const list = markersOf(m.id);
  const sel = list.find((x) => x.id === state.selectedMarker);
  const catOptions: [string, string][] = [['', '(no type)'], ...(state.pack.categories ?? []).map((c): [string, string] => [c.id, c.name])];
  return h('div', {},
    h('h2', {}, `Markers · ${m.name}`),
    h('button', { class: 'primary', onclick: () => update(() => (state.mode = 'addMarker'), false) }, icon('add_location'), 'Add marker'),
    h('p', { class: 'help' }, 'Drag markers on the map to move them.'),
    sel ? markerForm(m, sel, catOptions) : null,
    h('div', { class: 'list' },
      ...list.map((mk) => h('button', {
        class: `item${mk.id === state.selectedMarker ? ' active' : ''}`,
        onclick: () => update(() => (state.selectedMarker = mk.id)),
      }, icon(materialIcon(category(mk.category)?.icon), category(mk.category)?.color), mk.name))),
  );
}

function markerForm(m: MapDef, mk: Marker, catOptions: [string, string][]) {
  return h('div', { class: 'card editing' },
    keyed(field('Name', mk.name, (v) => live(() => rename('marker', mk, v, allMarkerIds(), (_, id) => {
      state.selectedMarker = id;
    }))), 'mk.name'),
    select('Type', mk.category ?? '', catOptions, (v) => update(() => (mk.category = v || undefined))),
    keyed(field('Notes (shown offline)', mk.description ?? '', (v) => live(() => (mk.description = v || undefined)),
      { multiline: true, placeholder: 'How to reach it, what it needs…' }), 'mk.desc'),
    keyed(field('Wiki page', mk.wiki ?? '', (v) => live(() => (mk.wiki = v || undefined)), { placeholder: 'optional' }), 'mk.wiki'),
    h('label', { class: 'check' },
      h('input', { type: 'checkbox', checked: mk.trackable !== false, onchange: (e: Event) =>
        update(() => {
          if ((e.target as HTMLInputElement).checked) delete mk.trackable;
          else mk.trackable = false;
        }, false) }),
      'Can be checked off (off for benches, shops…)'),
    h('small', { class: 'muted' }, `x ${mk.x}, y ${mk.y} · id ${mk.id}`),
    h('div', { class: 'row' },
      h('button', {
        class: 'ghost danger', onclick: () => update(() => {
          markersOf(m.id).splice(markersOf(m.id).indexOf(mk), 1);
          state.selectedMarker = undefined;
        }),
      }, icon('delete'), 'Delete'),
      h('button', { class: 'ghost', onclick: () => update(() => (state.selectedMarker = undefined)) }, 'Done')),
  );
}

// -- Regions
function finishOutline() {
  const m = activeMap();
  if (!m || state.draft.length < 3) return;
  const id = uniqueId('region', (m.regions ?? []).map((r) => r.id));
  update(() => {
    (m.regions ??= []).push({ id, name: 'New region', outline: state.draft });
    state.fresh.add(`region:${id}`);
    state.draft = [];
    state.mode = 'view';
    state.selectedRegion = id;
  });
}

function regionsTab() {
  const m = activeMap();
  if (!m) return h('p', { class: 'help' }, 'Add a map first (Maps tab).');
  const regions = (m.regions ??= []);
  const sel = regions.find((r) => r.id === state.selectedRegion);
  return h('div', {},
    h('h2', {}, `Regions · ${m.name}`),
    h('p', { class: 'help' }, 'Named places, shown in the map\'s ⓘ info sheet and search. An outline can open another map.'),
    h('div', { class: 'row' },
      h('button', { onclick: () => update(() => (state.mode = 'addPoint'), false) }, icon('place'), 'Add area (point)'),
      h('button', { onclick: () => update(() => ((state.mode = 'drawOutline'), (state.draft = []))) }, icon('polyline'), 'Draw outline')),
    sel ? regionForm(m, sel) : null,
    h('div', { class: 'list' },
      ...regions.map((r) => h('button', {
        class: `item${r.id === state.selectedRegion ? ' active' : ''}`,
        onclick: () => update(() => (state.selectedRegion = r.id)),
      }, icon(r.outline?.length ? 'crop_free' : 'place'), r.name))),
  );
}

function regionForm(m: MapDef, r: Region) {
  const mapOptions: [string, string][] = [['', '(nothing)'],
    ...state.pack.maps.filter((x) => x.id !== m.id).map((x): [string, string] => [x.id, x.name])];
  return h('div', { class: 'card editing' },
    keyed(field('Name', r.name, (v) => live(() => rename('region', r, v, (m.regions ?? []).map((x) => x.id),
      (_, id) => (state.selectedRegion = id)))), 'r.name'),
    keyed(field('Notes', r.description ?? '', (v) => live(() => (r.description = v || undefined)), { multiline: true }), 'r.desc'),
    keyed(field('Wiki page', r.wiki ?? '', (v) => live(() => (r.wiki = v || undefined)), { placeholder: 'optional' }), 'r.wiki'),
    r.outline?.length
      ? select('Opens map', r.map ?? '', mapOptions, (v) => update(() => (r.map = v || undefined)))
      : h('small', { class: 'muted' }, 'Draw an outline to make a region open another map.'),
    h('small', { class: 'muted' }, `id ${r.id}`),
    h('div', { class: 'row' },
      h('button', {
        class: 'ghost danger', onclick: () => update(() => {
          m.regions!.splice(m.regions!.indexOf(r), 1);
          state.selectedRegion = undefined;
        }),
      }, icon('delete'), 'Delete'),
      h('button', { class: 'ghost', onclick: () => update(() => (state.selectedRegion = undefined)) }, 'Done')),
  );
}

// -- Export
function exportTab() {
  const problems = validate(state.pack, state.markers);
  const errors = problems.filter((p) => p.level === 'error');
  const toBuild = state.pack.maps.filter((m) => state.images[m.id]?.buildTiles);
  const progress = h('div', { class: 'muted' });
  const run = async () => {
    const tileZips: Record<string, Blob> = {};
    for (const m of toBuild) {
      const img = state.images[m.id];
      tileZips[m.id] = await sliceToZip(img.bitmap, (done, total) =>
        (progress.textContent = `Making tiles for ${m.name}: ${done} / ${total}`));
    }
    progress.textContent = 'Packing…';
    const folderName = state.exportFolder || state.pack.id;
    const blob = await exportPack(state.pack, state.markers, tileZips, {
      folderName,
      keptTiles: state.keptTiles,
      notes: !state.origin, // a pack that came from a repo doesn't need the how-to file
    });
    const a = h('a', { href: URL.createObjectURL(blob), download: `${folderName}.zip` });
    a.click();
    setTimeout(() => URL.revokeObjectURL(a.href), 10_000);
    progress.textContent = state.origin
      ? `Downloaded. Unzip it over your repo's "${folderName}" folder, check git diff, then commit.`
      : 'Downloaded. See PUBLISHING.md inside the zip for the next steps.';
    state.fresh.clear(); // ids are now out in the world: keep them fixed
    save();
  };
  return h('div', {},
    h('h2', {}, 'Export'),
    problems.length
      ? h('ul', { class: 'problems' }, ...problems.map((p) => h('li', { class: p.level }, p.message)))
      : h('p', { class: 'ok' }, icon('check_circle'), 'No problems found.'),
    h('p', { class: 'help' },
      toBuild.length
        ? `Tiles will be made for: ${toBuild.map((m) => m.name).join(', ')}. Big images take a minute.`
        : 'No new tiles to make; existing tile links in pack.json are kept.'),
    keyed(field('Folder name', state.exportFolder || state.pack.id, (v) => (state.exportFolder = v.trim()),
      { hint: 'The zip unpacks to this folder, e.g. "silksong" to drop straight into demo_maps.' }), 'x.folder'),
    h('button', { class: 'primary', disabled: errors.length > 0, onclick: run }, icon('download'), 'Download pack (.zip)'),
    progress,
    h('button', {
      class: 'ghost',
      onclick: async () => {
        await navigator.clipboard.writeText(JSON.stringify(state.pack, null, 2));
        progress.textContent = 'pack.json copied.';
      },
    }, icon('content_copy'), 'Copy pack.json'),
  );
}

// ---- Start ---------------------------------------------------------------------

restore();
renderSidebar();
renderMapLayers();
// Published maps come back from their release; others need their image re-added.
for (const m of state.pack.maps) if (relayable(m.tiles.archive)) void loadFromRelease(m);
