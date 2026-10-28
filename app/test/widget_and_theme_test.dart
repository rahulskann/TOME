import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:tome/pack/pack.dart';
import 'package:tome/pack/pack_store.dart';
import 'package:tome/progress/progress_store.dart';
import 'package:tome/theme.dart';
import 'package:tome/widget/home_widget.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('tome_widget_'));
  tearDown(() => dir.deleteSync(recursive: true));

  InstalledPack pack(String id, String name, List<MapMarker> markers) => InstalledPack(
        dir: dir.path,
        manifest: PackManifest.fromJson(
            {'schemaVersion': 1, 'id': id, 'name': name, 'version': '1', 'maps': <Object>[]}),
        markers: {'m': markers},
      );
  MapMarker marker(String id, {bool trackable = true}) =>
      MapMarker(id: id, name: id, x: 0, y: 0, trackable: trackable);

  test('widget data: each pack\'s counts, its slot once there are two, and the theme', () async {
    final demo = pack('demo', 'Demo', [marker('a'), marker('b'), marker('bench', trackable: false)]);
    final silk = pack('silk', 'Silk', [marker('x')]);
    final demoProgress = await ProgressStore.load('demo', directory: dir)..setFound('a', true);
    final silkProgress = await ProgressStore.load('silk', directory: dir);
    await silkProgress.addSlot('Steel Soul', currentName: 'First run');

    final json = jsonDecode(widgetData([demo, silk], {'demo': demoProgress, 'silk': silkProgress}, AppTheme.atlas))
        as Map<String, dynamic>;
    expect(json['theme'], 'atlas');
    expect(json['packs'], [
      {'id': 'demo', 'name': 'Demo', 'slot': null, 'found': 1, 'total': 2},
      {'id': 'silk', 'name': 'Silk', 'slot': 'Steel Soul', 'found': 0, 'total': 1},
    ]);
    await demoProgress.flush();
    await silkProgress.flush();
  });

  group('theme', () {
    setUp(() => SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty());

    test('defaults to Dark and remembers the choice', () async {
      final first = await ThemeSetting.load();
      expect(first.value, AppTheme.dark);
      first.choose(AppTheme.atlas);
      await Future<void>.delayed(Duration.zero);
      expect((await ThemeSetting.load()).value, AppTheme.atlas);
    });

    test('Atlas is a light parchment theme with wax-red accents', () {
      final scheme = AppTheme.atlas.data.colorScheme;
      expect(scheme.brightness, Brightness.light);
      expect(scheme.primary, const Color(0xFF8E2A1E));
      expect(scheme.surface, const Color(0xFFF3E6CC));
      expect(AppTheme.dark.data.colorScheme.brightness, Brightness.dark);
    });
  });
}
