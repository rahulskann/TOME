import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tome/pack/known_packs.dart';
import 'package:tome/pack/pack.dart';
import 'package:tome/pack/pack_store.dart';

void main() {
  late Directory root;
  late File file;
  setUp(() {
    root = Directory.systemTemp.createTempSync('tome_known_');
    file = File(p.join(root.path, 'known-packs.json'));
  });
  tearDown(() => root.deleteSync(recursive: true));

  /// An installed pack folder: with a link (as installed from one), bundled, or neither.
  InstalledPack pack(String id, String name, {String? link, bool bundled = false}) {
    final dir = Directory(p.join(root.path, 'packs', id))..createSync(recursive: true);
    if (link != null) {
      File(p.join(dir.path, '.source.json')).writeAsStringSync(jsonEncode({'input': link}));
    }
    if (bundled) File(p.join(dir.path, '.bundled')).writeAsStringSync('');
    final manifest = PackManifest.fromJson({
      'schemaVersion': 1,
      'id': id,
      'name': name,
      'version': '1',
      'maps': <Object>[],
    });
    return InstalledPack(dir: dir.path, manifest: manifest, markers: const {});
  }

  test('records added packs with their links, but not the built-in one', () async {
    final missing = await updateKnownPacks([
      pack('a.silk', 'Silksong', link: 'a/maps/silksong'),
      pack('tome.demo', 'TOME Demo', bundled: true),
      pack('a.local', 'Local Pack'),
    ], file: file);

    expect(missing, isEmpty);
    final known = await readKnownPacks(file: file);
    expect(known.keys, unorderedEquals(['a.silk', 'a.local']));
    expect(known['a.silk']!.link, 'a/maps/silksong');
    expect(known['a.local']!.link, isNull);
  });

  test('after a restore, recorded packs that are not on the phone are missing, by name', () async {
    await updateKnownPacks([
      pack('a.zelda', 'Zelda', link: 'a/maps/zelda'),
      pack('a.silk', 'Silksong', link: 'a/maps/silksong'),
    ], file: file);

    // A new phone: the backup brought back the list, but no packs.
    final missing = await updateKnownPacks([], file: file);
    expect(missing.map((k) => k.name), ['Silksong', 'Zelda']);
    expect(missing.first.link, 'a/maps/silksong');

    // Re-downloading one takes it off the missing list.
    final after = await updateKnownPacks([pack('a.silk', 'Silksong', link: 'a/maps/silksong')], file: file);
    expect(after.map((k) => k.id), ['a.zelda']);
  });

  test('a pack whose folder exists but failed to open is not missing', () async {
    await updateKnownPacks([pack('a.silk', 'Silksong', link: 'a/maps/silksong')], file: file);
    expect(await updateKnownPacks([], presentIds: {'a.silk'}, file: file), isEmpty);
  });

  test('a link entered later replaces the old one', () async {
    await updateKnownPacks([pack('a.local', 'Local Pack')], file: file);
    await updateKnownPacks([pack('a.local', 'Local Pack', link: 'a/maps/local')], file: file);
    expect((await readKnownPacks(file: file))['a.local']!.link, 'a/maps/local');
  });

  test('forgetting removes a pack; a missing or broken file reads as empty', () async {
    await updateKnownPacks([pack('a.silk', 'Silksong', link: 'a/maps/silksong')], file: file);
    await forgetKnownPack('a.silk', file: file);
    expect(await readKnownPacks(file: file), isEmpty);
    expect(await updateKnownPacks([], file: file), isEmpty);

    file.writeAsStringSync('not json');
    expect(await readKnownPacks(file: file), isEmpty);
    file.deleteSync();
    expect(await readKnownPacks(file: file), isEmpty);
  });
}
