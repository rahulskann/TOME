import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../pack/pack.dart';

// Progress lives apart from the pack, so installing a new pack version or
// re-sideloading never touches it. Each pack has save slots, like save files in
// a game; each slot remembers which markers were found:
//
//   <app support>/progress/<packId>/slots.json    which slots exist, which is active
//   <app support>/progress/<packId>/<slotId>.json one slot's markers
//
// Un-ticking keeps the marker with done: false and the time, rather than
// forgetting it, so a later merge of two copies can tell "never found" from
// "un-found since". Version 1 (one file, <packId>.json, found markers only)
// becomes the first slot the first time it's opened.

/// One save slot of a pack. The first slot has no name until a second is added.
@immutable
class SaveSlot {
  const SaveSlot({required this.id, this.name});

  final String id;
  final String? name;

  SaveSlot named(String? name) => SaveSlot(id: id, name: name);

  @override
  bool operator ==(Object other) => other is SaveSlot && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);
}

/// Whether a marker is found, and when that last changed.
typedef MarkerProgress = ({bool done, DateTime updatedAt});

/// Which markers of one pack the player has found, in the active save slot.
/// Switching slots reloads it and notifies listeners, so every screen follows.
/// Keyed by marker id, which packs promise never to change or reuse.
class ProgressStore extends ChangeNotifier {
  ProgressStore._(this.packId, this._dir, this._slots, this._active, this._markers);

  /// Opens [packId]'s progress, converting a version 1 file if there is one.
  /// Nothing is written until the first change. [directory] is the progress
  /// root (`<app support>/progress`), overridden in tests.
  static Future<ProgressStore> load(String packId, {Directory? directory}) async {
    final root = directory ??
        Directory(p.join((await getApplicationSupportDirectory()).path, 'progress'));
    final dir = Directory(p.join(root.path, packId));
    await _migrateV1(root, dir, packId);

    var slots = <SaveSlot>[];
    String? active;
    final index = File(p.join(dir.path, 'slots.json'));
    if (await index.exists()) {
      try {
        (slots, active) = _parseSlots(await index.readAsString());
      } on FormatException catch (e) {
        debugPrint('Save slots for $packId were unreadable; rebuilding from the slot files: $e');
      }
    }
    if (slots.isEmpty) slots = await _slotsFromFiles(dir, packId);
    if (slots.isEmpty) slots = [const SaveSlot(id: 'main')];
    final current = slots.firstWhere((s) => s.id == active, orElse: () => slots.first);
    final markers = await _readSlot(dir, packId, current.id);
    return ProgressStore._(packId, dir, slots, current.id, markers);
  }

  final String packId;
  final Directory _dir;
  List<SaveSlot> _slots;
  String _active;
  Map<String, MarkerProgress> _markers;
  Future<void> _pendingWrite = Future.value();

  /// All slots, in the order they were added.
  List<SaveSlot> get slots => List.unmodifiable(_slots);

  SaveSlot get activeSlot => _slots.firstWhere((s) => s.id == _active);

  bool isFound(String markerId) => _markers[markerId]?.done ?? false;

  /// Found markers in the active slot, including ids no longer in the pack.
  /// For screens, count from the pack's markers with [tally] instead.
  int get foundCount => _markers.values.where((m) => m.done).length;

  void setFound(String markerId, bool found) {
    if (found == isFound(markerId)) return;
    _markers[markerId] = (done: found, updatedAt: DateTime.now());
    notifyListeners();
    _saveSlot();
  }

  void toggle(String markerId) => setFound(markerId, !isFound(markerId));

  /// Found / total over [markers], counting only trackable ones.
  ({int found, int total}) tally(Iterable<MapMarker> markers) => _tally(_markers, markers);

  /// Like [tally], for any slot (read from disk unless it's the active one).
  Future<({int found, int total})> tallyIn(String slotId, Iterable<MapMarker> markers) async {
    if (slotId == _active) return tally(markers);
    await _pendingWrite;
    return _tally(await _readSlot(_dir, packId, slotId), markers);
  }

  /// Makes [slotId] the active slot.
  Future<void> switchTo(String slotId) async {
    if (slotId == _active || !_slots.any((s) => s.id == slotId)) return;
    await _pendingWrite;
    _markers = await _readSlot(_dir, packId, slotId);
    _active = slotId;
    notifyListeners();
    _saveIndex();
  }

