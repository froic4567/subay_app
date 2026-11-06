import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App-wide light/dark mode state.
///
/// Toggled from the Profile tab and observed by `MaterialApp` in main.dart so
/// the whole UI switches theme without touching any map or data-processing
/// code.
///
/// The chosen mode is persisted locally so it survives app restarts and
/// signing out/in. It only changes when the user taps the theme button.
class ThemeController {
  ThemeController._();

  static const String _prefsKey = 'theme_mode';

  static SharedPreferences? _prefs;

  static final ValueNotifier<ThemeMode> mode =
      ValueNotifier<ThemeMode>(ThemeMode.light);

  static bool get isDark => mode.value == ThemeMode.dark;

  /// Restores the saved theme. Call once during app startup before runApp().
  static Future<void> load() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      final stored = _prefs?.getString(_prefsKey);
      if (stored == 'dark') {
        mode.value = ThemeMode.dark;
      } else if (stored == 'light') {
        mode.value = ThemeMode.light;
      }
    } catch (_) {
      // Storage unavailable — fall back to the default light theme.
    }
  }

  static void toggle() {
    final next = isDark ? ThemeMode.light : ThemeMode.dark;
    mode.value = next;
    unawaited(_persist(next == ThemeMode.dark));
  }

  static Future<void> _persist(bool dark) async {
    try {
      final prefs = _prefs ??= await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, dark ? 'dark' : 'light');
    } catch (_) {
      // Non-fatal: the current session still switches theme.
    }
  }
}
