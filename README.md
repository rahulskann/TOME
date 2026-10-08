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
| [`app/`](app/) | The Flutter app (Android; iOS builds need a Mac) |
| [`studio/`](studio/) | TOME Studio: a website for making packs in the browser |
| [`docs/`](docs/) | Architecture, pack format, roadmap |
| [`schemas/`](schemas/) | JSON Schemas for `pack.json` and markers files |
| [`tools/`](tools/) | Python tools: slicer, compose, publish, sideload, wiki text |
| [`examples/demo-pack/`](examples/demo-pack/) | A minimal example pack |

## Making a map pack

**Easiest:** use [TOME Studio](studio/) in your browser: add your map image, place markers,
export, and follow the included publishing steps.

**By hand:** slice your image with `python tools/slicer/slice_map.py world.png out/ --map-id world --zip`,
write `pack.json` and markers ([docs/pack-format.md](docs/pack-format.md)), push them to a
GitHub repo, and attach the tile zip to a release (`tools/publish_pack.py` helps). A full
walkthrough is in the [demo_maps README](https://github.com/rahulskann/demo_maps#make-your-own-map).

Players add a pack in the app by its link, e.g. `rahulskann/demo_maps/silksong`.

## Status

Early development. See [docs/roadmap.md](docs/roadmap.md).

## Support

TOME is free. If it's useful to you, you can [buy me a coffee](https://buymeacoffee.com/rahulskann):
it helps keep the map maker online and funds future projects.

## License

[MIT](LICENSE)
