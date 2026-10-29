import 'package:flutter/material.dart';

/// App-wide light/dark mode state.
///
/// Toggled from the Profile tab and observed by `MaterialApp` in main.dart so
/// the whole UI switches theme without touching any map or data-processing
/// code.
class ThemeController {
  ThemeController._();

  static final ValueNotifier<ThemeMode> mode =
      ValueNotifier<ThemeMode>(ThemeMode.light);

  static bool get isDark => mode.value == ThemeMode.dark;

  static void toggle() {
    mode.value = isDark ? ThemeMode.light : ThemeMode.dark;
  }
}
