import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'pack_installer.dart';
import 'pack_store.dart';

// The packs the user has added, and where from. It lives outside the packs
// folder so Android's backup includes it while leaving the (large) packs out:
// after a restore on a new phone, packs listed here but not installed are
// offered for download again, and their progress is already back.
//
//   <app support>/known-packs.json
//   {"format": "tome-known-packs", "version": 1,
//    "packs": {"<packId>": {"name": "...", "link": "owner/repo/folder" | null}}}

/// A pack the user has added on this phone (or a phone this one was restored from).
class KnownPack {
  const KnownPack({required this.id, required this.name, this.link});

  final String id;
  final String name;

  /// Where it was added from; null when it wasn't added from a link.
  final String? link;

  Map<String, dynamic> toJson() => {'name': name, 'link': link};

  @override
  bool operator ==(Object other) =>
      other is KnownPack && other.id == id && other.name == name && other.link == link;

  @override
  int get hashCode => Object.hash(id, name, link);
}

Future<File> knownPacksFile() async =>
    File(p.join((await getApplicationSupportDirectory()).path, 'known-packs.json'));

/// The recorded packs by id. A missing or unreadable file reads as none.
Future<Map<String, KnownPack>> readKnownPacks({File? file}) async {
  final f = file ?? await knownPacksFile();
  if (!await f.exists()) return {};
  try {
    final json = jsonDecode(await f.readAsString());
    if (json is! Map<String, dynamic> || json['format'] != 'tome-known-packs') return {};
    final packs = json['packs'] as Map<String, dynamic>? ?? const {};
    return {
      for (final MapEntry(:key, :value) in packs.entries)
        if (value is Map<String, dynamic>)
          key: KnownPack(id: key, name: value['name'] as String? ?? key, link: value['link'] as String?),
    };
  } on FormatException {
    return {};
  }
}

Future<void> _write(File f, Map<String, KnownPack> packs) async {
  await f.parent.create(recursive: true);
  final tmp = File('${f.path}.tmp');
  await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert({
    'format': 'tome-known-packs',
    'version': 1,
    'packs': {for (final k in packs.values) k.id: k.toJson()},
  }));
  await tmp.rename(f.path);
}

/// Records the [installed] packs (not those shipped with the app, which come
/// back by themselves) and returns the recorded ones that aren't on the phone,
/// sorted by name. [presentIds] are packs whose folder exists but couldn't be
/// opened: those aren't missing either.
Future<List<KnownPack>> updateKnownPacks(
  List<InstalledPack> installed, {
  Set<String> presentIds = const {},
  File? file,
}) async {
  final f = file ?? await knownPacksFile();
  final known = await readKnownPacks(file: f);
  final updated = {...known};
  for (final pack in installed) {
    if (isBundled(pack)) continue;
    final id = pack.manifest.id;
    updated[id] = KnownPack(id: id, name: pack.manifest.name, link: await installedFrom(pack));
  }
  final changed = updated.length != known.length ||
      updated.entries.any((e) => known[e.key] != e.value);
  if (changed) await _write(f, updated);

  final here = {for (final pack in installed) pack.manifest.id, ...presentIds};
  return [
    for (final k in updated.values)
      if (!here.contains(k.id)) k,
  ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
}

/// Stops listing [id]: for packs the user deleted or dismissed.
Future<void> forgetKnownPack(String id, {File? file}) async {
  final f = file ?? await knownPacksFile();
  final known = await readKnownPacks(file: f);
  if (known.remove(id) != null) await _write(f, known);
}
