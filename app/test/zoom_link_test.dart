import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:tome/pack/pack.dart';

Map<String, dynamic> _map(String id, int w, int h, int maxZoom, {Map<String, dynamic>? zoomsInto}) => {
      'id': id,
      'name': id,
      'image': {'width': w, 'height': h},
      'maxZoom': maxZoom,
      'tiles': {'archive': '$id.zip', 'path': '{z}/{x}/{y}.png'},
      'zoomsInto': ?zoomsInto,
    };

void main() {
  // Overview 1000x800; detail is the same world at 4x, but with the right half
  // shifted down 100 detail px (a stylised overview doesn't match exactly).
  final points = [
    [100, 100, 400, 400],
    [800, 100, 3200, 500],
    [100, 700, 400, 2800],
    [800, 700, 3200, 2900],
  ];
  final manifest = PackManifest.fromJson({
    'schemaVersion': 1,
    'id': 'p',
    'name': 'P',
    'version': '1',
    'maps': [
      _map('overview', 1000, 800, 2, zoomsInto: {'map': 'detail', 'points': points}),
      _map('detail', 4000, 3200, 4),
    ],
  });
  final overview = manifest.map('overview')!;
  final detail = manifest.map('detail')!;
  final link = overview.zoomsInto!;

  test('matching points map exactly, both ways', () {
    for (final [sx, sy, dx, dy] in points) {
      expect(link.toDetail(sx.toDouble(), sy.toDouble()), (dx.toDouble(), dy.toDouble()));
      expect(link.fromDetail(dx.toDouble(), dy.toDouble()), (sx.toDouble(), sy.toDouble()));
    }
  });

  test('scale comes from the spread of the points', () {
    expect(link.scale, closeTo(4, 0.05));
  });

  test('points near a match follow its local offset', () {
    final (x, y) = link.toDetail(810, 110);
    expect(x, closeTo(3240, 2));
    expect(y, closeTo(540, 2), reason: 'right half keeps its +100 shift');
  });

  test('going in and back out lands close to where you started', () {
    for (final (x, y) in [(300.0, 250.0), (650.0, 600.0), (120.0, 690.0)]) {
      final (dx, dy) = link.toDetail(x, y);
      final (bx, by) = link.fromDetail(dx, dy);
      expect(math.sqrt((bx - x) * (bx - x) + (by - y) * (by - y)), lessThan(8));
    }
  });

  test('zoom offset keeps things the same size on screen', () {
    // Size on screen = pixels * 2^(zoom - maxZoom); detail has 4x the pixels.
    const zoom = 2.5;
    final detailZoom = zoom + link.zoomOffset(overview, detail);
    expect(100 * math.pow(2, zoom - overview.maxZoom),
        closeTo(100 * link.scale * math.pow(2, detailZoom - detail.maxZoom), 1e-9));
  });

  test('finds the overview that zooms into a map', () {
    final (parent, l) = manifest.zoomParentOf(detail)!;
    expect(parent.id, 'overview');
    expect(l, same(link));
    expect(manifest.zoomParentOf(overview), isNull);
  });

  test('needs at least two points', () {
    expect(() => ZoomLink.fromJson({'map': 'x', 'points': [[0, 0, 0, 0]]}), throwsFormatException);
  });
}
