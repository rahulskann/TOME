import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Which marker categories are hidden for one pack, and whether found markers
/// are hidden, remembered between launches. Markers without a category are
/// always shown.
class MarkerFilter extends ChangeNotifier {
  MarkerFilter._(this._packId, this._prefs, this._hidden, this._hideFound);

  static Future<MarkerFilter> load(String packId) async {
    final prefs = SharedPreferencesAsync();
    final hidden = await prefs.getStringList(_hiddenKey(packId)) ?? const [];
    final hideFound = await prefs.getBool(_hideFoundKey(packId)) ?? false;
    return MarkerFilter._(packId, prefs, hidden.toSet(), hideFound);
  }

  static String _hiddenKey(String packId) => 'filter.hidden.$packId';
  static String _hideFoundKey(String packId) => 'filter.hideFound.$packId';

  final String _packId;
  final SharedPreferencesAsync _prefs;
  final Set<String> _hidden;
  bool _hideFound;

  bool isVisible(String? categoryId) =>
      categoryId == null || !_hidden.contains(categoryId);

  bool get hideFound => _hideFound;

  set hideFound(bool value) {
    if (value == _hideFound) return;
    _hideFound = value;
    notifyListeners();
    _prefs.setBool(_hideFoundKey(_packId), value);
  }

  void toggle(String categoryId) => setVisible([categoryId], !isVisible(categoryId));

  void setVisible(Iterable<String> categoryIds, bool visible) {
    final changed = visible
        ? categoryIds.map(_hidden.remove).fold(false, (a, b) => a || b)
        : categoryIds.map(_hidden.add).fold(false, (a, b) => a || b);
    if (!changed) return;
    notifyListeners();
    _prefs.setStringList(_hiddenKey(_packId), _hidden.toList());
  }
}
