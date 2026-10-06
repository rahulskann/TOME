import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../pack/pack.dart';

/// Which markers of one pack the player has found.
///
/// Stored apart from the pack, at `<app support>/progress/<packId>.json`, so
/// installing a new pack version or re-sideloading never touches it. Keyed by
/// marker id, which packs promise never to change or reuse.
class ProgressStore extends ChangeNotifier {
  ProgressStore._(this.packId, this._file, this._found);

  /// Opens the progress file for [packId], creating nothing until the first
  /// change. [directory] overrides the storage location (for tests).
  static Future<ProgressStore> load(String packId, {Directory? directory}) async {
    final dir = directory ??
        Directory(p.join((await getApplicationSupportDirectory()).path, 'progress'));
    final file = File(p.join(dir.path, '$packId.json'));
    final found = <String, DateTime>{};
    if (await file.exists()) {
      try {
        found.addAll(parseProgress(await file.readAsString(), packId));
      } on FormatException catch (e) {
        // Keep the unreadable file for inspection rather than overwrite it.
        await file.rename('${file.path}.corrupt-${DateTime.now().millisecondsSinceEpoch}');
        debugPrint('Progress for $packId was unreadable and has been set aside: $e');
      }
    }
    return ProgressStore._(packId, file, found);
  }

  final String packId;
  final File _file;
  final Map<String, DateTime> _found;
  Future<void> _pendingWrite = Future.value();

  bool isFound(String markerId) => _found.containsKey(markerId);

  int get foundCount => _found.length;

  void setFound(String markerId, bool found) {
    if (found == isFound(markerId)) return;
    if (found) {
      _found[markerId] = DateTime.now();
    } else {
      _found.remove(markerId);
    }
    notifyListeners();
    _save();
  }

  void toggle(String markerId) => setFound(markerId, !isFound(markerId));

  /// Found / total over [markers], counting only trackable ones.
  ({int found, int total}) tally(Iterable<MapMarker> markers) {
    var found = 0, total = 0;
    for (final m in markers) {
      if (!m.trackable) continue;
      total++;
      if (isFound(m.id)) found++;
    }
    return (found: found, total: total);
  }

  /// The progress file's contents, suitable for export.
  String toJsonString() => encodeProgress(packId, _found);

  // Writes are chained so they land in order, and go through a temp file so
  // a crash can't leave a half-written file.
  void _save() {
    final snapshot = toJsonString();
    _pendingWrite = _pendingWrite.then((_) async {
      await _file.parent.create(recursive: true);
      final tmp = File('${_file.path}.tmp');
      await tmp.writeAsString(snapshot);
      await tmp.rename(_file.path);
    }).catchError((Object e) => debugPrint('Could not save progress for $packId: $e'));
  }

  /// Completes when every change so far is on disk.
  Future<void> flush() => _pendingWrite;
}

/// `{"format": "tome-progress", "version": 1, "pack": id, "found": {markerId: iso8601}}`
String encodeProgress(String packId, Map<String, DateTime> found) {
  final ids = found.keys.toList()..sort();
  return '${const JsonEncoder.withIndent('  ').convert({
    'format': 'tome-progress',
    'version': 1,
    'pack': packId,
    'found': {for (final id in ids) id: found[id]!.toUtc().toIso8601String()},
  })}\n';
}

Map<String, DateTime> parseProgress(String text, String expectedPackId) {
  final json = jsonDecode(text);
  if (json is! Map<String, dynamic> || json['format'] != 'tome-progress') {
    throw const FormatException('Not a TOME progress file');
  }
  if ((json['version'] as int? ?? 0) > 1) {
    throw const FormatException('Progress file is from a newer version of TOME');
  }
  if (json['pack'] != expectedPackId) {
    throw FormatException('Progress is for pack ${json['pack']}, not $expectedPackId');
  }
  final found = json['found'] as Map<String, dynamic>;
  return {
    for (final e in found.entries)
      e.key: DateTime.tryParse(e.value as String? ?? '') ?? DateTime.now(),
  };
}
