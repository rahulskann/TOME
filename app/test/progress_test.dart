import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tome/pack/pack.dart';
import 'package:tome/progress/progress_store.dart';

MapMarker _m(String id, {bool trackable = true}) => MapMarker(
    id: id, name: id, x: 0, y: 0, trackable: trackable);

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('tome_progress_'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('found markers persist across loads', () async {
    final a = await ProgressStore.load('pack.one', directory: dir);
    expect(a.isFound('x'), isFalse);
    a.setFound('x', true);
    a.toggle('y');
    a.toggle('y'); // back to not found
    await a.flush();

    final b = await ProgressStore.load('pack.one', directory: dir);
    expect(b.isFound('x'), isTrue);
    expect(b.isFound('y'), isFalse);
    expect(b.foundCount, 1);
  });

  test('packs keep separate progress', () async {
    final a = await ProgressStore.load('a', directory: dir);
    a.setFound('shared_id', true);
    await a.flush();
    final b = await ProgressStore.load('b', directory: dir);
    expect(b.isFound('shared_id'), isFalse);
  });

  test('notifies only on real changes', () async {
    final store = await ProgressStore.load('p', directory: dir);
    var notified = 0;
    store.addListener(() => notified++);
    store.setFound('x', true);
    store.setFound('x', true);
    store.setFound('y', false);
    expect(notified, 1);
  });

  test('tally counts only trackable markers', () async {
    final store = await ProgressStore.load('p', directory: dir);
    store.setFound('a', true);
    store.setFound('bench', true); // found flag on a non-trackable marker is ignored
    final t = store.tally([_m('a'), _m('b'), _m('bench', trackable: false)]);
    expect(t, (found: 1, total: 2));
  });

  test('a corrupt file is set aside, not overwritten', () async {
    File('${dir.path}/p.json').writeAsStringSync('{not json');
    final store = await ProgressStore.load('p', directory: dir);
    expect(store.foundCount, 0);
    expect(dir.listSync().map((f) => f.path).any((p) => p.contains('.corrupt-')), isTrue);
  });

  group('file format', () {
    test('round-trips', () {
      final when = DateTime.utc(2026, 10, 5, 12);
      final text = encodeProgress('p', {'b': when, 'a': when});
      expect(text.indexOf('"a"'), lessThan(text.indexOf('"b"')), reason: 'sorted for clean diffs');
      expect(parseProgress(text, 'p'), {'a': when, 'b': when});
    });

    test('rejects files for another pack or a newer version', () {
      final text = encodeProgress('p', {});
      expect(() => parseProgress(text, 'other'), throwsFormatException);
      expect(
        () => parseProgress('{"format":"tome-progress","version":2,"pack":"p","found":{}}', 'p'),
        throwsFormatException,
      );
      expect(() => parseProgress('[]', 'p'), throwsFormatException);
    });
  });
}
