import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../pack/pack_store.dart';
import '../progress/progress_store.dart';
import '../theme.dart';

// The home-screen widget (android/.../TomeWidgetProvider.kt) can't run Dart, so
// the app writes what it shows to <app support>/widget-data.json and asks
// Android to redraw. Tapping a widget opens TOME on that pack.

const _channel = MethodChannel('tome/widget');

/// What the widgets show, as written to widget-data.json.
String widgetData(List<InstalledPack> packs, Map<String, ProgressStore> progress, AppTheme theme) {
  return jsonEncode({
    'theme': theme.name,
    'packs': [
      for (final pack in packs)
        if (progress[pack.manifest.id] case final store?) _packData(pack, store),
    ],
  });
}

Map<String, Object?> _packData(InstalledPack pack, ProgressStore store) {
  final t = store.tally(pack.markers.values.expand((l) => l));
  return {
    'id': pack.manifest.id,
    'name': pack.manifest.name,
    'slot': store.slots.length > 1 ? store.activeSlot.name : null,
    'found': t.found,
    'total': t.total,
  };
}

/// Keeps the widgets up to date with the packs, their progress and the theme.
class HomeWidgetSync {
  HomeWidgetSync({this.file, this.onOpenPack}) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'openPack' && call.arguments is String) onOpenPack?.call(call.arguments as String);
    });
  }

  /// Where to write widget-data.json (tests); defaults to the app support folder.
  final File? file;

  /// A widget was tapped while TOME was running.
  final void Function(String packId)? onOpenPack;

  List<InstalledPack> _packs = const [];
  Map<String, ProgressStore> _progress = const {};
  AppTheme _theme = AppTheme.dark;
  final Set<ProgressStore> _watching = {};
  Timer? _debounce;

  /// The pack a widget opened TOME on, once (null if TOME was opened another way).
  static Future<String?> takeLaunchPack() async {
    try {
      return await _channel.invokeMethod<String>('takeLaunchPack');
    } on MissingPluginException {
      return null; // tests, or a platform without widgets
    }
  }

  void update({List<InstalledPack>? packs, Map<String, ProgressStore>? progress, AppTheme? theme}) {
    _packs = packs ?? _packs;
    _progress = progress ?? _progress;
    _theme = theme ?? _theme;
    for (final store in _progress.values) {
      if (_watching.add(store)) store.addListener(_schedule);
    }
    _schedule();
  }

  // Ticks come in bursts; write once they settle.
  void _schedule() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _publish);
  }

  Future<void> _publish() async {
    try {
      final out = file ?? File(p.join((await getApplicationSupportDirectory()).path, 'widget-data.json'));
      final tmp = File('${out.path}.tmp');
      await tmp.writeAsString(widgetData(_packs, _progress, _theme));
      await tmp.rename(out.path);
      await _channel.invokeMethod<void>('refresh');
    } on MissingPluginException {
      // tests, or a platform without widgets
    } catch (e) {
      debugPrint('Could not update the home-screen widget: $e');
    }
  }

  void dispose() {
    _debounce?.cancel();
    for (final store in _watching) {
      store.removeListener(_schedule);
    }
    _channel.setMethodCallHandler(null);
  }
}
