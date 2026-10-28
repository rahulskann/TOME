import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The app's looks. Dark is the default; Atlas is parchment, leather brown,
/// wax red and gold, to match the icon.
enum AppTheme {
  dark('Dark'),
  atlas('Atlas');

  const AppTheme(this.label);

  final String label;

  ThemeData get data => switch (this) {
        AppTheme.dark => _dark,
        AppTheme.atlas => _atlas,
      };
}

final _dark = ThemeData(
  colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF7FB2F0), brightness: Brightness.dark),
);

final _atlas = ThemeData(
  colorScheme: _atlasScheme,
  // Gold, not the scheme's pale red: buttons look stamped in gilt, like the icon.
  floatingActionButtonTheme: FloatingActionButtonThemeData(
    backgroundColor: _atlasScheme.secondaryContainer,
    foregroundColor: _atlasScheme.onSecondaryContainer,
  ),
);

final _atlasScheme = ColorScheme.fromSeed(
  seedColor: const Color(0xFF8E2A1E),
  brightness: Brightness.light,
).copyWith(
  primary: const Color(0xFF8E2A1E), // wax red
  onPrimary: const Color(0xFFFFF6E6),
  primaryContainer: const Color(0xFFF1D2C2),
  onPrimaryContainer: const Color(0xFF3E0E07),
  secondary: const Color(0xFF8A6420), // gold
  onSecondary: const Color(0xFFFFF6E6),
  secondaryContainer: const Color(0xFFEBD49E),
  onSecondaryContainer: const Color(0xFF2E2004),
  tertiaryContainer: const Color(0xFFE5CC94), // the app bar while editing
  onTertiaryContainer: const Color(0xFF34260A),
  surface: const Color(0xFFF3E6CC), // parchment
  onSurface: const Color(0xFF3B2516), // leather brown ink
  onSurfaceVariant: const Color(0xFF6B4E33),
  surfaceContainerLowest: const Color(0xFFFBF4E4),
  surfaceContainerLow: const Color(0xFFF6EBD3),
  surfaceContainer: const Color(0xFFEFE0C2),
  surfaceContainerHigh: const Color(0xFFEAD8B6),
  surfaceContainerHighest: const Color(0xFFE3CEA8),
  outline: const Color(0xFF9C7C58),
  outlineVariant: const Color(0xFFCDB48C),
);

/// The chosen theme, remembered on the phone.
class ThemeSetting extends ValueNotifier<AppTheme> {
  ThemeSetting._(super.value, this._prefs);

  static const _key = 'theme';

  static Future<ThemeSetting> load() async {
    final prefs = SharedPreferencesAsync();
    final saved = await prefs.getString(_key);
    return ThemeSetting._(
        AppTheme.values.firstWhere((t) => t.name == saved, orElse: () => AppTheme.dark), prefs);
  }

  final SharedPreferencesAsync _prefs;

  void choose(AppTheme theme) {
    if (theme == value) return;
    value = theme;
    _prefs.setString(_key, theme.name);
  }
}
