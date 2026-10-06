import 'package:flutter_test/flutter_test.dart';
import 'package:tome/pack/pack.dart';
import 'package:tome/search/marker_search.dart';

void main() {
  final manifest = PackManifest.fromJson({
    'schemaVersion': 1,
    'id': 'p',
    'name': 'P',
    'version': '1',
    'categories': [
      {'id': 'bench', 'name': 'Benches'},
      {'id': 'shard', 'name': 'Mask Shards'},
    ],
    'maps': [
      for (final (id, name) in [('world', 'Pharloom'), ('bb', 'Bone Bottom & Wormways')])
        {
          'id': id,
          'name': name,
          'image': {'width': 100, 'height': 100},
          'maxZoom': 0,
          'tiles': {'archive': 'a.zip', 'path': '{z}/{x}/{y}.png'},
          if (id == 'world')
            'regions': [
              {'id': 'grey', 'name': 'Greymoor', 'x': 10, 'y': 10, 'description': 'Rain and craws.'},
            ],
        },
    ],
  });
  MapMarker m(String id, String name, [String? category, String? notes]) => MapMarker(
      id: id, name: name, x: 0, y: 0, category: category, description: notes);
  final markers = {
    'world': [
      m('hm', "Hunter's March"),
      m('gm', 'Greymoor', null, 'Gloomy and wet. A bench sits by the caravan.'),
    ],
    'bb': [
      m('b1', 'Bench', 'bench'),
      m('b2', 'Ruined Chapel Bench', 'bench'),
      m('s1', 'Mask Shard behind wall', 'shard'),
    ],
  };
  List<String> ids(String q) => [for (final h in searchMarkers(manifest, markers, q)) h.marker?.id ?? 'region:${h.region!.id}'];

  test('exact name first, then name matches, then notes', () {
    expect(ids('bench'), ['b1', 'b2', 'gm']);
  });

  test('category names match', () {
    expect(ids('shards'), ['s1']);
  });

  test('every word must match somewhere', () {
    expect(ids('chapel bench'), ['b2']);
    expect(ids('chapel shard'), isEmpty);
  });

  test('map names match, so a region finds its markers', () {
    expect(ids('wormways'), ['b1', 'b2', 's1']);
  });

  test('apostrophes and case are ignored', () {
    expect(ids('HUNTERS'), ['hm']);
    expect(ids("hunter's march"), ['hm']);
  });

  test('hits carry their map', () {
    final hit = searchMarkers(manifest, markers, 'mask').single;
    expect(hit.map.id, 'bb');
  });

  test('regions are found by name and notes, ahead of equal markers', () {
    expect(ids('greymoor'), ['region:grey', 'gm']);
    expect(ids('craws'), ['region:grey']);
    expect(ids('area'), ['region:grey'], reason: 'point regions count as areas');
  });

  test('blank query finds nothing', () {
    expect(ids('  '), isEmpty);
  });
}
