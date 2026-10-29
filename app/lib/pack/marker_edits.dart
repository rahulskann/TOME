import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'pack.dart';
import 'pack_installer.dart' show installedSnapshotDir, sideloadedSnapshotDir;
import 'pack_store.dart';

// Markers the user added, changed or deleted on this phone, kept apart from the
// pack so a pack update never replaces them, and shared by all save slots:
//
//   <app support>/edits/<packId>.json
//   {"format": "tome-edits", "version": 1, "pack": id,
//    "markers": {markerId: {"map": mapId, "marker": {...} | null, "updatedAt": iso8601}}}
//
// "marker" is the user's whole version of the marker; null means deleted. The
// user's version always wins: a marker the author changed or removed after it
// was edited here shows as edited. Reset to pack version drops an edit.
//
// Photos added on the phone live beside the edits, at the path they'd have in
// the pack (so the PC tools can copy them straight in), and are left out of the
// cloud backup for size (see data_extraction_rules.xml):
//
//   <app support>/photos/<packId>/photos/<markerId>-<ms>.jpg
//
// A marker's "photo" is looked for there first, then in the pack.

/// One marker as edited on this phone.
@immutable
class MarkerEdit {
  const MarkerEdit({required this.map, required this.marker, required this.updatedAt});

  final String map;

  /// The user's version, or null if they deleted it.
  final MapMarker? marker;
  final DateTime updatedAt;

  bool get deleted => marker == null;
}

/// The user's marker edits for one pack.
class MarkerEdits {
  MarkerEdits._(this.packId, this._file, this._edits, this.photosDir);

  /// [directory] is the edits folder (`<app support>/edits`), and [photos] the
  /// pack's photo folder (`<app support>/photos/<packId>`); both overridden in tests.
  static Future<MarkerEdits> load(String packId, {Directory? directory, Directory? photos}) async {
    final dir = directory ?? Directory(p.join((await getApplicationSupportDirectory()).path, 'edits'));
    final file = File(p.join(dir.path, '$packId.json'));
    final edits = <String, MarkerEdit>{}; // keeps insertion order
    var readable = true;
    if (await file.exists()) {
      try {
        edits.addAll(parseEdits(await file.readAsString(), packId));
      } on FormatException catch (e) {
        readable = false;
        await file.rename('${file.path}.corrupt-${DateTime.now().millisecondsSinceEpoch}');
        debugPrint('Marker edits for $packId were unreadable and have been set aside: $e');
      }
    }
    final loaded = MarkerEdits._(
        packId, file, edits, photos ?? Directory(p.join(p.dirname(dir.path), 'photos', packId)));
    // Photos are only tidied against edits that could be read, so setting a
    // broken file aside never costs the photos it used.
    if (readable) await loaded._removeUnusedPhotos();
    return loaded;
  }

  final String packId;
  final File _file;

  /// Where photos added on this phone are kept, at their pack paths.
  final Directory photosDir;

  /// In the order they were first made, so added markers keep their order.
  final Map<String, MarkerEdit> _edits;
  Future<void> _pendingWrite = Future.value();

  bool get isEmpty => _edits.isEmpty;

  /// The marker was changed or added here (not deleted).
  bool isEdited(String markerId) => _edits[markerId]?.deleted == false;

  /// Markers deleted on [mapId] that the pack still has.
  int deletedCount(String mapId, List<MapMarker> packMarkers) {
    final ids = {for (final m in packMarkers) m.id};
    return _edits.entries.where((e) => e.value.map == mapId && e.value.deleted && ids.contains(e.key)).length;
  }

  /// [packMarkers] for [mapId] with the user's edits applied: their versions
  /// in place, deletions left out, and markers only they have at the end.
  List<MapMarker> apply(String mapId, List<MapMarker> packMarkers) {
    final inPack = {for (final m in packMarkers) m.id};
    return [
      for (final m in packMarkers)
        if (_edits[m.id] case final e?) ?e.marker else m,
      for (final MapEntry(:key, :value) in _edits.entries)
        if (value.map == mapId && !inPack.contains(key)) ?value.marker,
    ];
  }

  /// Records [markers] as what the user wants [mapId] to show, as differences
  /// from [packMarkers]. Unchanged edits keep their times.
  void record(String mapId, List<MapMarker> packMarkers, List<MapMarker> markers) {
    final now = DateTime.now();
    final pack = {for (final m in packMarkers) m.id: m};
    final wanted = {for (final m in markers) m.id: m};
    void put(String id, MapMarker? marker) {
      final old = _edits[id];
      if (old != null && old.map == mapId && _same(old.marker, marker)) return;
      _edits[id] = MarkerEdit(map: mapId, marker: marker, updatedAt: now);
    }

    for (final id in pack.keys) {
      final want = wanted[id];
      if (want == null) {
        put(id, null);
      } else if (_same(want, pack[id])) {
        _edits.remove(id); // back to the pack's version
      } else {
        put(id, want);
      }
    }
    for (final m in markers) {
      if (!pack.containsKey(m.id)) put(m.id, m);
    }
    // Markers only the user had (or deleted) that are gone from this map's list.
    _edits.removeWhere((id, e) => e.map == mapId && !pack.containsKey(id) && !wanted.containsKey(id));
    _save();
  }

  /// Drops the edit to one marker, so the pack's version shows again.
  void reset(String markerId) {
    if (_edits.remove(markerId) != null) _save();
  }

  /// Brings back the pack's markers the user deleted on [mapId].
  void restoreDeleted(String mapId) {
    final before = _edits.length;
    _edits.removeWhere((_, e) => e.map == mapId && e.deleted);
    if (_edits.length != before) _save();
  }

