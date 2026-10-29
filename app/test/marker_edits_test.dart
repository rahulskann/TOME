import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tome/pack/marker_edits.dart';
import 'package:tome/pack/pack.dart';

MapMarker _m(String id, {String? name, double x = 0}) => MapMarker(id: id, name: name ?? id, x: x, y: 0);

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('tome_edits_'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<MarkerEdits> load() => MarkerEdits.load('p', directory: dir);
  List<String> names(List<MapMarker> list) => [for (final m in list) m.name];

  test('records only the differences from the pack, and applies them in order', () async {
    final edits = await load();
    final pack = [_m('a'), _m('b'), _m('c')];
    edits.record('world', pack, [_m('a'), _m('b', name: 'B!'), _m('new')]);

    expect(edits.isEdited('b'), isTrue);
    expect(edits.isEdited('new'), isTrue);
    expect(edits.isEdited('a'), isFalse, reason: 'unchanged markers are not stored');
    expect(edits.isEdited('c'), isFalse, reason: 'deleted, not edited');
    expect(edits.deletedCount('world', pack), 1);
    expect(names(edits.apply('world', pack)), ['a', 'B!', 'new']);
    expect(edits.apply('cave', [_m('x')]).single.id, 'x', reason: 'other maps are untouched');
  });

  test('your version wins when the pack updates', () async {
    final edits = await load();
    edits.record('world', [_m('a'), _m('b')], [_m('a', name: 'Mine'), _m('b', name: 'Also mine')]);

    // The author renames a, removes b and adds c.
    final updated = [_m('a', name: 'Author'), _m('c')];
    expect(names(edits.apply('world', updated)), ['Mine', 'c', 'Also mine']);
  });

  test('editing a marker back to the pack version drops the edit', () async {
    final edits = await load();
    final pack = [_m('a')];
    edits.record('world', pack, [_m('a', name: 'X')]);
    edits.record('world', pack, [_m('a')]);
    expect(edits.isEmpty, isTrue);
  });

  test('reset and restore deleted', () async {
    final edits = await load();
    final pack = [_m('a'), _m('b'), _m('c')];
    edits.record('world', pack, [_m('a', name: 'X'), _m('c')]);

    edits.reset('a');
    expect(names(edits.apply('world', pack)), ['a', 'c']);
    edits.restoreDeleted('world');
    expect(names(edits.apply('world', pack)), ['a', 'b', 'c']);
    expect(edits.isEmpty, isTrue);
  });

  test('a marker added here and then deleted leaves nothing behind', () async {
    final edits = await load();
    final pack = [_m('a')];
    edits.record('world', pack, [_m('a'), _m('mine')]);
    edits.record('world', pack, [_m('a')]);
    expect(edits.isEmpty, isTrue);
  });

  test('persists, and a broken file is set aside', () async {
    final edits = await load();
    edits.record('world', [_m('a')], [_m('a', name: 'Kept', x: 5)]);
    await edits.flush();
    final again = await load();
    expect(again.apply('world', [_m('a')]).single.name, 'Kept');
    expect(again.apply('world', [_m('a')]).single.x, 5);

    File(p.join(dir.path, 'p.json')).writeAsStringSync('{broken');
    expect((await load()).isEmpty, isTrue);
    expect(dir.listSync().any((f) => f.path.contains('.corrupt-')), isTrue);
  });

  test('photos are kept with the edits, found before the pack\'s, and tidied when unused', () async {
    final photos = Directory(p.join(dir.path, 'photos'));
    final packDir = Directory(p.join(dir.path, 'pack'));
    File(p.join(packDir.path, 'photos', 'a.jpg'))
      ..createSync(recursive: true)
      ..writeAsStringSync('pack');
    final picture = File(p.join(dir.path, 'cam.jpg'))..writeAsStringSync('mine');
    final edits = await MarkerEdits.load('p', directory: dir, photos: photos);

    final mine = await edits.addPhoto('a', picture.path);
    expect(mine, matches(RegExp(r'^photos/a-\d+\.jpg$')));
    expect(edits.photoFile(packDir.path, mine)!.readAsStringSync(), 'mine');
    expect(edits.photoFile(packDir.path, 'photos/a.jpg')!.readAsStringSync(), 'pack');
    expect(edits.photoFile(packDir.path, 'photos/none.jpg'), isNull);
    expect(edits.photoFile(packDir.path, '../cam.jpg'), isNull, reason: 'unsafe paths are ignored');

    // A second pick that's never saved, and the saved one.
    final unsaved = await edits.addPhoto('b', picture.path);
    edits.record('world', [_m('a')], [_m('a').copyWith(photo: () => mine)]);
    await edits.flush();

    final again = await MarkerEdits.load('p', directory: dir, photos: photos);
    expect(again.photoFile(packDir.path, mine), isNotNull);
    expect(again.photoFile(packDir.path, unsaved), isNull, reason: 'never saved, so tidied away');

    // Unreadable edits never cost the photos.
    File(p.join(dir.path, 'p.json')).writeAsStringSync('{broken');
    await MarkerEdits.load('p', directory: dir, photos: photos);
    expect(File(p.joinAll([photos.path, ...mine.split('/')])).existsSync(), isTrue);
  });
}
