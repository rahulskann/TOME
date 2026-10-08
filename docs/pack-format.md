# Pack format (schema version 1)

A **pack** is a GitHub repository (or any folder served over HTTPS) containing a
`pack.json` at its root. A pack can contain multiple maps — for example one world map,
or a D&D campaign with a region map plus several dungeon maps.

```
my-pack/
├── pack.json
├── markers/
│   └── world.json
└── README.md
```

Tile archives are attached to a GitHub Release, not committed.

## `pack.json`

```json
{
  "schemaVersion": 1,
  "id": "rahulkannan.silksong",
  "name": "Silksong Complete Secrets",
  "game": "Hollow Knight: Silksong",
  "author": "Rahul Kannan",
  "version": "1.0.0",
  "description": "Every collectible, mask shard and secret wall.",
  "wiki": "https://hollowknight.wiki/w/",
  "categoryGroups": [
    { "id": "collectibles", "name": "Collectibles" },
    { "id": "navigation",   "name": "Navigation" }
  ],
  "categories": [
    { "id": "mask_shard", "name": "Mask Shards", "group": "collectibles", "color": "#E8E8F0", "icon": "heart" },
    { "id": "spool",      "name": "Spool Fragments", "group": "collectibles", "color": "#E05A6A", "icon": "star" },
    { "id": "bench",      "name": "Benches",     "group": "navigation",   "color": "#7FB2F0", "icon": "bench",
      "wiki": "Bench (Silksong)" }
  ],
  "maps": [
    {
      "id": "world",
      "name": "Pharloom",
      "image": { "width": 16384, "height": 12288 },
      "tileSize": 256,
      "minZoom": 0,
      "maxZoom": 6,
      "tiles": {
        "archive": "https://github.com/rahulkannan/tome-silksong/releases/download/v1.0.0/world-tiles.zip",
        "archiveBytes": 184320000,
        "path": "{z}/{x}/{y}.png"
      },
      "markers": "markers/world.json",
      "initialView": { "x": 8192, "y": 6144, "zoom": 2 }
    }
  ]
}
```

| Field | Required | Notes |
| --- | --- | --- |
| `schemaVersion` | yes | Always `1` for now. The app refuses packs with a newer major version. |
| `id` | yes | Globally unique. Convention: `<github-user>.<pack-name>`, lowercase, `[a-z0-9._-]`. Never change it after publishing — progress is keyed on it. |
| `version` | yes | Semver. Bump it to make the app offer an update. |
| `wiki` | no | Base URL that wiki page names are appended to (spaces become `_`). Lets markers and categories link to a wiki by page name. |
| `categoryGroups` | no | Headings that categories are filed under in the filter panel, in display order. |
| `categories` | no | Marker types, in display order. Each has `id`, `name`, and optionally `group` (a `categoryGroups` id), `color` (`#RRGGBB`) and `icon` (see below). Categories with no group are listed under "Other". A category's `wiki` page is the default link for its markers. A category's `description` (with optional `source`) is shown as "About …" on each of its markers. |
| `maps[].id` | yes | Unique within the pack. |
| `maps[].image` | yes | Pixel size of the original full-resolution image. |
| `maps[].maxZoom` | yes | Zoom level where tiles are at native image resolution. The slicer prints this. |
| `maps[].tiles.archive` | yes | URL of the zip of tiles. Relative paths are resolved against the pack root (useful for local testing). |
| `maps[].tiles.path` | yes | Path template of tiles *inside* the zip. |
| `maps[].markers` | no | Path to a markers file, relative to the pack root. |
| `maps[].initialView` | no | Where the camera starts, in image pixels. |
| `maps[].regions` | no | Named regions and areas of this map. See below. |
| `maps[].description` | no | About this map, shown in its info sheet (with optional `source` credit). |
| `maps[].wiki` | no | Wiki page for this map. |
| `maps[].zoomsInto` | no | A detailed map that zooming in anywhere on this one continues on. See below. |
| `maps[].layout` | no | Layout file the map's image is composed from (see below). Used by TOME Studio and `tools/compose_map.py`; the app ignores it. |

### Regions and areas

A map's `regions` list its named places. They appear in the map's info sheet (ⓘ) with
their notes and found counts, and in search, so place names don't need markers cluttering
the map. A region is either a point or an outline:

```json
"regions": [
  { "id": "mosshome", "name": "Mosshome", "x": 629, "y": 218, "wiki": "Mosshome",
    "description": "A ruined settlement above Bone Bottom…",
    "source": { "name": "Hollow Knight Wiki: Bone Bottom (Mosshome)", "url": "…", "license": "CC BY-SA 3.0" } }
]
```

#### Linking an overview to detailed maps

Large games can ship a world overview plus separate detailed maps, and only load the detail
when it's opened. A region with an `outline` and a `map` opens that map:

```json
"regions": [
  {
    "id": "bone_bottom",
    "name": "Bone Bottom",
    "map": "bone_bottom",
    "outline": [[239, 524], [361, 524], [361, 641], [142, 687], [67, 642]],
    "target": { "x": 20, "y": 60, "width": 740, "height": 590 }
  }
]
```

