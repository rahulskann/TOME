import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tome/map/map_screen.dart';
import 'package:tome/map/marker_filter.dart';
import 'package:tome/map/marker_badge.dart';
import 'package:tome/pack/pack.dart';
import 'package:tome/pack/pack_store.dart';
import 'package:tome/progress/progress_store.dart';

Map<String, dynamic> _map(String id, String name, int w, int h, int maxZoom,
        {List<Object>? regions}) =>
    {
      'id': id,
      'name': name,
      'image': {'width': w, 'height': h},
      'maxZoom': maxZoom,
      'tiles': {'archive': '$id.zip', 'path': '{z}/{x}/{y}.png'},
      'regions': ?regions,
    };

void main() {
  late Directory progressDir;
  late ProgressStore progress;
  setUp(() {
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    progressDir = Directory.systemTemp.createTempSync('tome_test_');
  });
  tearDown(() => progressDir.deleteSync(recursive: true));

  Future<void> pumpScreen(WidgetTester tester, PackManifest manifest,
      Map<String, List<MapMarker>> markers) async {
    // Tiles point at a folder that doesn't exist; missing tiles render blank.
    final pack = InstalledPack(dir: '/nonexistent', manifest: manifest, markers: markers);
    final filter = await MarkerFilter.load(manifest.id);
    progress = await tester.runAsync(
        () => ProgressStore.load(manifest.id, directory: progressDir)) as ProgressStore;
    await tester.pumpWidget(
        MaterialApp(home: MapScreen(pack: pack, filter: filter, progress: progress)));
    await tester.pumpAndSettle();
  }

  // The map listens for double-tap zoom, so single taps resolve only after
  // the double-tap window.
  Future<void> tapOnMap(WidgetTester tester, Finder finder) async {
    await tester.tap(finder);
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
  }

  final regionPack = PackManifest.fromJson({
    'schemaVersion': 1,
    'id': 'p',
    'name': 'P',
    'version': '1',
    'maps': [
      _map('world', 'World', 1000, 800, 2, regions: [
        {
          'id': 'cave',
          'name': 'Cave',
          'map': 'cave',
          'outline': [[100, 100], [300, 100], [300, 300], [100, 300]],
        },
      ]),
      _map('cave', 'Cave Detail', 2000, 1000, 3),
    ],
  });

  testWidgets('enter a region via its marker, then return with the parent button',
      (tester) async {
    // Regression: reusing one MapController across maps tripped flutter_map's
    // camera-constraint assertion when the next map opened.
    await pumpScreen(tester, regionPack, {
      'world': [
        MapMarker.fromJson({'id': 'cave_label', 'name': 'Cave', 'x': 200, 'y': 200, 'map': 'cave'}),
      ],
      'cave': const [],
    });
    expect(find.text('World'), findsOneWidget);

    await tapOnMap(tester, find.byType(CategoryBadge));
    expect(find.text('Cave Detail'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Parent button is labelled with the parent map's name.
    await tester.tap(find.widgetWithText(FilledButton, 'World'));
    await tester.pumpAndSettle();
    expect(find.text('World'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // And back in again, several times, to catch controller reuse.
    for (var i = 0; i < 3; i++) {
      await tapOnMap(tester, find.byType(CategoryBadge));
      expect(find.text('Cave Detail'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'World'));
      await tester.pumpAndSettle();
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('map menu only appears for maps no region leads to', (tester) async {
    await pumpScreen(tester, regionPack, {'world': const [], 'cave': const []});
    expect(find.byTooltip('Switch map'), findsNothing);

    final unlinked = PackManifest.fromJson({
      'schemaVersion': 1,
      'id': 'q',
      'name': 'Q',
      'version': '1',
      'maps': [_map('a', 'Map A', 500, 500, 1), _map('b', 'Map B', 500, 500, 1)],
    });
    await pumpScreen(tester, unlinked, {'a': const [], 'b': const []});
    expect(find.byTooltip('Switch map'), findsOneWidget);
  });

  testWidgets('long-press marks a marker found; hide found hides it', (tester) async {
    final pack = PackManifest.fromJson({
      'schemaVersion': 1,
      'id': 'r',
      'name': 'R',
      'version': '1',
      'maps': [_map('a', 'Map A', 500, 500, 1)],
    });
    await pumpScreen(tester, pack, {
      'a': [
        MapMarker.fromJson({'id': 'shard', 'name': 'Shard', 'x': 250, 'y': 250}),
      ],
    });

    await tester.longPress(find.byType(CategoryBadge));
    await tester.pumpAndSettle();
    expect(progress.isFound('shard'), isTrue);
    expect(find.text('Found: Shard'), findsOneWidget);
    expect(find.text('1/1'), findsOneWidget);

    await tester.tap(find.text('1/1')); // the found counter toggles hide-found
    await tester.pumpAndSettle();
    expect(find.byType(CategoryBadge), findsNothing);
  });

  testWidgets('search finds a marker on another map and jumps there', (tester) async {
    await pumpScreen(tester, regionPack, {
      'world': const [],
      'cave': [
        MapMarker.fromJson({'id': 'shard', 'name': 'Hidden Shard', 'x': 1500, 'y': 500}),
      ],
    });
    expect(find.text('World'), findsOneWidget);

    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'hidden');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hidden Shard'));
    await tester.pumpAndSettle();

    expect(find.text('Cave Detail'), findsOneWidget);
    expect(find.byType(CategoryBadge), findsOneWidget);
    expect(tester.takeException(), isNull);
    // Let the highlight timer run out.
    await tester.pump(const Duration(seconds: 7));
  });

  testWidgets('info sheet lists regions; Open map and Go there work', (tester) async {
    final pack = PackManifest.fromJson({
      'schemaVersion': 1,
      'id': 'i',
      'name': 'I',
      'version': '1',
      'maps': [
        {
          ..._map('world', 'World', 1000, 800, 2, regions: [
            {
              'id': 'cave',
              'name': 'Cave',
              'map': 'cave',
              'outline': [[100, 100], [300, 100], [300, 300], [100, 300]],
            },
            {'id': 'lake', 'name': 'Lake', 'x': 700, 'y': 600, 'description': 'Still water.'},
          ]),
          'description': 'The whole world.',
        },
        _map('cave', 'Cave Detail', 2000, 1000, 3),
      ],
    });
    await pumpScreen(tester, pack, {
      'world': const [],
      'cave': [MapMarker.fromJson({'id': 's', 'name': 'S', 'x': 10, 'y': 10})],
    });

    await tester.tap(find.byTooltip('About this map'));
    await tester.pumpAndSettle();
    expect(find.text('The whole world.'), findsOneWidget);
    expect(find.text('0 / 1 found'), findsOneWidget, reason: "the cave's marker counts for Cave");

    await tester.tap(find.text('Lake'));
    await tester.pumpAndSettle();
    expect(find.text('Still water.'), findsOneWidget);
    await tester.tap(find.text('Go there'));
    // The ring pulses until its timer ends, so check before things "settle".
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('World'), findsOneWidget);
    expect(find.byIcon(Icons.place), findsOneWidget, reason: 'the spot is ringed');
    await tester.pump(const Duration(seconds: 7));
    expect(find.byIcon(Icons.place), findsNothing, reason: 'and the ring goes away');

    await tester.tap(find.byTooltip('About this map'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cave'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open map'));
    await tester.pumpAndSettle();
    expect(find.text('Cave Detail'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 7));
  });
}
