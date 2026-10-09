// TOME's pack format (docs/pack-format.md), as plain JSON-shaped types.
// Kept loose on purpose: unknown fields from newer packs are preserved.

export interface Source {
  name: string;
  url?: string;
  license?: string;
}

export interface CategoryGroup {
  id: string;
  name: string;
}

export interface Category {
  id: string;
  name: string;
  group?: string;
  color?: string;
  icon?: string;
  /** A small image in the pack (e.g. icons/mask_shard.png) drawn instead of `icon`. */
  iconImage?: string;
  wiki?: string;
  description?: string;
  source?: Source;
}

export interface Region {
  id: string;
  name: string;
  map?: string;
  wiki?: string;
  x?: number;
  y?: number;
  outline?: [number, number][];
  description?: string;
  source?: Source;
  [extra: string]: unknown;
}

/** Matching points between an overview and a more detailed map (see docs/pack-format.md). */
export interface ZoomLink {
  map: string;
  /** [overviewX, overviewY, detailX, detailY] */
  points: [number, number, number, number][];
  /** Overview regions the detailed map covers; absent = everywhere. */
  regions?: string[];
  [extra: string]: unknown;
}

/** One image placed on a composed map's canvas (tools/compose_map.py layout). */
export interface Piece {
  file: string;
  x: number;
  y: number;
  scale?: number;
  /** Natural size of the image, so its place shows even before it's loaded. */
  width?: number;
  height?: number;
  /** Pieces sharing a group move together. */
  group?: string;
  /** Can't be dragged. */
  locked?: boolean;
  /** Studio only: an alignment guide, never composed or exported. */
  reference?: boolean;
  opacity?: number;
  [extra: string]: unknown;
}

export interface Layout {
  map?: string;
  note?: string;
  size: [number, number];
  images: Piece[];
  [extra: string]: unknown;
}

export interface MapDef {
  id: string;
  name: string;
  image: { width: number; height: number };
  tileSize: number;
  minZoom: number;
  maxZoom: number;
  tiles: { archive: string; path: string; archiveBytes?: number };
  markers?: string;
  initialView?: { x: number; y: number; zoom?: number };
  regions?: Region[];
  description?: string;
  wiki?: string;
  zoomsInto?: ZoomLink;
  /** Layout file this map is composed from (studio and tools only; the app ignores it). */
  layout?: string;
  [extra: string]: unknown;
}

export interface Marker {
  id: string;
  name: string;
  x: number;
  y: number;
  category?: string;
  description?: string;
  wiki?: string;
  trackable?: boolean;
  [extra: string]: unknown;
}

export interface Pack {
  schemaVersion: 1;
  id: string;
  name: string;
  version: string;
  game?: string;
  author?: string;
  description?: string;
  wiki?: string;
  categoryGroups?: CategoryGroup[];
  categories?: Category[];
  maps: MapDef[];
  [extra: string]: unknown;
}

export const TILE_SIZE = 256;

export function newPack(): Pack {
  return {
    schemaVersion: 1,
    id: 'yourname.mygame',
    name: 'My Game Map',
    version: '0.1.0',
    game: '',
    author: '',
    categoryGroups: [],
    categories: [],
    maps: [],
  };
}

