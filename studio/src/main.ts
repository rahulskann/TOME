import 'leaflet/dist/leaflet.css';
import './style.css';
import L from 'leaflet';
import { field, h, icon, select } from './dom';
import { CATEGORY_ICONS, materialIcon } from './icons';
import {
  type Rect,
  artPieces,
  composeImage,
  contentBounds,
  fitCanvas,
  groupOf,
  overflows,
  pieceAt,
  pieceRect,
  shiftMapContent,
} from './compose';
import {
  type Category,
  type Layout,
  type MapDef,
  type Marker,
  type Pack,
  type Piece,
  type Region,
  mapForImage,
  nativeMaxZoom,
  newPack,
  slugify,
  uniqueId,
  validate,
} from './model';
import {
  type OpenedPack, exportFolderName, exportPack, importPackZip, layoutFileFor, openFromLink,
} from './packio';
import { sliceToZip } from './slicer';
import { fetchViaRelay, relayable } from './relay';
import { imageFromTiles } from './tiles';
import { fromDetail, linkScale, matchByRegions, toDetail, zoomParent } from './zoomlink';

// ---- State ------------------------------------------------------------------

type Tab = 'pack' | 'types' | 'maps' | 'pieces' | 'markers' | 'regions' | 'zoom' | 'export';
type Mode = 'view' | 'addMarker' | 'addPoint' | 'drawOutline' | 'zoomPick' | 'zoomPickDetail' | 'zoomTry';

interface LoadedImage {
  url: string;
  width: number;
  height: number;
  bitmap: ImageBitmap;
  /** Build tiles from this image on export (off when it's only a preview). */
  buildTiles: boolean;
}

interface PieceImage {
  url: string;
  bitmap: ImageBitmap;
  blob: Blob;
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
  /** Composed maps' layouts, by map id. */
  layouts: {} as Record<string, Layout>,
  /** Their piece images (not saved in the browser), by map id then file. */
  pieceImages: {} as Record<string, Record<string, PieceImage>>,
  /** Composed maps whose pieces changed since their tiles were made. */
  dirtyLayouts: new Set<string>(),
  selectedPiece: undefined as string | undefined,
  /** Moving a piece also moves the markers, areas and zoom points on it. */
  moveContent: true,
  /** Picking a matching point: the overview spot, and the view to return to. */
  pendingZoom: undefined as { map: string; x: number; y: number; center: L.LatLng; zoom: number } | undefined,
  /** "Try it" result to show. */
  tryPoint: undefined as { map: string; x: number; y: number } | undefined,
};

function restore() {
  try {
    const saved = localStorage.getItem(STORAGE_KEY);
    if (!saved) return;
    const data = JSON.parse(saved) as {
      pack: Pack; markers: Record<string, Marker[]>; activeMap?: string; fresh?: string[];
      layouts?: Record<string, Layout>; dirtyLayouts?: string[];
    };
    state.pack = data.pack;
    state.layouts = data.layouts ?? {};
    state.dirtyLayouts = new Set(data.dirtyLayouts ?? []);
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
          layouts: state.layouts, dirtyLayouts: [...state.dirtyLayouts],
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

const rectBounds = (m: MapDef, r: Rect) => L.latLngBounds(toLatLng(m, r.x, r.y + r.h), toLatLng(m, r.x + r.w, r.y));

/** Overlays of the pieces on screen, so dragging can move them without a redraw. */
const pieceOverlays = new Map<string, L.ImageOverlay | L.Rectangle>();

function renderMapLayers() {
  layers.clearLayers();
  pieceOverlays.clear();
  const m = activeMap();
  if (!m) return;
  const bounds = L.latLngBounds(toLatLng(m, 0, m.image.height), toLatLng(m, m.image.width, 0));
  const img = state.images[m.id];
  const layout = state.layouts[m.id];
  const pieceImgs = state.pieceImages[m.id] ?? {};
  const piecesMissing = layout ? artPieces(layout).some((p) => !pieceImgs[p.file]) : true;
  if (img && piecesMissing) {
    L.imageOverlay(img.url, bounds, { opacity: layout ? 0.6 : 1 }).addTo(layers);
  }
  if (layout) renderPieces(m, layout, pieceImgs);
  if (!img || layout) {
    L.rectangle(bounds, { color: '#555', weight: 1, dashArray: '6 6', fill: false, interactive: false }).addTo(layers);
  }
  if (fittedFor !== m.id) {
    map.fitBounds(bounds, { padding: [20, 20] });
    fittedFor = m.id;
  }

  const editingPieces = state.tab === 'pieces';
  const link = m.zoomsInto;
  const covered = new Set(state.tab === 'zoom' ? (link?.regions ?? []) : []);
  for (const r of m.regions ?? []) {
    const selected = r.id === state.selectedRegion || covered.has(r.id);
    const style = {
      color: selected ? '#ffd166' : '#b9a8e0', weight: selected ? 3 : 2, fillOpacity: covered.has(r.id) ? 0.18 : 0.08,
      interactive: !editingPieces && state.tab !== 'zoom' && state.mode === 'view',
    };
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
      draggable: !editingPieces,
      interactive: !editingPieces && state.tab !== 'zoom' && state.mode === 'view',
      opacity: editingPieces ? 0.7 : 1,
      title: mk.name,
    });
    marker.on('click', () => update(() => ((state.selectedMarker = mk.id), (state.tab = 'markers'))));
    marker.on('dragend', () => {
      const [x, y] = toPixel(m, marker.getLatLng());
      update(() => Object.assign(mk, { x, y }));
    });
    marker.addTo(layers);
  }
  if (state.tab === 'zoom' || state.mode.startsWith('zoom')) renderZoomPoints(m);
  if (state.tryPoint?.map === m.id) {
    L.circleMarker(toLatLng(m, state.tryPoint.x, state.tryPoint.y), {
      radius: 14, color: '#4fd1c5', weight: 3, fill: false, interactive: false,
    }).addTo(layers);
  }
}

