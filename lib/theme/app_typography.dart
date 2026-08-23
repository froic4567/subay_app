import 'package:flutter/material.dart';
import 'app_colors.dart';

/// Text styles translated from the FloodSight web app's typography patterns
/// (floodsight-design-reference.css, section 3). The web app uses no custom
/// webfont — just the system font stack — so these use Flutter's platform
/// default font too; only size/weight/spacing/color are translated.
class AppTypography {
  AppTypography._();

  /// Screen/page titles, e.g. "Live Flood Watch".
  static const TextStyle pageTitle = TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.3,
    color: AppColors.textPrimary,
  );

  /// Small uppercase section headers.
  static const TextStyle sectionLabel = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.6,
    color: AppColors.textMuted,
  );

  static const TextStyle cardTitle = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w600,
    height: 1.35,
    color: AppColors.textPrimary,
  );

  /// Big tabular numbers, e.g. dashboard stat cards.
  static const TextStyle statNumber = TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w700,
    color: AppColors.textPrimary,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  /// Smaller tabular numbers, e.g. distance/ETA readouts.
  static const TextStyle metricValue = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  static const TextStyle badge = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.3,
  );

  /// e.g. the app tagline under a logo.
  static const TextStyle eyebrow = TextStyle(
    fontSize: 10,
    fontWeight: FontWeight.w600,
    letterSpacing: 1.2,
    color: AppColors.textMuted,
  );
}
