import 'package:flutter/material.dart';

class AppColors {
  // FloodSight brand blue — matches the web dashboard's chrome primary
  // (--color-primary: oklch(0.58 0.17 245), ~#2C6FD1).
  static const Color primary      = Color(0xFF2C6FD1);
  static const Color primaryDark  = Color(0xFF1E4E9E); // pressed/hover state
  static const Color primaryLight = Color(0xFFE4EEF9); // pale blue accent — chip/badge backgrounds

  static const Color danger      = Color(0xFFEF4444);
  static const Color dangerLight = Color(0xFFFCEBEB);
  static const Color dangerText  = Color(0xFFA32D2D);

  static const Color alert       = Color(0xFFF59E0B);
  static const Color alertLight  = Color(0xFFFFFBEB);
  static const Color alertText   = Color(0xFF854F0B);

  static const Color normal      = Color(0xFF22C55E);
  static const Color normalLight = Color(0xFFF0FDF4);
  static const Color normalText  = Color(0xFF166534);

  static const Color infoLight   = Color(0xFFEFF6FF);
  static const Color infoText    = Color(0xFF185FA5);

  static const Color background          = Color(0xFFFFFFFF);
  static const Color backgroundSecondary = Color(0xFFF4F4F5);

  static const Color textPrimary   = Color(0xFF111827);
  static const Color textSecondary = Color(0xFF444444);
  static const Color textMuted     = Color(0xFF888888);
  static const Color textDisabled  = Color(0xFFBBBBBB);

  static const Color border = Color(0xFFE5E7EB);

  // Google Maps–style route line colors
  static const Color routeBlue       = Color(0xFF2D7FF9); // main route line
  static const Color routeBlueDark   = Color(0xFF1B5EAB); // outline / shadow
  static const Color routeStart       = Color(0xFF2D7FF9); // origin marker

  // Camera-covered road segment outline (Map tab)
  static const Color segmentOutline = Color(0xFF2A2A2A);

  // ── Dark mode — deep navy palette ─────────────────────────────────────
  // Used by the dark theme and any screen that needs explicit dark surfaces
  // (profile cards, routing panels, navigation bars, notification cards).
  static const Color darkBackground    = Color(0xFF060E1A);
  static const Color darkSurface       = Color(0xFF0B1929);
  static const Color darkSurfaceMuted  = Color(0xFF10243B);
  static const Color darkBorder        = Color(0xFF1D3E63);
  static const Color darkTextPrimary   = Color(0xFFF2F7FF);
  static const Color darkTextSecondary = Color(0xFFC3D2E4);
  static const Color darkTextMuted     = Color(0xFF8DA4BF);
  static const Color darkAccent        = Color(0xFF2F9BFF);
}