function renderPieces(m: MapDef, layout: Layout, imgs: Record<string, PieceImage>) {
  const editing = state.tab === 'pieces';
  // Art first, alignment guides on top so they can be seen through.
  for (const p of [...artPieces(layout), ...layout.images.filter((x) => x.reference)]) {
    const r = pieceRect(p);
    if (r.w === 0) continue;
    const img = imgs[p.file];
    const interactive = editing && !groupOf(layout, p).some((q) => q.locked);
    const layer = img
      ? L.imageOverlay(img.url, rectBounds(m, r), {
        opacity: p.opacity ?? (p.reference ? 0.5 : 1), interactive, className: interactive ? 'piece' : '',
      })
      : L.rectangle(rectBounds(m, r), { color: '#888', weight: 1, dashArray: '3 5', fillOpacity: 0.04, interactive })
        .bindTooltip(`${p.file} (image not loaded)`);
    layer.addTo(layers);
    // Listen on the element itself and stop the press there, so the map's own
    // panning (which listens further up) never starts.
    if (interactive) {
      layer.getElement()?.addEventListener('mousedown', (e: Event) => {
        if (!(e instanceof MouseEvent)) return;
        if (e.button !== 0) return;
        e.stopPropagation();
        e.preventDefault();
        startPieceDrag(m, layout, p, e);
      });
    }
    pieceOverlays.set(p.file, layer);
  }
  if (!editing) return;
  const sel = layout.images.find((p) => p.file === state.selectedPiece);
  for (const p of sel ? groupOf(layout, sel) : []) {
    L.rectangle(rectBounds(m, pieceRect(p)), {
      color: p === sel ? '#ffd166' : '#e8b04a', weight: 2, dashArray: p === sel ? undefined : '4 4',
      fill: false, interactive: false,
    }).addTo(layers);
  }
  const b = contentBounds(layout);
  if (b && overflows(layout)) {
    L.rectangle(rectBounds(m, b), { color: '#e06a6a', weight: 1, dashArray: '2 6', fill: false, interactive: false }).addTo(layers);
  }
}

/** Drag a piece (and the pieces linked to it) across the canvas. */
function startPieceDrag(m: MapDef, layout: Layout, piece: Piece, e: MouseEvent) {
  if (state.tab !== 'pieces') return;
  const group = groupOf(layout, piece);
  if (state.selectedPiece !== piece.file) {
    state.selectedPiece = piece.file;
    renderSidebar();
  }
  if (group.some((q) => q.locked)) return;
  const start = map.mouseEventToLatLng(e);
  const k = 2 ** m.maxZoom;
  let dx = 0;
  let dy = 0;
  const move = (ev: MouseEvent) => {
    const at = map.mouseEventToLatLng(ev);
    dx = Math.round((at.lng - start.lng) * k);
    dy = Math.round(-(at.lat - start.lat) * k);
    for (const q of group) {
      const r = pieceRect(q);
      const layer = pieceOverlays.get(q.file);
      layer?.setBounds(rectBounds(m, { ...r, x: r.x + dx, y: r.y + dy }));
    }
  };
  const end = () => {
    document.removeEventListener('mousemove', move);
    document.removeEventListener('mouseup', end);
    if (dx || dy) movePieces(m, layout, group, dx, dy);
    else update(() => {});
  };
  document.addEventListener('mousemove', move);
  document.addEventListener('mouseup', end);
}

/** Moves pieces, carrying what's drawn on them along if that's switched on. */
function movePieces(m: MapDef, layout: Layout, group: Piece[], dx: number, dy: number, full = true) {
  const change = () => {
    if (state.moveContent && group.some((q) => !q.reference)) {
      const moving = new Set(group);
      const moved = shiftMapContent(state.pack, state.markers, m.id, dx, dy, (x, y) => {
        const top = pieceAt(layout, x, y);
        return top !== undefined && moving.has(top);
      });
      state.status = moved ? `Moved ${moved} marker(s), area(s) or zoom point(s) with it.` : state.status;
    }
    for (const q of group) {
      q.x += dx;
      q.y += dy;
    }
    if (group.some((q) => !q.reference)) state.dirtyLayouts.add(m.id);
  };
  if (full) update(change);
  else live(change);
}