  /// Adds an empty slot called [name] and switches to it. If the current only
  /// slot has no name yet, [currentName] names it (and is then required).
  Future<SaveSlot> addSlot(String name, {String? currentName}) async {
    if (_slots.length == 1 && _slots.single.name == null) {
      if (currentName == null || currentName.trim().isEmpty) {
        throw ArgumentError('Name the current slot before adding another');
      }
      _slots = [_slots.single.named(currentName.trim())];
      _saveSlot(); // its file carries the name too
    }
    final slot = SaveSlot(id: _newSlotId(), name: name.trim());
    _slots = [..._slots, slot];
    await _pendingWrite;
    _markers = {};
    _active = slot.id;
    notifyListeners();
    _saveIndex();
    _saveSlot();
    return slot;
  }

  void renameSlot(String slotId, String name) {
    _slots = [for (final s in _slots) s.id == slotId ? s.named(name.trim()) : s];
    notifyListeners();
    _saveIndex();
    if (slotId == _active) _saveSlot(); // its file carries the name too
  }

  /// Deletes a slot and its progress. The last slot can't be deleted; deleting
  /// the active one switches to the first remaining slot.
  Future<void> deleteSlot(String slotId) async {
    if (_slots.length <= 1) throw StateError('A pack always keeps at least one slot');
    final remaining = [for (final s in _slots) if (s.id != slotId) s];
    if (slotId == _active) {
      await _pendingWrite;
      _markers = await _readSlot(_dir, packId, remaining.first.id);
      _active = remaining.first.id;
    }
    _slots = remaining;
    notifyListeners();
    _saveIndex();
    _pendingWrite = _pendingWrite.then((_) async {
      final f = File(p.join(_dir.path, '$slotId.json'));
      if (await f.exists()) await f.delete();
    });
  }

  /// The active slot's file contents, suitable for export.
  String toJsonString() => encodeProgress(packId, activeSlot, _markers);

  /// Completes when every change so far is on disk.
  Future<void> flush() => _pendingWrite;

  String _newSlotId() {
    var n = _slots.length + 1;
    while (_slots.any((s) => s.id == 'slot$n')) {
      n++;
    }
    return 'slot$n';
  }

  // Writes are chained so they land in order, and go through a temp file so a
  // crash can't leave a half-written file.
  void _saveSlot() {
    final file = File(p.join(_dir.path, '$_active.json'));
    _write(file, encodeProgress(packId, activeSlot, _markers));
  }

  void _saveIndex() => _write(File(p.join(_dir.path, 'slots.json')), _encodeSlots(_slots, _active));

  void _write(File file, String text) {
    _pendingWrite = _pendingWrite.then((_) => _atomicWrite(file, text)).catchError(
        (Object e) => debugPrint('Could not save progress for $packId: $e'));
  }
}

({int found, int total}) _tally(Map<String, MarkerProgress> progress, Iterable<MapMarker> markers) {
  var found = 0, total = 0;
  for (final m in markers) {
    if (!m.trackable) continue;
    total++;
    if (progress[m.id]?.done ?? false) found++;
  }
  return (found: found, total: total);
}

Future<void> _atomicWrite(File file, String text) async {
  await file.parent.create(recursive: true);
  final tmp = File('${file.path}.tmp');
  await tmp.writeAsString(text);
  await tmp.rename(file.path);
}

/// Reads one slot's markers; an unreadable file is set aside, not overwritten.
Future<Map<String, MarkerProgress>> _readSlot(Directory dir, String packId, String slotId) async {
  final file = File(p.join(dir.path, '$slotId.json'));
  if (!await file.exists()) return {};
  try {
    return parseProgress(await file.readAsString(), packId).markers;
  } on FormatException catch (e) {
    await file.rename('${file.path}.corrupt-${DateTime.now().millisecondsSinceEpoch}');
    debugPrint('Progress for $packId ($slotId) was unreadable and has been set aside: $e');
    return {};
  }
}

