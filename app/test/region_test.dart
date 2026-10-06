import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:tome/pack/pack.dart';

Map<String, dynamic> _map(String id, int w, int h, int maxZoom, {List<Object>? regions}) => {
      'id': id,
      'name': id,
      'image': {'width': w, 'height': h},
      'maxZoom': maxZoom,
      'tiles': {'archive': '$id.zip', 'path': '{z}/{x}/{y}.png'},
      'regions': ?regions,
    };

void main() {
  // An L-shaped region on a 1000x800 overview, opening a 2000x1000 detail map.
  final manifest = PackManifest.fromJson({
    'schemaVersion': 1,
    'id': 'p',
    'name': 'P',
    'version': '1',
    'maps': [
      _map('world', 1000, 800, 2, regions: [
        {
          'id': 'cave',
          'name': 'Cave',
          'map': 'cave',
          'outline': [[100, 100], [300, 100], [300, 200], [200, 200], [200, 300], [100, 300]],
        },
        {
          'id': 'east',
          'name': 'East',
          'map': 'cave',
          'outline': [[600, 100], [700, 100], [700, 200], [600, 200]],
          'target': {'x': 1000, 'y': 0, 'width': 1000, 'height': 1000},
        },
      ]),
      _map('cave', 2000, 1000, 3),
    ],
  });
  final world = manifest.map('world')!;
  final cave = manifest.map('cave')!;
  final region = world.regions.first;

  test('contains respects concave outlines', () {
    expect(region.contains(150, 150), isTrue);
    expect(region.contains(150, 250), isTrue);
    expect(region.contains(250, 250), isFalse, reason: 'the notch of the L');
    expect(region.contains(50, 50), isFalse);
  });

  test('carries points into the child and back', () {
    // Region bounds 100..300 map onto the whole 2000x1000 child.
    expect(region.toChild(100, 100, cave), (0.0, 0.0));
    expect(region.toChild(300, 300, cave), (2000.0, 1000.0));
    final (cx, cy) = region.toChild(180, 240, cave);
    final (x, y) = region.fromChild(cx, cy, cave);
    expect(x, closeTo(180, 1e-9));
    expect(y, closeTo(240, 1e-9));
  });

  test('target limits the region to part of the child', () {
    final east = world.regions[1];
    expect(east.toChild(600, 100, cave), (1000.0, 0.0));
    expect(east.toChild(700, 200, cave), (2000.0, 1000.0));
  });

  test('zoom offset keeps the region the same size on screen', () {
    // On screen, width = pixels * 2^(zoom - maxZoom). Region is 200px wide on the
    // world; the child target is 2000px wide.
    const worldZoom = 3.0;
    final childZoom = worldZoom + region.zoomOffset(world, cave);
    final onWorld = 200 * math.pow(2, worldZoom - world.maxZoom);
    final onChild = 2000 * math.pow(2, childZoom - cave.maxZoom);
    expect(onChild, closeTo(onWorld, 1e-9));
  });

  test('finds the parent map of a region map', () {
    final (parent, r) = manifest.parentOf(cave)!;
    expect(parent.id, 'world');
    expect(r.id, 'cave');
    expect(manifest.parentOf(world), isNull);
  });

  test('point areas have a position but contain nothing', () {
    final area = MapRegion.fromJson({'id': 'a', 'name': 'A', 'x': 40, 'y': 60});
    expect(area.point, (40.0, 60.0));
    expect(area.contains(40, 60), isFalse);
    expect(region.point, region.bounds.center, reason: 'outline regions default to their centre');
  });

  test('a region needs a position, and an outline if it opens a map', () {
    expect(() => MapRegion.fromJson({'id': 'x', 'name': 'x'}), throwsFormatException);
    expect(() => MapRegion.fromJson({'id': 'x', 'name': 'x', 'x': 1, 'y': 1, 'map': 'cave'}),
        throwsFormatException);
  });

  test('markersIn counts the child map part a region stands for', () {
    final markers = {
      'world': [MapMarker(id: 'w', name: 'w', x: 150, y: 150)],
      'cave': [
        MapMarker(id: 'left', name: 'l', x: 500, y: 500),
        MapMarker(id: 'right', name: 'r', x: 1500, y: 500),
      ],
    };
    final east = world.regions[1];
    expect([for (final m in manifest.markersIn(world, east, markers)) m.id], ['right']);
    expect([for (final m in manifest.markersIn(world, region, markers)) m.id], ['left', 'right']);
    final area = MapRegion(id: 'a', name: 'A', outline: [(100, 100), (200, 100), (200, 200)]);
    expect([for (final m in manifest.markersIn(world, area, markers)) m.id], ['w']);
  });

  test('rejects outlines with fewer than three points', () {
    expect(
      () => MapRegion.fromJson({'id': 'x', 'name': 'x', 'map': 'm', 'outline': [[0, 0], [1, 1]]}),
      throwsFormatException,
    );
  });

  test('marker map link survives a save round-trip', () {
    final json = {'id': 'a', 'name': 'A', 'x': 1, 'y': 2, 'map': 'cave'};
    expect(MapMarker.fromJson(json).toJson(), json);
  });
}
