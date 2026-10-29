import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tome/map/live_location.dart';
import 'package:tome/map/map_screen.dart';
import 'package:tome/map/marker_filter.dart';
import 'package:tome/map/marker_badge.dart';
import 'package:tome/map/marker_photo.dart';
import 'package:tome/pack/marker_edits.dart';
import 'package:tome/pack/pack.dart';
import 'package:tome/pack/pack_store.dart';
import 'package:tome/progress/progress_store.dart';

Map<String, dynamic> _map(String id, String name, int w, int h, int maxZoom,
        {List<Object>? regions, Map<String, Object>? geo}) =>
    {
      'id': id,
      'name': name,
      'image': {'width': w, 'height': h},
      'maxZoom': maxZoom,
      'tiles': {'archive': '$id.zip', 'path': '{z}/{x}/{y}.png'},
      'regions': ?regions,
      'geo': ?geo,
    };

/// A 1x1 PNG.
final _png = [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0xF0,
  0x1F, 0x00, 0x05, 0x00, 0x01, 0xFF, 0x89, 0x99, 0x3D, 0x1D, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45,
  0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
];

/// Positions on demand; asks once, like a first run.
class _FakeLocation implements LocationSource {
  final positions = StreamController<GeoFix>.broadcast();
  var access = LocationAccess.denied;
  var asked = 0;

  @override
  Future<LocationAccess> check() async => access;
  @override
  Future<LocationAccess> request() async {
    asked++;
    return access = LocationAccess.granted;
  }

  @override
  Stream<GeoFix> fixes() => positions.stream;
  @override
  Future<void> openAppSettings() async {}
  @override
  Future<void> openLocationSettings() async {}
}