  void _save() {
    final text = encodeEdits(packId, _edits);
    _pendingWrite = _pendingWrite.then((_) async {
      await _file.parent.create(recursive: true);
      final tmp = File('${_file.path}.tmp');
      await tmp.writeAsString(text);
      await tmp.rename(_file.path);
    }).catchError((Object e) => debugPrint('Could not save marker edits for $packId: $e'));
  }

  /// Completes when every change so far is on disk.
  Future<void> flush() => _pendingWrite;

  /// Copies a picture taken or chosen for [markerId] in with the edits and
  /// returns its path for the marker's `photo`. Saving the marker keeps it.
  Future<String> addPhoto(String markerId, String picture) async {
    var ext = p.extension(picture).toLowerCase();
    if (!const {'.jpg', '.jpeg', '.png', '.webp'}.contains(ext)) ext = '.jpg';
    final path = 'photos/$markerId-${DateTime.now().millisecondsSinceEpoch}$ext';
    final out = File(p.joinAll([photosDir.path, ...path.split('/')]));
    await out.parent.create(recursive: true);
    await File(picture).copy(out.path);
    return path;
  }

  /// The file for a marker's [photo]: one added on this phone, else the
  /// pack's (in [packDir]). Null if there's none, or it isn't here (a photo
  /// that didn't download, or wasn't in a cloud backup).
  File? photoFile(String packDir, String? photo) {
    if (photo == null || !safeImagePath(photo)) return null;
    for (final root in [photosDir.path, packDir]) {
      final file = File(p.joinAll([root, ...photo.split('/')]));
      if (file.existsSync()) return file;
    }
    return null;
  }

  /// Deletes photos no edit uses any more: replaced, removed, reset to the
  /// pack's version, or picked for a marker that was never saved.
  Future<void> _removeUnusedPhotos() async {
    if (!await photosDir.exists()) return;
    final used = {
      for (final e in _edits.values)
        if (e.marker?.photo case final photo?) p.normalize(p.joinAll([photosDir.path, ...photo.split('/')])),
    };
    try {
      await for (final f in photosDir.list(recursive: true)) {
        if (f is File && !used.contains(p.normalize(f.path))) await f.delete();
      }
    } on FileSystemException catch (e) {
      debugPrint('Could not tidy photos for $packId: $e');
    }
  }
}

bool _same(MapMarker? a, MapMarker? b) =>
    a == null || b == null ? a == b : jsonEncode(a.toJson()) == jsonEncode(b.toJson());

String encodeEdits(String packId, Map<String, MarkerEdit> edits) =>
    '${const JsonEncoder.withIndent('  ').convert({
      'format': 'tome-edits',
      'version': 1,
      'pack': packId,
      'markers': {
        for (final MapEntry(:key, :value) in edits.entries)
          key: {
            'map': value.map,
            'marker': value.marker?.toJson(),
            'updatedAt': value.updatedAt.toUtc().toIso8601String(),
          },
      },
    })}\n';

Map<String, MarkerEdit> parseEdits(String text, String expectedPackId) {
  final json = jsonDecode(text);
  if (json is! Map<String, dynamic> || json['format'] != 'tome-edits') {
    throw const FormatException('Not a marker edits file saved by TOME');
  }
  if ((json['version'] as int? ?? 0) > 1) {
    throw const FormatException('Marker edits are from a newer version of TOME');
  }
  if (json['pack'] != expectedPackId) {
    throw FormatException('Edits are for pack ${json['pack']}, not $expectedPackId');
  }
  final markers = json['markers'] as Map<String, dynamic>? ?? const {};
  return {
    for (final MapEntry(:key, :value) in markers.entries)
      if (value is Map<String, dynamic> && value['map'] is String)
        key: MarkerEdit(
          map: value['map'] as String,
          marker: value['marker'] is Map<String, dynamic>
              ? MapMarker.fromJson(value['marker'] as Map<String, dynamic>)
              : null,
          updatedAt: DateTime.tryParse(value['updatedAt'] as String? ?? '') ?? DateTime.now(),
        ),
  };
}

/// Shows [edits] on [pack]: each map's markers become the pack's with the
/// user's edits applied.
void applyMarkerEdits(InstalledPack pack, MarkerEdits edits) {
  for (final map in pack.manifest.maps) {
    pack.markers[map.id] = List.unmodifiable(edits.apply(map.id, pack.packMarkers[map.id] ?? const []));
  }
}

/// Older versions of the app saved edits by rewriting the pack's markers
/// files. This moves any such edits into [edits] and puts the files back as
/// published, using the copy kept when the pack was installed. Nothing happens
/// for files that match it (the usual case) or packs with no copy.
Future<void> adoptInPlaceEdits(InstalledPack pack, MarkerEdits edits) async {
  for (final map in pack.manifest.maps) {
    final path = map.markersPath;
    if (path == null) continue;
    final current = File(p.join(pack.dir, path));
    File? original;
    for (final dir in [installedSnapshotDir, sideloadedSnapshotDir]) {
      final f = File(p.join(pack.dir, dir, path));
      if (await f.exists()) original = f;
    }
    if (original == null || !await current.exists()) continue;
    try {
      final now = jsonDecode(await current.readAsString()) as List;
      final was = jsonDecode(await original.readAsString()) as List;
      if (jsonEncode(now) == jsonEncode(was)) continue;
      final published = MapMarker.listFromJson(was);
      edits.record(map.id, published, MapMarker.listFromJson(now));
      await edits.flush();
      await current.writeAsString(await original.readAsString());
      pack.packMarkers[map.id] = published;
    } on FormatException catch (e) {
      debugPrint('Could not compare ${pack.manifest.id}/$path with its installed copy: $e');
    }
  }
}
