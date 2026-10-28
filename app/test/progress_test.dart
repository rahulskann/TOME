import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tome/pack/pack.dart';
import 'package:tome/progress/progress_store.dart';

MapMarker _m(String id, {bool trackable = true}) => MapMarker(
    id: id, name: id, x: 0, y: 0, trackable: trackable);

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('tome_progress_'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<ProgressStore> load(String pack) => ProgressStore.load(pack, directory: dir);
  Map<String, dynamic> readJson(String path) =>
      jsonDecode(File(p.join(dir.path, path)).readAsStringSync()) as Map<String, dynamic>;

  test('found markers persist across loads', () async {
    final a = await load('pack.one');
    expect(a.isFound('x'), isFalse);
    a.setFound('x', true);
    a.toggle('y');
    a.toggle('y'); // back to not found
    await a.flush();

    final b = await load('pack.one');
    expect(b.isFound('x'), isTrue);
    expect(b.isFound('y'), isFalse);
    expect(b.foundCount, 1);
  });

  test('un-ticking is kept with its time, not forgotten', () async {
    final store = await load('p');
    store.setFound('a', true);
    store.setFound('a', false);
    await store.flush();
    final a = (readJson('p/main.json')['markers'] as Map<String, dynamic>)['a'] as Map<String, dynamic>;
    expect(a['done'], isFalse);
    expect(DateTime.tryParse(a['updatedAt'] as String), isNotNull);
  });

  test('packs keep separate progress', () async {
    final a = await load('a');
    a.setFound('shared_id', true);
    await a.flush();
    final b = await load('b');
    expect(b.isFound('shared_id'), isFalse);
  });

  test('notifies only on real changes', () async {
    final store = await load('p');
    var notified = 0;
    store.addListener(() => notified++);
    store.setFound('x', true);
    store.setFound('x', true);
    store.setFound('y', false);
    expect(notified, 1);
  });

  test('tally counts only trackable markers', () async {
    final store = await load('p');
    store.setFound('a', true);
    store.setFound('bench', true); // found flag on a non-trackable marker is ignored
    final t = store.tally([_m('a'), _m('b'), _m('bench', trackable: false)]);
    expect(t, (found: 1, total: 2));
  });

  test('a corrupt slot file is set aside, not overwritten', () async {
    final slot = File(p.join(dir.path, 'p', 'main.json'))..createSync(recursive: true);
    slot.writeAsStringSync('{not json');
    final store = await load('p');
    expect(store.foundCount, 0);
    expect(Directory(p.join(dir.path, 'p')).listSync().any((f) => f.path.contains('.corrupt-')), isTrue);
  });

  group('version 1 files', () {
    test('become the first, unnamed slot', () async {
      File(p.join(dir.path, 'p.json')).writeAsStringSync(jsonEncode({
        'format': 'tome-progress',
        'version': 1,
        'pack': 'p',
        'found': {'a': '2026-10-05T12:00:00.000Z'},
      }));
      final store = await load('p');
      expect(store.isFound('a'), isTrue);
      expect(store.slots, [const SaveSlot(id: 'main')]);
      expect(File(p.join(dir.path, 'p.json')).existsSync(), isFalse, reason: 'converted once');
      expect(readJson('p/main.json')['version'], 2);

      expect((await load('p')).isFound('a'), isTrue);
    });

    test('an unreadable one is set aside', () async {
      File(p.join(dir.path, 'p.json')).writeAsStringSync('{not json');
      final store = await load('p');
      expect(store.foundCount, 0);
      expect(dir.listSync().any((f) => f.path.contains('p.json.corrupt-')), isTrue);
    });
  });

  group('save slots', () {
    test('start with one unnamed slot; the first extra slot needs both named', () async {
      final store = await load('p');
      expect(store.slots.single.name, isNull);
      expect(() => store.addSlot('Steel Soul'), throwsArgumentError);
    });

    test('a new slot starts empty and becomes active; switching back restores', () async {
      final store = await load('p');
      store.setFound('a', true);
      final markers = [_m('a'), _m('b')];
      var notified = 0;
      store.addListener(() => notified++);

      final steel = await store.addSlot('Steel Soul', currentName: 'First run');
      expect(store.activeSlot, steel);
      expect(store.isFound('a'), isFalse);
      expect(store.slots.map((s) => s.name), ['First run', 'Steel Soul']);
      expect(await store.tallyIn('main', markers), (found: 1, total: 2));
      expect(notified, greaterThan(0));

      store.setFound('b', true);
      await store.switchTo('main');
      expect(store.isFound('a'), isTrue);
      expect(store.isFound('b'), isFalse);
      expect(await store.tallyIn(steel.id, markers), (found: 1, total: 2));
    });

    test('names, the active slot and each slot\'s progress persist', () async {
      final store = await load('p');
      store.setFound('a', true);
      final second = await store.addSlot('Two', currentName: 'One');
      store.setFound('b', true);
      store.renameSlot(second.id, 'Second');
      await store.flush();

      final again = await load('p');
      expect(again.slots.map((s) => s.name), ['One', 'Second']);
      expect(again.activeSlot.id, second.id);
      expect(again.isFound('b'), isTrue);
      expect(again.isFound('a'), isFalse);
    });

    test('deleting the active slot switches to the first; the last one stays', () async {
      final store = await load('p');
      store.setFound('a', true);
      final second = await store.addSlot('Two', currentName: 'One');
      await store.deleteSlot(second.id);
      expect(store.slots.map((s) => s.name), ['One'], reason: 'back to one slot, which keeps its name');
      expect(store.isFound('a'), isTrue);
      await store.flush();
      expect(File(p.join(dir.path, 'p', '${second.id}.json')).existsSync(), isFalse);
      expect(() => store.deleteSlot('main'), throwsStateError);
    });

    test('a lost slots.json is rebuilt from the slot files', () async {
      final store = await load('p');
      await store.addSlot('Two', currentName: 'One');
      store.setFound('x', true);
      await store.flush();
      File(p.join(dir.path, 'p', 'slots.json')).deleteSync();

      final again = await load('p');
      expect(again.slots.map((s) => s.name), unorderedEquals(['One', 'Two']));
    });
  });

  group('file format', () {
    test('round-trips, sorted for clean diffs', () {
      final when = DateTime.utc(2026, 10, 5, 12);
      const slot = SaveSlot(id: 'main', name: 'Run');
      final text = encodeProgress('p', slot, {'b': (done: false, updatedAt: when), 'a': (done: true, updatedAt: when)});
      expect(text.indexOf('"a"'), lessThan(text.indexOf('"b"')));
      final parsed = parseProgress(text, 'p');
      expect(parsed.markers, {'a': (done: true, updatedAt: when), 'b': (done: false, updatedAt: when)});
      expect(parsed.slotName, 'Run');
    });

    test('rejects files for another pack or a newer version', () {
      final text = encodeProgress('p', const SaveSlot(id: 'main'), {});
      expect(() => parseProgress(text, 'other'), throwsFormatException);
      expect(
        () => parseProgress('{"format":"tome-progress","version":3,"pack":"p","markers":{}}', 'p'),
        throwsFormatException,
      );
      expect(() => parseProgress('[]', 'p'), throwsFormatException);
    });
  });
}
