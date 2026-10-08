import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tome/map/image_coords.dart';
import 'package:tome/pack/category_icons.dart';
import 'package:tome/pack/pack.dart';

const _demo = 'assets/packs/tome.demo';

dynamic _readJson(String path) => jsonDecode(File(path).readAsStringSync());

void main() {
  group('demo pack', () {
    final manifest = PackManifest.fromJson(
        _readJson('$_demo/pack.json') as Map<String, dynamic>);
    final markers =
        MapMarker.listFromJson(_readJson('$_demo/markers/world.json') as List);

    test('parses manifest', () {
      expect(manifest.id, 'tome.demo');
      expect(manifest.maps.single.maxZoom, 3);
      expect(manifest.category('collectible')?.color, const Color(0xFFE8B04A));
      expect(manifest.category('nope'), isNull);
    });

    test('parses markers', () {
      final byId = {for (final m in markers) m.id: m};
      expect(byId['center_stone']!.trackable, isFalse);
      expect(byId['corner_chest_nw']!.trackable, isTrue);
      expect(byId.length, markers.length, reason: 'marker ids must be unique');
    });

    test('groups categories in declaration order', () {
      final groups = manifest.groupedCategories;
      expect([for (final (g, _) in groups) g.id], ['loot', 'places']);
      expect([for (final c in groups.first.$2) c.id], ['collectible', 'key']);
    });

    test('uses only built-in icon names', () {
      for (final c in manifest.categories) {
        expect(categoryIcons.keys, contains(c.icon), reason: c.id);
      }
    });

    test('bundled copy matches examples/demo-pack', () {
      for (final f in ['pack.json', 'markers/world.json']) {
        expect(File('$_demo/$f').readAsStringSync(),
            File('../examples/demo-pack/$f').readAsStringSync(),
            reason: 'copy examples/demo-pack/$f into $_demo/');
      }
    });

    test('every marker category is declared and inside the image', () {
      final map = manifest.maps.single;
      for (final m in markers) {
        expect(manifest.category(m.category), isNotNull, reason: m.id);
        expect(m.x, inInclusiveRange(0, map.imageWidth), reason: m.id);
        expect(m.y, inInclusiveRange(0, map.imageHeight), reason: m.id);
      }
    });
  });

  test('ungrouped categories fall into "Other"', () {
    final m = PackManifest.fromJson({
      'schemaVersion': 1,
      'id': 'x',
      'name': 'x',
      'version': '1',
      'maps': [],
      'categoryGroups': [
        {'id': 'a', 'name': 'A'},
        {'id': 'empty', 'name': 'Empty'},
      ],
      'categories': [
        {'id': 'c1', 'name': 'C1', 'group': 'a'},
        {'id': 'c2', 'name': 'C2'},
        {'id': 'c3', 'name': 'C3', 'group': 'typo'},
      ],
    });
    final groups = m.groupedCategories;
    expect([for (final (g, _) in groups) g.name], ['A', 'Other']);
    expect([for (final c in groups.last.$2) c.id], ['c2', 'c3']);
  });

  group('links', () {
    PackManifest manifest({String? wiki}) => PackManifest.fromJson({
          'schemaVersion': 1,
          'id': 'x',
          'name': 'x',
          'version': '1',
          'maps': [],
          'wiki': ?wiki,
          'categories': [
            {'id': 'bench', 'name': 'Benches', 'wiki': 'Bench (Silksong)'},
            {'id': 'plain', 'name': 'Plain'},
          ],
        });
    MapMarker marker({String? category, String? wiki, List<Map<String, String>>? links}) =>
        MapMarker.fromJson({
          'id': 'm',
          'name': 'M',
          'x': 0,
          'y': 0,
          'category': ?category,
          'wiki': ?wiki,
          'links': ?links,
        });
    const base = 'https://hollowknight.wiki/w/';

    test('marker page wins over category page', () {
      final links = manifest(wiki: base).linksFor(marker(category: 'bench', wiki: "Hunter's March"));
      expect(links.single.url, "${base}Hunter's_March");
    });

    test('falls back to the category page, encoding spaces and brackets', () {
      final links = manifest(wiki: base).linksFor(marker(category: 'bench'));
      expect(links.single.url, '${base}Bench_(Silksong)');
    });

    test('no wiki base means page names are ignored but URLs still work', () {
      final m = manifest();
      expect(m.linksFor(marker(category: 'bench')), isEmpty);
      expect(m.linksFor(marker(wiki: 'https://example.com/a')).single.url,
          'https://example.com/a');
    });

    test('explicit links follow the wiki link', () {
      final links = manifest(wiki: base).linksFor(marker(
          category: 'bench', links: [{'label': 'Video', 'url': 'https://v.example'}]));
      expect([for (final l in links) l.label], ['Wiki: Bench (Silksong)', 'Video']);
    });

    test('nothing to link', () {
      expect(manifest(wiki: base).linksFor(marker(category: 'plain')), isEmpty);
    });
  });

  test('markers survive a save round-trip, including unknown fields', () {
    final json = {
      'id': 'a',
      'name': 'A',
      'category': 'bench',
      'x': 10,
      'y': 20.5,
      'description': 'd',
      'wiki': 'W',
      'links': [{'label': 'L', 'url': 'https://u'}],
      'trackable': false,
      'source': {'name': 'Wiki: A', 'url': 'https://w/A', 'license': 'CC BY-SA 3.0'},
      'futureField': {'kept': true},
    };
    expect(MapMarker.fromJson(json).toJson(), json);
  });

  test('credit text and category notes', () {
    final m = PackManifest.fromJson({
      'schemaVersion': 1, 'id': 'x', 'name': 'x', 'version': '1', 'maps': [],
      'categories': [
        {
          'id': 'bench',
          'name': 'Benches',
          'description': 'Save points.',
          'source': {'name': 'Wiki: Bench', 'license': 'CC BY-SA 3.0'},
        },
      ],
    });
    final c = m.category('bench')!;
    expect(c.description, 'Save points.');
    expect(c.source!.credit, 'Adapted from Wiki: Bench · CC BY-SA 3.0');
    expect(const ContentSource(name: 'Notes').credit, 'Adapted from Notes');
  });

  test('copyWith can clear optional fields', () {
    final m = MapMarker.fromJson({'id': 'a', 'name': 'A', 'x': 1, 'y': 2, 'wiki': 'W'});
    expect(m.copyWith(wiki: () => null).wiki, isNull);
    expect(m.copyWith(name: 'B').wiki, 'W');
  });

  test('maps without a markers entry get a conventional file', () {
    final map = MapDefinition.fromJson({
      'id': 'cave',
      'name': 'Cave',
      'image': {'width': 1, 'height': 1},
      'maxZoom': 0,
      'tiles': {'archive': 'a.zip', 'path': '{z}/{x}/{y}.png'},
    });
    expect(map.markersFile, 'markers/cave.json');
  });

  test('rejects newer schema versions', () {
    expect(
      () => PackManifest.fromJson({'schemaVersion': 2}),
      throwsFormatException,
    );
  });

  test('parseHexColor', () {
    expect(parseHexColor('#7FB2F0'), const Color(0xFF7FB2F0));
    expect(parseHexColor('#807FB2F0'), const Color(0x807FB2F0));
    expect(parseHexColor('7FB2F0'), isNull);
    expect(parseHexColor('#xyz'), isNull);
  });

  group('ImageCoords', () {
    final coords = ImageCoords(maxZoom: 3, width: 2048, height: 1536);

    test('top-left is the origin and y points down', () {
      final origin = coords.toLatLng(0, 0);
      expect(origin.latitude, 0);
      expect(origin.longitude, 0);
      expect(coords.toLatLng(0, 100).latitude, lessThan(0));
    });

    test('round-trips pixels', () {
      final (x, y) = coords.toPixel(coords.toLatLng(1420.5, 842.25));
      expect(x, closeTo(1420.5, 1e-9));
      expect(y, closeTo(842.25, 1e-9));
    });

    test('native zoom puts one image pixel on one map pixel', () {
      // flutter_map's CrsSimple scale is 256 * 2^zoom.
      final p = coords.toLatLng(2048, 1536);
      expect(p.longitude * 256 * 8, closeTo(2048, 1e-9));
      expect(-p.latitude * 256 * 8, closeTo(1536, 1e-9));
    });

    test('a 16k map stays inside latitude limits', () {
      final big = ImageCoords(maxZoom: 6, width: 16384, height: 12288);
      expect(big.toLatLng(16384, 12288).latitude.abs(), lessThanOrEqualTo(90));
    });
  });

  test('custom icon images: only safe paths, resolved inside the pack', () {
    for (final ok in ['icons/a.png', 'icons/sub/b_c-1.webp', 'x.JPG']) {
      expect(safeIconPath(ok), isTrue, reason: ok);
    }
    for (final bad in ['../a.png', 'icons/../../a.png', '/a.png', 'https://x/a.png', 'a.svg', 'a b.png', '']) {
      expect(safeIconPath(bad), isFalse, reason: bad);
    }
    final c = MarkerCategory.fromJson({'id': 'k', 'name': 'K', 'iconImage': 'icons/k.png'}, root: 'packdir');
    expect(c.iconImage, 'icons/k.png');
    expect(c.iconFile, isNotNull);
    expect(p.split(c.iconFile!), ['packdir', 'icons', 'k.png']);
    expect(MarkerCategory.fromJson({'id': 'k', 'name': 'K', 'iconImage': 'icons/k.png'}).iconFile, isNull);
  });
}
