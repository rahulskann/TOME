import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'pack.dart';

// On-device layout, shared by bundled, sideloaded and (Phase 2) downloaded packs:
//
//   <app support>/packs/<packId>/
//   ├── pack.json            written last; a folder without it is incomplete
//   ├── markers/<file>.json  at the paths pack.json names
//   └── <mapId>/tiles/{z}/{x}/{y}.png
//
// tools/sideload_pack.py writes this same layout over USB.

/// A pack whose maps are ready to render from local files.
class InstalledPack {
  const InstalledPack({
    required this.dir,
    required this.manifest,
    required this.markers,
  });

  final String dir;
  final PackManifest manifest;

  /// Map id -> markers for that map.
  final Map<String, List<MapMarker>> markers;

  /// Absolute tile path template for FileTileProvider.
  String tileTemplate(MapDefinition map) => p.join(dir, map.id, 'tiles', map.tilesPath);
}

Future<Directory> packsRoot() async =>
    Directory(p.join((await getApplicationSupportDirectory()).path, 'packs'));

/// Reads every complete pack on the device, sorted by name. Packs that fail
/// to parse are skipped and reported through [onError].
Future<List<InstalledPack>> listInstalledPacks(
    {void Function(String dir, Object error)? onError}) async {
  final root = await packsRoot();
  if (!await root.exists()) return [];
  final packs = <InstalledPack>[];
  await for (final entry in root.list()) {
    if (entry is! Directory) continue;
    if (!await File(p.join(entry.path, 'pack.json')).exists()) continue;
    try {
      packs.add(await openInstalledPack(entry.path));
    } catch (e) {
      onError?.call(entry.path, e);
    }
  }
  packs.sort((a, b) => a.manifest.name.toLowerCase().compareTo(b.manifest.name.toLowerCase()));
  return packs;
}

Future<InstalledPack> openInstalledPack(String dir) async {
  final manifest = PackManifest.fromJson(
      jsonDecode(await File(p.join(dir, 'pack.json')).readAsString())
          as Map<String, dynamic>);
  final markers = <String, List<MapMarker>>{};
  for (final map in manifest.maps) {
    final file = File(p.join(dir, map.markersFile));
    markers[map.id] = !await file.exists()
        ? const []
        : MapMarker.listFromJson(jsonDecode(await file.readAsString()) as List);
  }
  return InstalledPack(dir: dir, manifest: manifest, markers: markers);
}

/// Writes [markers] as [map]'s markers file, replacing it atomically so a
/// crash mid-write can't leave a truncated file.
Future<void> saveMarkers(
    InstalledPack pack, MapDefinition map, List<MapMarker> markers) async {
  final file = File(p.join(pack.dir, map.markersFile));
  await file.parent.create(recursive: true);
  final tmp = File('${file.path}.tmp');
  await tmp.writeAsString(markersToJson(markers));
  await tmp.rename(file.path);
  pack.markers[map.id] = List.unmodifiable(markers);
}

/// Pretty-printed markers file contents, as the pack repo stores them.
String markersToJson(List<MapMarker> markers) {
  final json = [for (final m in markers) m.toJson()];
  return '${const JsonEncoder.withIndent('  ').convert(json)}\n';
}

/// Copies a pack shipped in the app's assets into the store, unless that
/// version is already installed.
Future<void> installBundledPack(String assetRoot) async {
  final manifestJson = await rootBundle.loadString('$assetRoot/pack.json');
  final manifest = PackManifest.fromJson(
      jsonDecode(manifestJson) as Map<String, dynamic>);

  final dir = Directory(p.join((await packsRoot()).path, manifest.id));
  final installed = File(p.join(dir.path, 'pack.json'));
  if (await installed.exists()) {
    try {
      final current = jsonDecode(await installed.readAsString()) as Map<String, dynamic>;
      if (current['version'] == manifest.version) {
        // Installs from before the marker existed need it too.
        await File(p.join(dir.path, '.bundled')).writeAsString('');
        return;
      }
    } on FormatException {
      // Corrupt manifest: fall through and reinstall.
    }
  }

  if (await dir.exists()) await dir.delete(recursive: true);
  for (final map in manifest.maps) {
    final markersPath = map.markersPath;
    if (markersPath != null) {
      final out = File(p.join(dir.path, markersPath));
      await out.parent.create(recursive: true);
      await out.writeAsString(await rootBundle.loadString('$assetRoot/$markersPath'));
    }
    final bytes = await rootBundle.load('$assetRoot/${map.tilesArchive}');
    await extractArchiveToDisk(ZipDecoder().decodeBytes(bytes.buffer.asUint8List()),
        p.join(dir.path, map.id, 'tiles'));
  }
  // Marks it as shipped with the app (not deletable or updatable from a link).
  await File(p.join(dir.path, '.bundled')).writeAsString('');
  await installed.writeAsString(manifestJson);
}