/** Numbered matching points of zoom links touching this map, draggable to fine-tune. */
function renderZoomPoints(m: MapDef) {
  const parent = zoomParent(state.pack.maps, m.id);
  const sets: [L.PathOptions['color'], [number, number, number, number][], 0 | 2][] = [];
  if (m.zoomsInto) sets.push(['#ffd166', m.zoomsInto.points, 0]);
  if (parent?.zoomsInto) sets.push(['#4fd1c5', parent.zoomsInto.points, 2]);
  for (const [color, points, at] of sets) {
    points.forEach((pt, i) => {
      const el = h('div', { class: 'zpt', style: { borderColor: color ?? '' } }, String(i + 1));
      const marker = L.marker(toLatLng(m, pt[at], pt[at + 1]), {
        icon: L.divIcon({ html: el, className: '', iconSize: [22, 22], iconAnchor: [11, 11] }),
        draggable: state.tab === 'zoom',
        title: `Matching point ${i + 1}`,
      });
      marker.on('dragend', () => {
        const [x, y] = toPixel(m, marker.getLatLng());
        update(() => ((pt[at] = x), (pt[at + 1] = y)));
      });
      marker.addTo(layers);
    });
  }
  if (state.pendingZoom && state.pendingZoom.map === m.id) {
    L.circleMarker(toLatLng(m, state.pendingZoom.x, state.pendingZoom.y), {
      radius: 9, color: '#ffd166', weight: 3, interactive: false,
    }).addTo(layers);
  }
}

/** Shows map `id` centred on (x, y), at the zoom matching what was on screen. */
function showMapAt(id: string, x: number, y: number, zoom: number) {
  const target = state.pack.maps.find((mm) => mm.id === id)!;
  state.activeMap = id;
  fittedFor = id;
  renderMapLayers();
  map.setView(toLatLng(target, x, y), zoom, { animate: false });
}

function insidePolygon(poly: [number, number][], x: number, y: number): boolean {
  let hit = false;
  for (let i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    const [xi, yi] = poly[i];
    const [xj, yj] = poly[j];
    if (yi > y !== yj > y && x < ((xj - xi) * (y - yi)) / (yj - yi) + xi) hit = !hit;
  }
  return hit;
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
    case 'zoomPick': {
      const detail = m.zoomsInto?.map;
      if (!detail) return;
      const link = m.zoomsInto!;
      state.pendingZoom = { map: m.id, x, y, center: map.getCenter(), zoom: map.getZoom() };
      state.mode = 'zoomPickDetail';
      const d = state.pack.maps.find((mm) => mm.id === detail)!;
      if (link.points.length >= 2) {
        const [tx, ty] = toDetail(link, x, y);
        showMapAt(detail, tx, ty, map.getZoom() + Math.log2(linkScale(link.points)));
      } else {
        state.activeMap = detail;
        fittedFor = undefined;
        renderMapLayers();
      }
      state.status = `Now click the same spot on ${d.name}.`;
      renderSidebar();
      break;
    }
    case 'zoomPickDetail': {
      const pending = state.pendingZoom;
      const overview = state.pack.maps.find((mm) => mm.id === pending?.map);
      if (!pending || !overview?.zoomsInto) return;
      overview.zoomsInto.points.push([pending.x, pending.y, x, y]);
      state.pendingZoom = undefined;
      state.mode = 'view';
      state.status = `Matching point ${overview.zoomsInto.points.length} added.`;
      save();
      restoreView(overview.id, pending.center, pending.zoom);
      renderSidebar();
      break;
    }
    case 'zoomTry': {
      const link = m.zoomsInto;
      const parent = zoomParent(state.pack.maps, m.id);
      if (link && link.points.length >= 2) {
        const regions = link.regions?.length ? m.regions?.filter((r) => link.regions!.includes(r.id)) ?? [] : undefined;
        if (regions && !regions.some((r) => r.outline && insidePolygon(r.outline, x, y))) {
          update(() => (state.status = 'Outside the covered regions: zooming in here stays on this map.'), false);
          return;
        }
        const [tx, ty] = toDetail(link, x, y);
        state.tryPoint = { map: link.map, x: tx, y: ty };
        showMapAt(link.map, tx, ty, map.getZoom() + Math.log2(linkScale(link.points)));
      } else if (parent?.zoomsInto && parent.zoomsInto.points.length >= 2) {
        const [tx, ty] = fromDetail(parent.zoomsInto, x, y);
        state.tryPoint = { map: parent.id, x: tx, y: ty };
        showMapAt(parent.id, tx, ty, map.getZoom() - Math.log2(linkScale(parent.zoomsInto.points)));
      } else {
        return;
      }
      state.status = 'The ring shows where you land. Click again to go back the other way.';
      renderSidebar();
      break;
    }
  }
});

function stopMode() {
  const back = state.pendingZoom;
  update(() => {
    state.mode = 'view';
    state.draft = [];
    state.pendingZoom = undefined;
    state.tryPoint = undefined;
  });
  if (back) restoreView(back.map, back.center, back.zoom);
}

function restoreView(id: string, center: L.LatLng, zoom: number) {
  state.activeMap = id;
  fittedFor = id;
  renderMapLayers();
  map.setView(center, zoom, { animate: false });
}

