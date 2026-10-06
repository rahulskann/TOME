# TOME

**An offline-first interactive map engine for any game — video games, tabletop campaigns, homebrew worlds.**

TOME is a native mobile app (iOS / iPadOS / Android) that works like an emulator for maps:
the app is just the engine, and the content comes from **map packs** that anyone can
publish from their own GitHub repository.

- **Offline first.** Download a pack once and it works with no connection — on a plane,
  on a train, anywhere. Tiles are stored on the device, not streamed.
- **Any map.** Not tied to real-world geography. Any big image becomes a pannable,
  zoomable, tiled map with markers.
- **Community packs, zero servers.** Packs live in ordinary GitHub repos. Make yours
  public and others can add it by URL. No database, no hosting bill.
- **Track progress.** Check off collectibles and secrets; progress is stored locally
  and (later) synced across your devices.
- **DM mode (planned).** Tabletop packs can hide layers from players until the DM
  unlocks them.

## Repository layout

| Path | What it is |
| --- | --- |
| [`app/`](app/) | The Flutter app (not scaffolded yet — see below) |
| [`docs/`](docs/) | Architecture, pack format, roadmap |
| [`schemas/`](schemas/) | JSON Schemas for `pack.json` and markers files |
| [`tools/slicer/`](tools/slicer/) | Python tool that turns a huge map image into a tile pack |
| [`examples/demo-pack/`](examples/demo-pack/) | A minimal example pack |

## Making a map pack

1. Get a high-resolution image of your map.
2. Slice it: `python tools/slicer/slice_map.py world.png out/ --map-id world --zip`
3. Write a `pack.json` and a markers file (see [docs/pack-format.md](docs/pack-format.md)).
4. Push `pack.json` + markers to a GitHub repo and attach the tile zip to a GitHub Release.
5. In the app, add the pack by its repo URL.

## Status

Early development. See [docs/roadmap.md](docs/roadmap.md).

## License

[MIT](LICENSE)