/// Version 1 kept one file per pack beside the pack folders: it becomes the
/// first (unnamed) slot. The old file is removed once the new one is written.
Future<void> _migrateV1(Directory root, Directory dir, String packId) async {
  final old = File(p.join(root.path, '$packId.json'));
  if (!await old.exists()) return;
  if (await File(p.join(dir.path, 'slots.json')).exists()) {
    await old.delete(); // converted before; the delete didn't happen
    return;
  }
  final Map<String, MarkerProgress> markers;
  try {
    markers = parseProgress(await old.readAsString(), packId).markers;
  } on FormatException catch (e) {
    await old.rename('${old.path}.corrupt-${DateTime.now().millisecondsSinceEpoch}');
    debugPrint('Progress for $packId was unreadable and has been set aside: $e');
    return;
  }
  const slot = SaveSlot(id: 'main');
  await _atomicWrite(File(p.join(dir.path, '${slot.id}.json')), encodeProgress(packId, slot, markers));
  await _atomicWrite(File(p.join(dir.path, 'slots.json')), _encodeSlots([slot], slot.id));
  await old.delete();
}

/// Slots from the slot files themselves, when slots.json is missing or broken.
Future<List<SaveSlot>> _slotsFromFiles(Directory dir, String packId) async {
  if (!await dir.exists()) return [];
  final slots = <SaveSlot>[];
  await for (final f in dir.list()) {
    if (f is! File || !f.path.endsWith('.json') || p.basename(f.path) == 'slots.json') continue;
    try {
      final parsed = parseProgress(await f.readAsString(), packId);
      slots.add(SaveSlot(id: p.basenameWithoutExtension(f.path), name: parsed.slotName));
    } on FormatException {
      continue;
    }
  }
  return slots..sort((a, b) => a.id.compareTo(b.id));
}

String _encodeSlots(List<SaveSlot> slots, String active) =>
    '${const JsonEncoder.withIndent('  ').convert({
      'format': 'tome-slots',
      'version': 1,
      'active': active,
      'slots': [for (final s in slots) {'id': s.id, 'name': s.name}],
    })}\n';

(List<SaveSlot>, String?) _parseSlots(String text) {
  final json = jsonDecode(text);
  if (json is! Map<String, dynamic> || json['format'] != 'tome-slots') {
    throw const FormatException('Not a save slots file');
  }
  final slots = [
    for (final s in json['slots'] as List? ?? const [])
      if (s is Map<String, dynamic> && s['id'] is String)
        SaveSlot(id: s['id'] as String, name: s['name'] as String?),
  ];
  return (slots, json['active'] as String?);
}

/// One slot's file (version 2):
/// `{"format": "tome-progress", "version": 2, "pack": id, "slot": slotId, "slotName": name|null,
///   "markers": {markerId: {"done": bool, "updatedAt": iso8601}}}`
String encodeProgress(String packId, SaveSlot slot, Map<String, MarkerProgress> markers) {
  final ids = markers.keys.toList()..sort();
  return '${const JsonEncoder.withIndent('  ').convert({
    'format': 'tome-progress',
    'version': 2,
    'pack': packId,
    'slot': slot.id,
    'slotName': slot.name,
    'markers': {
      for (final id in ids)
        id: {'done': markers[id]!.done, 'updatedAt': markers[id]!.updatedAt.toUtc().toIso8601String()},
    },
  })}\n';
}

/// Reads a progress file: version 2, or version 1 (found markers only).
({Map<String, MarkerProgress> markers, String? slotName}) parseProgress(String text, String expectedPackId) {
  final json = jsonDecode(text);
  if (json is! Map<String, dynamic> || json['format'] != 'tome-progress') {
    throw const FormatException('Not a progress file saved by TOME');
  }
  final version = json['version'] as int? ?? 0;
  if (version > 2) throw const FormatException('Progress file is from a newer version of TOME');
  if (json['pack'] != expectedPackId) {
    throw FormatException('Progress is for pack ${json['pack']}, not $expectedPackId');
  }
  DateTime time(Object? v) => DateTime.tryParse(v as String? ?? '') ?? DateTime.now();
  if (version < 2) {
    final found = json['found'] as Map<String, dynamic>? ?? const {};
    return (
      markers: {for (final e in found.entries) e.key: (done: true, updatedAt: time(e.value))},
      slotName: null,
    );
  }
  final markers = json['markers'] as Map<String, dynamic>? ?? const {};
  return (
    markers: {
      for (final e in markers.entries)
        if (e.value is Map<String, dynamic>)
          e.key: (
            done: (e.value as Map<String, dynamic>)['done'] == true,
            updatedAt: time((e.value as Map<String, dynamic>)['updatedAt']),
          ),
    },
    slotName: json['slotName'] as String?,
  );
}