document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && state.mode !== 'view') return stopMode();
  // Arrow keys nudge the selected piece (Shift: 10px), unless typing.
  const arrows: Record<string, [number, number]> = {
    ArrowLeft: [-1, 0], ArrowRight: [1, 0], ArrowUp: [0, -1], ArrowDown: [0, 1],
  };
  const typing = (e.target as HTMLElement)?.closest?.('input, textarea, select');
  const m = activeMap();
  const layout = m && state.layouts[m.id];
  const piece = layout?.images.find((p) => p.file === state.selectedPiece);
  if (!arrows[e.key] || typing || state.tab !== 'pieces' || !m || !layout || !piece) return;
  const group = groupOf(layout, piece);
  if (group.some((q) => q.locked)) return;
  e.preventDefault();
  const step = e.shiftKey ? 10 : 1;
  movePieces(m, layout, group, arrows[e.key][0] * step, arrows[e.key][1] * step);
});

// ---- Sidebar ------------------------------------------------------------------

const sidebar = document.getElementById('sidebar')!;
const TABS: [Tab, string, string][] = [
  ['pack', 'Pack', 'inventory_2'],
  ['types', 'Types', 'category'],
  ['maps', 'Maps', 'map'],
  ['pieces', 'Pieces', 'dashboard'],
  ['markers', 'Markers', 'place'],
  ['regions', 'Regions', 'crop_free'],
  ['zoom', 'Zoom', 'zoom_in'],
  ['export', 'Export', 'download'],
];