void main() {
  late Directory progressDir;
  late ProgressStore progress;
  late MarkerEdits edits;
  setUp(() {
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    progressDir = Directory.systemTemp.createTempSync('tome_test_');
  });
  tearDown(() => progressDir.deleteSync(recursive: true));

  Future<void> pumpScreen(WidgetTester tester, PackManifest manifest,
      Map<String, List<MapMarker>> markers,
      {String packDir = '/nonexistent',
      Future<String?> Function(PhotoSource)? pickPhoto,
      LocationSource? location}) async {
    // Tiles point at a folder that doesn't exist; missing tiles render blank.
    final pack = InstalledPack(dir: packDir, manifest: manifest, markers: markers);
    final filter = await MarkerFilter.load(manifest.id);
    progress = await tester.runAsync(
        () => ProgressStore.load(manifest.id, directory: progressDir)) as ProgressStore;
    edits = await tester.runAsync(() => MarkerEdits.load(manifest.id,
        directory: Directory('${progressDir.path}/edits'),
        photos: Directory('${progressDir.path}/photos/${manifest.id}'))) as MarkerEdits;
    await tester.pumpWidget(MaterialApp(
        home: MapScreen(
      pack: pack,
      filter: filter,
      progress: progress,
      edits: edits,
      pickPhoto: pickPhoto ?? (_) async => null,
      locationSource: location ?? _FakeLocation(),
    )));
    await tester.pumpAndSettle();
  }

  // Saving and switching slots does real file work, which the test clock
  // doesn't advance: alternate real waits with frames until it's done.
  Future<void> settleIo(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
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

    // The confirmation goes away on its own (it has an Undo button, which
    // would otherwise keep it on screen until dismissed).
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('Found: Shard'), findsNothing);

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

  testWidgets('save slots: name both, the new one starts empty, its name shows in the title',
      (tester) async {
    final pack = PackManifest.fromJson({
      'schemaVersion': 1,
      'id': 's',
      'name': 'Silk',
      'version': '1',
      'maps': [_map('a', 'Map A', 500, 500, 1)],
    });
    await pumpScreen(tester, pack, {
      'a': [MapMarker.fromJson({'id': 'shard', 'name': 'Shard', 'x': 250, 'y': 250})],
    });
    progress.setFound('shard', true);
    await tester.pumpAndSettle();
    expect(find.text('Silk'), findsOneWidget, reason: 'one unnamed slot: no slot name shown');

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save slots'));
    await tester.pumpAndSettle();
    expect(find.text('Unnamed slot'), findsOneWidget);
    expect(find.text('1 of 1 found · playing now'), findsOneWidget);

    await tester.tap(find.text('Add slot'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(find.text('Give it a name'), findsNWidgets(2), reason: 'both slots need names');

    await tester.enterText(find.widgetWithText(TextField, 'Your current progress'), 'First run');
    await tester.enterText(find.widgetWithText(TextField, 'New slot'), 'first RUN');
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(find.text('Another slot already has this name'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'New slot'), 'Steel Soul');
    await tester.tap(find.text('Add'));
    await settleIo(tester);

    expect(find.text('Silk · Steel Soul'), findsOneWidget);
    expect(progress.isFound('shard'), isFalse, reason: 'the new slot starts empty');

    // Switch back from the title.
    await tester.tap(find.text('Silk · Steel Soul'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('First run'));
    await settleIo(tester);
    expect(find.text('Silk · First run'), findsOneWidget);
    expect(progress.isFound('shard'), isTrue);
    await tester.runAsync(progress.flush);
  });

  testWidgets('editing a marker stores an edit, not a pack change; reset brings the pack version back',
      (tester) async {
    final pack = PackManifest.fromJson({
      'schemaVersion': 1,
      'id': 'e',
      'name': 'E',
      'version': '1',
      'maps': [_map('a', 'Map A', 500, 500, 1)],
    });
    await pumpScreen(tester, pack, {
      'a': [MapMarker.fromJson({'id': 'shard', 'name': 'Shard', 'x': 250, 'y': 250})],
    });

    await tester.tap(find.byTooltip('Edit markers'));
    await tester.pumpAndSettle();
    await tapOnMap(tester, find.byType(CategoryBadge));
    expect(find.text('Reset to pack version'), findsNothing, reason: 'not edited yet');
    await tester.enterText(find.widgetWithText(TextFormField, 'Shard'), 'Big Shard');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(edits.isEdited('shard'), isTrue);
    final state = tester.state(find.byType(MapScreen)) as dynamic;
    expect((state.widget as MapScreen).pack.packMarkers['a']!.single.name, 'Shard',
        reason: 'the pack itself is unchanged');
    expect((state.widget as MapScreen).pack.markers['a']!.single.name, 'Big Shard');

    await tapOnMap(tester, find.byType(CategoryBadge));
    expect(find.text('You\'ve edited this marker on this phone.'), findsOneWidget);
    await tester.tap(find.text('Reset to pack version'));
    await tester.pumpAndSettle();
    expect(edits.isEdited('shard'), isFalse);
    expect((state.widget as MapScreen).pack.markers['a']!.single.name, 'Shard');
    await settleIo(tester);
  });

  testWidgets('a marker photo shows on its card; one added in edit mode is kept with the edits',
      (tester) async {
    final packDir = Directory('${progressDir.path}/pack')..createSync();
    File('${packDir.path}/photos/stone.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync(_png);
    final picked = File('${progressDir.path}/camera.png')..writeAsBytesSync(_png);
    final manifest = PackManifest.fromJson({
      'schemaVersion': 1,
      'id': 'p',
      'name': 'P',
      'version': '1',
      'maps': [_map('world', 'World', 1000, 800, 2)],
    });
    await pumpScreen(tester, manifest, {
      'world': [
        MapMarker.fromJson({'id': 'stone', 'name': 'Stone', 'x': 500, 'y': 400, 'photo': 'photos/stone.png'}),
        MapMarker.fromJson({'id': 'well', 'name': 'Well', 'x': 900, 'y': 700}),
      ],
    }, packDir: packDir.path, pickPhoto: (_) async => picked.path);

    await tapOnMap(tester, find.byType(CategoryBadge).first);
    expect(find.byType(MarkerPhoto), findsOneWidget);
    await tester.tap(find.byType(MarkerPhoto));
    await tester.pumpAndSettle();
    expect(find.byType(PhotoViewer), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.text('Stone').last)).pop();
    await tester.pumpAndSettle();

    // Add one to the other marker in edit mode.
    await tester.tap(find.byTooltip('Edit markers'));
    await tester.pumpAndSettle();
    await tapOnMap(tester, find.byType(CategoryBadge).last);
    await tester.tap(find.text('Choose photo'));
    await settleIo(tester);
    expect(find.text('Remove photo'), findsOneWidget);
    await tester.tap(find.text('Save'));
    await settleIo(tester);

    final photo = edits.apply('world', [MapMarker.fromJson({'id': 'well', 'name': 'Well', 'x': 900, 'y': 700})])
        .single
        .photo;
    expect(photo, startsWith('photos/well-'));
    final file = edits.photoFile(packDir.path, photo)!;
    expect(file.path, startsWith(edits.photosDir.path), reason: 'kept with the edits, not in the pack');
    expect(file.readAsBytesSync(), _png);
  });

  testWidgets('you are here: only on pinned maps; explains first, then shows the dot or the way',
      (tester) async {
    final pinned = PackManifest.fromJson({
      'schemaVersion': 1,
      'id': 'city',
      'name': 'City',
      'version': '1',
      'maps': [
        _map('park', 'Park', 1000, 800, 2, geo: {
          'points': [
            [0, 0, 45.53, -122.70],
            [1000, 800, 45.52, -122.68],
          ],
        }),
      ],
    });
    final location = _FakeLocation();
    await pumpScreen(tester, pinned, {'park': const []}, location: location);

    await tester.tap(find.byTooltip('Show where you are'));
    await tester.pumpAndSettle();
    expect(find.text('Show where you are?'), findsOneWidget);
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(location.asked, 1);
    expect(find.byTooltip('Stop showing where you are'), findsOneWidget);

    // In the middle of the park: a dot, no arrow.
    final (lat, lng) = pinned.maps.single.geo!.toLatLng(500, 400);
    location.positions.add((lat: lat, lng: lng, accuracy: 10));
    await tester.pumpAndSettle();
    expect(find.byType(YouAreHereLayer), findsOneWidget);
    expect(find.textContaining('about'), findsNothing);

    // Far to the east: off the map, so an arrow and the distance.
    location.positions.add((lat: 45.525, lng: -122.50, accuracy: 10));
    await tester.pumpAndSettle();
    expect(find.textContaining('Off the map · about'), findsOneWidget);
    expect(find.textContaining(' E'), findsOneWidget);

    // Turning it off removes it, and asks nothing next time.
    await tester.tap(find.byTooltip('Stop showing where you are'));
    await tester.pumpAndSettle();
    expect(find.byType(YouAreHereLayer), findsNothing);
    await tester.tap(find.byTooltip('Show where you are'));
    await tester.pumpAndSettle();
    expect(find.text('Show where you are?'), findsNothing);
    expect(location.asked, 1);

    // Maps that aren't pinned have no button.
    await pumpScreen(tester, regionPack, {'world': const [], 'cave': const []});
    expect(find.byTooltip('Show where you are'), findsNothing);
  });
}
