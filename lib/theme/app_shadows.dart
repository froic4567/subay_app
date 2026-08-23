import 'package:flutter/material.dart';

/// Box-shadow presets translated from the FloodSight web app's CSS shadow
/// scale (floodsight-design-reference.css, section 6).
///
/// Usage: cards/panels → [base]; small controls (search bars, chips) → [sm];
/// elevated sheets/dropdowns → [lg]; active/emphasized surfaces → [xl].
class AppShadows {
  AppShadows._();

  static List<BoxShadow> sm = [
    BoxShadow(
      color: Colors.black.withValues(alpha: 0.05),
      blurRadius: 2,
      offset: const Offset(0, 1),
    ),
  ];

  static List<BoxShadow> base = [
    BoxShadow(
      color: Colors.black.withValues(alpha: 0.08),
      blurRadius: 6,
      offset: const Offset(0, 1),
    ),
  ];

  static List<BoxShadow> lg = [
    BoxShadow(
      color: Colors.black.withValues(alpha: 0.12),
      blurRadius: 15,
      offset: const Offset(0, 6),
    ),
  ];

  static List<BoxShadow> xl = [
    BoxShadow(
      color: Colors.black.withValues(alpha: 0.16),
      blurRadius: 22,
      offset: const Offset(0, 10),
    ),
  ];
}