function renderSidebar() {
  const focused = document.activeElement as HTMLElement | null;
  const focusKey = focused?.dataset?.key;
  const body = {
    pack: packTab,
    types: typesTab,
    maps: mapsTab,
    pieces: piecesTab,
    markers: markersTab,
    regions: regionsTab,
    zoom: zoomTab,
    export: exportTab,
  }[state.tab]();
  const parts = [
    h(
      'nav',
      { class: 'tabs' },
      ...TABS.map(([id, label, ic]) =>
        h('button', { class: state.tab === id ? 'active' : '', onclick: () => update(() => (state.tab = id)) },
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
    zoomPick: 'Click a spot you can recognise on this map (a region name, a landmark).',
    zoomPickDetail: 'Now click the same spot on this map.',
    zoomTry: 'Click anywhere: you\'ll jump to where the app would take you. Esc to stop.',
  }[state.mode];
  if (!text) return null;
  return h('div', { class: 'mode' }, text,
    state.mode === 'drawOutline'
      ? h('button', { disabled: state.draft.length < 3, onclick: finishOutline }, 'Finish')
      : null,
    h('button', { class: 'ghost', onclick: stopMode }, state.mode === 'zoomTry' ? 'Done' : 'Cancel'));
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
    clearPieces();
    state.layouts = opened.layouts ?? {};
    state.dirtyLayouts.clear();
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
  for (const [mapId, blobs] of Object.entries(opened.pieces ?? {})) {
    for (const [file, blob] of Object.entries(blobs)) void loadPieceImage(mapId, file, blob);
  }
}

function clearPieces() {
  for (const imgs of Object.values(state.pieceImages)) {
    for (const img of Object.values(imgs)) URL.revokeObjectURL(img.url);
  }
  state.pieceImages = {};
  state.selectedPiece = undefined;
}

/** Shows a piece's image, filling in its size if the layout didn't have it. */
async function loadPieceImage(mapId: string, file: string, blob: Blob) {
  try {
    const bitmap = await createImageBitmap(blob);
    const piece = state.layouts[mapId]?.images.find((p) => p.file === file);
    update(() => {
      const imgs = (state.pieceImages[mapId] ??= {});
      if (imgs[file]) URL.revokeObjectURL(imgs[file].url);
      imgs[file] = { url: URL.createObjectURL(blob), bitmap, blob };
      if (piece) {
        piece.width = bitmap.width;
        piece.height = bitmap.height;
      }
    });
  } catch {
    update(() => (state.status = `Couldn't read ${file} as an image.`), false);
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
          clearPieces();
          state.layouts = {};
          state.dirtyLayouts.clear();
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
        state.layouts[m.id]
          ? h('small', { class: 'muted' }, `Composed from ${artPieces(state.layouts[m.id]).length} piece(s) (Pieces tab)` +
            (state.dirtyLayouts.has(m.id) ? ': new tiles on export' : ''))
          : null,
        m.zoomsInto
          ? h('small', { class: 'muted' }, `Zooming in continues on ${mapName(m.zoomsInto.map)} (Zoom tab)`)
          : null,
        state.layouts[m.id] ? null : img
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
    h('div', { class: 'row' },
      h('button', { onclick: () => filePicker((f) => addImage(f)) }, icon('add_photo_alternate'), 'Add map from image'),
      h('button', { onclick: () => filesPicker((fs) => void newMapFromPieces(fs)) }, icon('dashboard'), 'Map from pieces')),
    h('p', { class: 'help' }, '"Map from pieces" places several images (e.g. one per region) on one canvas; ' +
      'arrange them in the Pieces tab.'),
  );
}

const mapName = (id: string) => state.pack.maps.find((m) => m.id === id)?.name ?? id;

function filesPicker(onFiles: (f: File[]) => void) {
  const input = h('input', { type: 'file', accept: 'image/*', multiple: true });
  input.addEventListener('change', () => input.files?.length && onFiles([...input.files]));
  input.click();
}

// -- Pieces
const pieceName = (p: Piece) => p.file.split('/').pop() ?? p.file;

/** A free path for a new piece image, e.g. source/the-marrow.png. */
function piecePath(layout: Layout, file: File, reference: boolean): string {
  const dot = file.name.lastIndexOf('.');
  const base = slugify(dot > 0 ? file.name.slice(0, dot) : file.name).replace(/_/g, '-') || 'piece';
  const ext = dot > 0 ? file.name.slice(dot).toLowerCase() : '.png';
  const taken = new Set(layout.images.map((p) => p.file));
  let path = `${reference ? 'reference' : 'source'}/${base}${ext}`;
  for (let n = 2; taken.has(path); n++) path = `${reference ? 'reference' : 'source'}/${base}-${n}${ext}`;
  return path;
}

/** Adds images as pieces, placed in the middle of the view (side by side). */
async function addPieces(m: MapDef, files: File[], reference = false) {
  const layout = state.layouts[m.id];
  const [cx, cy] = toPixel(m, map.getCenter());
  let offset = 0;
  for (const file of files) {
    let bitmap: ImageBitmap;
    try {
      bitmap = await createImageBitmap(file);
    } catch {
      update(() => (state.status = `Couldn't read ${file.name} as an image.`), false);
      continue;
    }
    const piece: Piece = {
      file: piecePath(layout, file, reference),
      x: Math.round(cx - bitmap.width / 2 + offset),
      y: Math.round(cy - bitmap.height / 2),
      width: bitmap.width,
      height: bitmap.height,
      ...(reference ? { reference: true, locked: false, opacity: 0.5 } : {}),
    };
    offset += bitmap.width + 20;
    update(() => {
      layout.images.push(piece);
      (state.pieceImages[m.id] ??= {})[piece.file] = { url: URL.createObjectURL(file), bitmap, blob: file };
      state.selectedPiece = piece.file;
      if (!reference) state.dirtyLayouts.add(m.id);
    });
  }
}

/** Turns a single-image map into a composed one; its current image becomes the first piece. */
async function composeExisting(m: MapDef) {
  const layout: Layout = { size: [m.image.width, m.image.height], images: [] };
  const img = state.images[m.id];
  if (img) {
    const blob = await (await fetch(img.url)).blob();
    const file = `source/${m.id.replace(/_/g, '-')}-base.png`;
    layout.images.push({ file, x: 0, y: 0, width: img.width, height: img.height, locked: true });
    (state.pieceImages[m.id] ??= {})[file] = { url: URL.createObjectURL(blob), bitmap: img.bitmap, blob };
  }
  update(() => {
    state.layouts[m.id] = layout;
    m.layout = layoutFileFor(state.pack, m.id);
    state.selectedPiece = layout.images[0]?.file;
    if (img?.buildTiles) state.dirtyLayouts.add(m.id);
    state.status = img
      ? 'The current image is now a locked piece. Add pieces around it, then "Fit canvas to pieces".'
      : '';
  });
}

async function newMapFromPieces(files: File[]) {
  const first = await createImageBitmap(files[0]).catch(() => undefined);
  if (!first) return update(() => (state.status = `Couldn't read ${files[0].name} as an image.`), false);
  const id = uniqueId('map', state.pack.maps.map((x) => x.id));
  const m = mapForImage(id, 'New map', first.width, first.height);
  update(() => {
    state.pack.maps.push(m);
    state.markers[m.id] = [];
    state.fresh.add(`map:${id}`);
    state.layouts[m.id] = { size: [first.width, first.height], images: [] };
    m.layout = layoutFileFor(state.pack, m.id);
    state.activeMap = m.id;
    state.tab = 'pieces';
    fittedFor = undefined;
  });
  await addPieces(m, files);
  const layout = state.layouts[m.id];
  // Lay them out in a row from the left edge, then fit the canvas around them.
  let x = 0;
  for (const p of layout.images) {
    p.x = x;
    p.y = 0;
    x += pieceRect(p).w + 20;
  }
  update(() => {
    fitToPieces(m, true);
    state.status = 'Drag the pieces into place (arrow keys nudge), then "Fit canvas to pieces".';
  });
}

/** Fits the canvas to the pieces and resizes the map to match. */
function fitToPieces(m: MapDef, trim = false) {
  const layout = state.layouts[m.id];
  const shift = fitCanvas(state.pack, state.markers, m.id, layout, trim);
  if (!shift) return;
  const [w, h] = layout.size;
  if (w !== m.image.width || h !== m.image.height || shift[0] || shift[1]) {
    m.image = { width: w, height: h };
    m.maxZoom = nativeMaxZoom(w, h, m.tileSize);
    if (m.initialView?.zoom !== undefined) m.initialView.zoom = Math.min(m.initialView.zoom, m.maxZoom);
    state.dirtyLayouts.add(m.id);
    fittedFor = undefined;
  }
}

/** Re-attaches piece images after a reload, matching by file name. */
function reattachPieces(m: MapDef, files: File[]) {
  const layout = state.layouts[m.id];
  let found = 0;
  for (const f of files) {
    const p = layout.images.find((q) => pieceName(q).toLowerCase() === f.name.toLowerCase() ||
      pieceName(q).replace(/\.[^.]+$/, '') === slugify(f.name.replace(/\.[^.]+$/, '')).replace(/_/g, '-'));
    if (p) {
      found++;
      void loadPieceImage(m.id, p.file, f);
    }
  }
  update(() => (state.status = `Matched ${found} of ${files.length} image(s) to pieces by name.`), false);
}

function piecesTab() {
  const m = activeMap();
  if (!m) return h('p', { class: 'help' }, 'Add a map first (Maps tab).');
  const layout = state.layouts[m.id];
  if (!layout) {
    return h('div', {},
      h('h2', {}, `Pieces · ${m.name}`),
      h('p', { class: 'help' },
        'Build this map from several images placed on one canvas, e.g. a clean picture of each region. ' +
        'Neighbouring pieces line up, and you can add more regions later.'),
      h('button', { class: 'primary', onclick: () => void composeExisting(m) }, icon('dashboard'), 'Compose this map from pieces'),
      h('p', { class: 'help' }, state.images[m.id]
        ? 'Its current image becomes the first (locked) piece, so nothing moves.'
        : 'Load or add its image first to keep it as the first piece, or start with an empty canvas.'),
    );
  }
  const imgs = state.pieceImages[m.id] ?? {};
  const missing = layout.images.filter((p) => !imgs[p.file]);
  const sel = layout.images.find((p) => p.file === state.selectedPiece);
  return h('div', {},
    h('h2', {}, `Pieces · ${m.name}`),
    h('small', { class: 'muted' }, `Canvas ${layout.size[0]}×${layout.size[1]}px · ${artPieces(layout).length} piece(s)`),
    overflows(layout)
      ? h('small', { class: 'warn' }, 'Some pieces stick out past the canvas (red outline): they\'d be cut off.')
      : null,
    h('div', { class: 'row wrap' },
      h('button', { class: 'primary', onclick: () => filesPicker((fs) => void addPieces(m, fs)) }, icon('add_photo_alternate'), 'Add pieces'),
      h('button', { onclick: () => update(() => fitToPieces(m)), title: 'Grow the canvas so every piece fits' },
        icon('fit_screen'), 'Fit canvas to pieces'),
      h('button', {
        class: 'ghost', title: 'Shrink the canvas to just the pieces (cuts the empty space kept for regions to come)',
        onclick: () => confirm('Shrink the canvas to just the pieces? Empty space around them is removed.') &&
          update(() => fitToPieces(m, true)),
      }, icon('crop'), 'Trim')),
    h('p', { class: 'help' },
      'Drag pieces on the map; arrow keys nudge the selected one (Shift: 10px). ' +
      'Fitting the canvas moves everything on the map with it, so markers stay put on the art.'),
    h('label', { class: 'check' },
      h('input', { type: 'checkbox', checked: state.moveContent, onchange: (e: Event) =>
        update(() => (state.moveContent = (e.target as HTMLInputElement).checked), false) }),
      'Markers and areas move with the piece they\'re on'),
    missing.length
      ? h('div', { class: 'card' },
        h('small', { class: 'warn' }, `${missing.length} piece image(s) not loaded (images aren't saved in the browser).`),
        h('button', { onclick: () => filesPicker((fs) => reattachPieces(m, fs)) }, icon('image_search'), 'Re-add images…'),
        h('small', { class: 'muted' }, 'Pick them all at once; they\'re matched by file name.'))
      : null,
    sel ? pieceForm(m, layout, sel) : null,
    h('div', { class: 'list' },
      ...[...layout.images].reverse().map((p) => h('button', {
        class: `item${p.file === state.selectedPiece ? ' active' : ''}`,
        onclick: () => update(() => (state.selectedPiece = p.file)),
      },
      icon(p.reference ? 'visibility' : imgs[p.file] ? 'image' : 'broken_image'),
      pieceName(p),
      p.locked ? icon('lock') : null,
      p.group ? h('small', { class: 'muted' }, ` 🔗${p.group}`) : null))),
    h('h3', {}, 'Alignment guide'),
    h('p', { class: 'help' },
      'A reference picture (e.g. a full map) shown see-through over the pieces to line them up. ' +
      'It\'s never exported.'),
    h('button', { onclick: () => filesPicker((fs) => void addPieces(m, fs.slice(0, 1), true)) }, icon('layers'), 'Add reference image'),
    h('h3', {}, 'Stop composing'),
    h('button', {
      class: 'ghost danger',
      onclick: () => confirm(`Turn ${m.name} back into a single-image map? The piece layout is removed.`) && update(() => {
        delete state.layouts[m.id];
        delete m.layout;
        state.dirtyLayouts.delete(m.id);
        state.selectedPiece = undefined;
      }),
    }, icon('layers_clear'), 'Use a single image instead'),
  );
}

function pieceForm(m: MapDef, layout: Layout, p: Piece) {
  const group = groupOf(layout, p);
  const others = layout.images.filter((q) => q !== p && !group.includes(q));
  const num = (label: string, value: number, set: (v: number) => void, key: string) =>
    keyed(field(label, String(value), (v) => {
      const n = Number(v);
      if (v.trim() !== '' && Number.isFinite(n)) set(n);
    }), key);
  return h('div', { class: 'card editing' },
    h('strong', {}, pieceName(p)),
    h('small', { class: 'muted' }, `${p.file}${p.width ? ` · ${p.width}×${p.height}px` : ''}`),
    h('div', { class: 'row' },
      num('x', p.x, (v) => movePieces(m, layout, group, Math.round(v) - p.x, 0, false), 'pc.x'),
      num('y', p.y, (v) => movePieces(m, layout, group, 0, Math.round(v) - p.y, false), 'pc.y'),
      num('Scale', p.scale ?? 1, (v) => v > 0 && live(() => {
        if (v === 1) delete p.scale;
        else p.scale = v;
        if (!p.reference) state.dirtyLayouts.add(m.id);
      }), 'pc.scale')),
    h('label', { class: 'field' }, h('span', {}, `See-through (${Math.round((p.opacity ?? (p.reference ? 0.5 : 1)) * 100)}%)`),
      h('input', {
        type: 'range', min: 10, max: 100, value: Math.round((p.opacity ?? (p.reference ? 0.5 : 1)) * 100),
        oninput: (e: Event) => live(() => {
          const v = Number((e.target as HTMLInputElement).value) / 100;
          if (v === 1 && !p.reference) delete p.opacity;
          else p.opacity = v;
        }),
        onchange: () => renderSidebar(),
      })),
    h('label', { class: 'check' },
      h('input', { type: 'checkbox', checked: !!p.locked, onchange: (e: Event) =>
        update(() => {
          if ((e.target as HTMLInputElement).checked) p.locked = true;
          else delete p.locked;
        }) }),
      'Locked (can\'t be dragged)'),
    h('small', { class: 'muted' }, group.length > 1
      ? `Moves together with: ${group.filter((q) => q !== p).map(pieceName).join(', ')}`
      : 'Link pieces to move them as one, once they line up.'),
    h('div', { class: 'row' },
      others.length
        ? select('Link with', '', [['', 'choose a piece…'], ...others.map((q): [string, string] => [q.file, pieceName(q)])],
          (file) => file && update(() => {
            const q = layout.images.find((x) => x.file === file)!;
            const used = new Set(layout.images.map((x) => x.group));
            const free = [...'ABCDEFGHIJKLMNOPQRSTUVWXYZ'].find((c) => !used.has(c)) ?? uniqueId('G', [...used].filter(Boolean) as string[]);
            const id = p.group ?? q.group ?? free;
            for (const x of [...groupOf(layout, p), ...groupOf(layout, q)]) x.group = id;
          }))
        : null,
      group.length > 1
        ? h('button', { class: 'ghost', onclick: () => update(() => {
          delete p.group;
          const rest = layout.images.filter((x) => x.group && x.group === group.find((g) => g !== p)?.group);
          if (rest.length === 1) delete rest[0].group;
        }) }, icon('link_off'), 'Unlink')
        : null),
    h('div', { class: 'row' },
      h('button', { class: 'ghost', title: 'Draw above the piece after it', onclick: () => update(() => {
        const i = layout.images.indexOf(p);
        if (i < layout.images.length - 1) {
          [layout.images[i], layout.images[i + 1]] = [layout.images[i + 1], p];
          if (!p.reference) state.dirtyLayouts.add(m.id);
        }
      }) }, icon('flip_to_front'), 'Up'),
      h('button', { class: 'ghost', title: 'Draw below the piece before it', onclick: () => update(() => {
        const i = layout.images.indexOf(p);
        if (i > 0) {
          [layout.images[i], layout.images[i - 1]] = [layout.images[i - 1], p];
          if (!p.reference) state.dirtyLayouts.add(m.id);
        }
      }) }, icon('flip_to_back'), 'Down'),
      h('button', { class: 'ghost danger', onclick: () => confirm(`Remove ${pieceName(p)}? Markers on it stay.`) && update(() => {
        layout.images.splice(layout.images.indexOf(p), 1);
        const img = state.pieceImages[m.id]?.[p.file];
        if (img) URL.revokeObjectURL(img.url);
        delete state.pieceImages[m.id]?.[p.file];
        state.selectedPiece = undefined;
        if (!p.reference) state.dirtyLayouts.add(m.id);
      }) }, icon('delete'), 'Remove')),
  );
}

// -- Zoom
function zoomTab() {
  const m = activeMap();
  if (!m) return h('p', { class: 'help' }, 'Add a map first (Maps tab).');
  const link = m.zoomsInto;
  const parent = zoomParent(state.pack.maps, m.id);
  const options: [string, string][] = [['', '(nothing: stay on this map)'],
    ...state.pack.maps.filter((x) => x.id !== m.id).map((x): [string, string] => [x.id, x.name])];
  const detail = link && state.pack.maps.find((x) => x.id === link.map);
  const outlined = (m.regions ?? []).filter((r) => r.outline?.length);
  return h('div', {},
    h('h2', {}, `Zoom · ${m.name}`),
    h('p', { class: 'help' },
      'An overview can hand over to a more detailed map: zoom in past its sharpest level and the app ' +
      'carries on there, at the matching spot. Zooming back out returns to the overview by itself.'),
    h('h3', {}, 'Zooming in'),
    select('Continue on', link?.map ?? '', options, (v) => update(() => {
      if (!v) delete m.zoomsInto;
      else if (link) link.map = v;
      else m.zoomsInto = { map: v, points: [] };
    })),
    link && detail
      ? h('div', {},
        h('p', { class: 'help' },
          'Matching points tie the two maps together: the same place, clicked on each. Use 4 or more, ' +
          'spread across the map; around each region name works well. Drag the numbers on either map to fine-tune.'),
        h('div', { class: 'row wrap' },
          h('button', { class: 'primary', onclick: () => update(() => (state.mode = 'zoomPick')) }, icon('add_location_alt'), 'Add matching point'),
          h('button', {
            title: 'Pair up regions that have the same name on both maps',
            onclick: () => update(() => {
              const found = matchByRegions(m, detail, link.points);
              link.points.push(...found);
              state.status = found.length
                ? `Added ${found.length} point(s) from regions named the same on both maps.`
                : 'No regions with the same name on both maps (or they\'re already matched).';
            }),
          }, icon('join_inner'), 'Match regions by name'),
          h('button', { disabled: link.points.length < 2, onclick: () => update(() => (state.mode = 'zoomTry')) },
            icon('travel_explore'), 'Try it')),
        h('small', { class: link.points.length < 2 ? 'warn' : 'muted' },
          `${link.points.length} matching point(s)${link.points.length < 2 ? ': at least 2 needed' : ''}`),
        h('div', { class: 'list' },
          ...link.points.map((pt, i) => h('div', { class: 'row' },
            h('button', {
              class: 'item', onclick: () => map.setView(toLatLng(m, pt[0], pt[1]), Math.max(map.getZoom(), -1)),
            }, h('span', { class: 'zpt inline' }, String(i + 1)), `(${pt[0]}, ${pt[1]}) → (${pt[2]}, ${pt[3]})`),
            h('button', { class: 'ghost', title: 'Remove', onclick: () => update(() => link.points.splice(i, 1)) }, icon('close'))))),
        h('h3', {}, 'Where it zooms in'),
        outlined.length
          ? h('div', {},
            h('p', { class: 'help' },
              `Tick the regions ${detail.name} already covers, so a detailed map that's still being filled in ` +
              'never shows empty space. Leave all unticked to zoom in everywhere.'),
            ...outlined.map((r) => h('label', { class: 'check' },
              h('input', { type: 'checkbox', checked: link.regions?.includes(r.id) ?? false, onchange: (e: Event) =>
                update(() => {
                  const set = new Set(link.regions ?? []);
                  if ((e.target as HTMLInputElement).checked) set.add(r.id);
                  else set.delete(r.id);
                  if (set.size) link.regions = [...set];
                  else delete link.regions;
                }) }),
              r.name)))
          : h('p', { class: 'help' }, 'Zooms in everywhere. To limit it to some regions, draw their outlines (Regions tab).'))
      : null,
    h('h3', {}, 'Zooming out'),
    parent
      ? h('div', {},
        h('p', { class: 'help' }, `Zooming out of this map returns to ${parent.name}.`),
        h('div', { class: 'row wrap' },
          h('button', { onclick: () => update(() => ((state.activeMap = parent.id), (fittedFor = undefined))) },
            icon('zoom_out_map'), `Go to ${parent.name}`),
          h('button', { disabled: (parent.zoomsInto?.points.length ?? 0) < 2, onclick: () => update(() => (state.mode = 'zoomTry')) },
            icon('travel_explore'), 'Try zooming out')))
      : h('p', { class: 'help' },
        'Nothing zooms into this map, so there\'s nothing to zoom out to. To set one up, open the overview ' +
        'and choose this map under "Continue on".'),
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
  const composed = state.pack.maps.filter((m) => state.layouts[m.id] && state.dirtyLayouts.has(m.id));
  const toBuild = [
    ...state.pack.maps.filter((m) => !state.layouts[m.id] && state.images[m.id]?.buildTiles),
    ...composed,
  ];
  const unloaded = composed.filter((m) => artPieces(state.layouts[m.id]).some((p) => !state.pieceImages[m.id]?.[p.file]));
  for (const m of unloaded) {
    const problem = { level: 'error' as const, message: `${m.name}: re-add its piece images (Pieces tab) so its new tiles can be made.` };
    problems.push(problem);
    errors.push(problem);
  }
  for (const m of composed) {
    if (overflows(state.layouts[m.id])) {
      problems.push({ level: 'warning', message: `${m.name}: some pieces stick out past the canvas (Pieces → Fit canvas).` });
    }
  }
  const progress = h('div', { class: 'muted' });
  const run = async () => {
    const tileZips: Record<string, Blob> = {};
    for (const m of toBuild) {
      const layout = state.layouts[m.id];
      const source = layout
        ? composeImage(layout, Object.fromEntries(
          Object.entries(state.pieceImages[m.id] ?? {}).map(([f, img]) => [f, img.bitmap])))
        : state.images[m.id].bitmap;
      tileZips[m.id] = await sliceToZip(source, (done, total) =>
        (progress.textContent = `Making tiles for ${m.name}: ${done} / ${total}`));
    }
    progress.textContent = 'Packing…';
    const folderName = state.exportFolder || state.pack.id;
    const blob = await exportPack(state.pack, state.markers, tileZips, {
      folderName,
      keptTiles: state.keptTiles,
      notes: !state.origin, // a pack that came from a repo doesn't need the how-to file
      layouts: state.layouts,
      pieces: Object.fromEntries(Object.entries(state.pieceImages).map(([id, imgs]) =>
        [id, Object.fromEntries(Object.entries(imgs).map(([f, img]) => [f, img.blob]))])),
    });
    // The new tiles now stand for these maps; later exports carry them through.
    for (const m of composed) {
      state.keptTiles[m.id] = tileZips[m.id];
      state.dirtyLayouts.delete(m.id);
    }
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