/** Lowercase id from a name: "Mask Shard #1" -> "mask_shard_1". */
export function slugify(name: string): string {
  return name
    .toLowerCase()
    .replace(/['’]/g, '')
    .replace(/[^a-z0-9]+/g, '_')
    .replace(/^_+|_+$/g, '');
}

/** `base`, or `base_2`, `base_3`… — whichever isn't in `taken`. */
export function uniqueId(base: string, taken: Iterable<string>): string {
  const used = new Set(taken);
  const start = base || 'item';
  let id = start;
  for (let n = 2; used.has(id); n++) id = `${start}_${n}`;
  return id;
}

/** Zoom level where one tile pixel is one image pixel (same rule as tools/slicer). */
export function nativeMaxZoom(width: number, height: number, tileSize = TILE_SIZE): number {
  return Math.max(0, Math.ceil(Math.log2(Math.max(width, height) / tileSize)));
}

/** A new map entry for an image, with the conventional archive and markers paths. */
export function mapForImage(id: string, name: string, width: number, height: number): MapDef {
  const maxZoom = nativeMaxZoom(width, height);
  return {
    id,
    name,
    image: { width, height },
    tileSize: TILE_SIZE,
    minZoom: 0,
    maxZoom,
    tiles: { archive: `out/${id}-tiles.zip`, path: '{z}/{x}/{y}.png' },
    markers: `markers/${id}.json`,
    initialView: { x: Math.round(width / 2), y: Math.round(height / 2), zoom: Math.max(0, maxZoom - 2) },
    regions: [],
  };
}

export const markersPath = (m: MapDef) => m.markers ?? `markers/${m.id}.json`;

/** Same rule as the app: a relative path inside the pack, to a PNG, WebP or JPEG. */
export const safeIconPath = (path: string) =>
  /^[\w.-]+(\/[\w.-]+)*\.(png|webp|jpe?g)$/i.test(path) && !path.split('/').includes('..');

/** Where a type's uploaded icon is stored in the pack. */
export const iconPathFor = (categoryId: string) => `icons/${categoryId}.png`;

export interface Problem {
  level: 'error' | 'warning';
  message: string;
}

/** Everything that would stop the app loading the pack, plus things worth a look. */
export function validate(pack: Pack, markers: Record<string, Marker[]>): Problem[] {
  const out: Problem[] = [];
  const err = (message: string) => out.push({ level: 'error', message });
  const warn = (message: string) => out.push({ level: 'warning', message });

  if (!/^[a-z0-9][a-z0-9._-]*$/.test(pack.id)) {
    err(`Pack id "${pack.id}" must be lowercase letters, numbers, ".", "_" or "-" (e.g. yourname.mygame).`);
  }
  if (pack.id === 'yourname.mygame') warn('Change the pack id from the example "yourname.mygame".');
  if (!pack.name.trim()) err('The pack needs a name.');
  if (!/^\d+\.\d+\.\d+/.test(pack.version)) warn(`Version "${pack.version}" isn't like 1.0.0.`);
  if (pack.maps.length === 0) err('Add at least one map.');

  const groups = new Set((pack.categoryGroups ?? []).map((g) => g.id));
  const cats = new Set<string>();
  for (const c of pack.categories ?? []) {
    if (cats.has(c.id)) err(`Two types share the id "${c.id}".`);
    cats.add(c.id);
    if (c.group && !groups.has(c.group)) warn(`Type "${c.name}" is in a group that no longer exists.`);
    if (c.iconImage !== undefined && !safeIconPath(c.iconImage)) {
      err(`Type "${c.name}" has an icon image path the app won't load ("${c.iconImage}").`);
    }
  }

  const mapIds = new Set<string>();
  const markerIds = new Set<string>();
  for (const m of pack.maps) {
    if (mapIds.has(m.id)) err(`Two maps share the id "${m.id}".`);
    mapIds.add(m.id);
    for (const mk of markers[m.id] ?? []) {
      if (markerIds.has(mk.id)) err(`Marker id "${mk.id}" is used twice (ids must be unique across the pack).`);
      markerIds.add(mk.id);
      if (mk.category && !cats.has(mk.category)) warn(`Marker "${mk.name}" has a type that doesn't exist.`);
      if (mk.x < 0 || mk.y < 0 || mk.x > m.image.width || mk.y > m.image.height) {
        warn(`Marker "${mk.name}" is outside the ${m.name} image.`);
      }
    }
    for (const r of m.regions ?? []) {
      if (r.outline && r.outline.length > 0 && r.outline.length < 3) {
        err(`Region "${r.name}" needs at least 3 outline points.`);
      }
      if (!r.outline?.length && (r.x === undefined || r.y === undefined)) {
        err(`Region "${r.name}" needs a point or an outline.`);
      }
      if (r.map && !r.outline?.length) err(`Region "${r.name}" opens a map, so it needs an outline.`);
    }
  }
  for (const m of pack.maps) {
    for (const r of m.regions ?? []) {
      if (r.map && !mapIds.has(r.map)) err(`Region "${r.name}" opens a map that doesn't exist.`);
    }
    const link = m.zoomsInto;
    if (link) {
      if (!mapIds.has(link.map) || link.map === m.id) err(`${m.name} zooms into a map that doesn't exist.`);
      if (link.points.length < 2) err(`${m.name} zooms into another map: add at least 2 matching points (Zoom tab).`);
      else if (link.points.length < 4) warn(`${m.name}: more matching points (spread out) make zooming in land more accurately.`);
      for (const id of link.regions ?? []) {
        const r = m.regions?.find((x) => x.id === id);
        if (!r) err(`${m.name}'s zoom-in area list names a region that no longer exists ("${id}").`);
        else if (!r.outline?.length) err(`Region "${r.name}" limits where ${m.name} zooms in, so it needs an outline.`);
      }
    }
  }
  return out;
}