| Field | Required | Notes |
| --- | --- | --- |
| `id`, `name` | yes | |
| `x`, `y` | one of these or `outline` | Label point, in this map's pixels. Where "Go there" centres. |
| `outline` | one of these or `x`/`y`; required with `map` | Polygon in this map's pixels, at least 3 points. Markers inside it count towards the region's found total. |
| `map` | no | Id of a more detailed map this region opens. |
| `target` | no | The rectangle of the opened map that this region corresponds to. Defaults to the whole image. Lets several regions share one detailed map. |
| `wiki`, `description`, `source` | no | As for markers. |

In the app, tapping inside a region opens its map, and zooming in on a region swaps to it at
the matching spot; zooming out of the detailed map swaps back. The two maps don't need to
share geometry (a stylised overview is fine): positions are carried across by mapping the
outline's bounding box onto `target`. A map whose tiles show the whole world in full detail
doesn't need regions at all.

### Zooming from an overview into a detailed map

If a game has a stylised overview *and* a detailed map of the whole world, link them with
matching points, e.g. each region's label on both. Zooming in anywhere on the overview then
swaps to the detailed map at the matching spot, with all the surrounding areas present, and
zooming out swaps back:

```json
"zoomsInto": {
  "map": "pharloom_detailed",
  "points": [[896, 104, 3645, 150], [1150, 600, 1833, 4038], ...]
}
```

Each point is `[overviewX, overviewY, detailX, detailY]`; at least 2, and more give a closer
match. Add `"regions": ["bone_bottom", ...]` (ids of outlined overview regions) when the
detailed map only covers part of the world so far: zooming in elsewhere stays on the
overview instead of showing empty space, and the covered regions are outlined. Positions between points are blended from the nearest ones, so the two maps don't need
to share geometry. Prefer this over region maps when you have a detailed map of everything:
region maps show only their region, with gaps around it.

If your detailed art comes as separate per-region images, place them on one canvas with
TOME Studio's **Pieces** tab or `tools/compose_map.py` (a small JSON layout of image positions,
named by the map's `layout`) and slice the result: the regions then line up with their
neighbours. Keep the canvas size fixed as you add regions so marker positions never change
(the studio's *Fit canvas* shifts markers along when it does change it).

### Category icons

`icon` must be one of these built-in names (unknown names fall back to `circle`):

`circle`, `star`, `heart`, `chest`, `key`, `gem`, `coin`, `shield`, `book`, `scroll`, `flag`, `door`, `bench`, `bell`, `boss`, `enemy`, `npc`, `shop`, `quest`, `secret`, `puzzle`, `travel`, `save`, `tool`, `skill`, `upgrade`, `map`, `music`, `flower`, `fish`, `bug`, `water`, `note`

Each game decides its own groups and categories; the app has no built-in notion of
"collectible" or "boss". A category's `id` is what markers reference and what the app
remembers filter choices by, so don't rename it after publishing.

## Publishing

Commit `pack.json` and `markers/` to a public GitHub repo (a pack can live in a subfolder),
and attach the tile zips to a GitHub Release. `tools/publish_pack.py <pack> --repo owner/repo`
sets each `tiles.archive` to the release URL and prints the `gh release create` command.
Players add the pack in the app with `owner/repo/folder`. Bump `version` to publish an
update; the app compares versions when the player checks for updates.

A step-by-step guide for making a pack is in the
[demo_maps README](https://github.com/rahulskann/demo_maps#make-your-own-map).

## Offline content and links

Everything a player needs on the go — name, position, category, `description` — is stored in
the pack and works offline. Wiki pages and `links` are optional extras that open in the browser
when tapped. If you adapt text from a wiki, check its licence (many use CC BY-SA, which
requires credit and the same licence for your marker data), set `source` on each adapted
entry, and credit the wiki in the pack README.

`tools/wiki_text.py` fetches a page's text and "What's here" lists from any MediaWiki
(politely: cached, one request per second). A pack can script it to fill notes, as
`demo_maps/silksong/tools/enrich_from_wiki.py` does; only fill entries that are empty or
were filled before, so hand-written notes are never replaced.

## Markers file

```json
[
  {
    "id": "grotto_stash_01",
    "name": "Moss Grotto Hidden Shell Stash",
    "category": "collectible",
    "x": 1420,
    "y": 842,
    "description": "Jump-dash from the breaking ledge above the first bench, then strike the left wall."
  }
]
```

| Field | Required | Notes |
| --- | --- | --- |
| `id` | yes | Unique within the pack. Never reuse or change it — progress is keyed on it. |
| `name` | yes | |
| `category` | no | Must match a `categories[].id` if given. |
| `x`, `y` | yes | Pixel coordinates on the full-resolution image. Origin top-left, `y` grows down. |
| `description` | no | Plain text (Markdown support planned). |
| `wiki` | no | Wiki page name (resolved against the pack's `wiki`) or a full URL. Overrides the category's page. |
| `source` | no | Credit for an adapted `description`: `{ "name": "Hollow Knight Wiki: Greymoor", "url": "https://…", "license": "CC BY-SA 3.0" }`. Shown under the text. |
| `map` | no | Id of a map to open when the marker is tapped (doors, lifts, region labels). |
| `links` | no | Extra links: `[{ "label": "Video guide", "url": "https://…" }]`. |
| `trackable` | no | Default `true`. Set `false` for markers that can't be "checked off" (e.g. benches used only for navigation). |

Machine-readable schemas: [`schemas/pack.schema.json`](../schemas/pack.schema.json),
[`schemas/markers.schema.json`](../schemas/markers.schema.json).
