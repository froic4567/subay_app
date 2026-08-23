/// Border-radius scale translated from the FloodSight web app's CSS
/// (`--radius-*` custom properties in floodsight-design-reference.css).
///
/// Usage: buttons/inputs/nav chips → [md]; cards/sheets → [xl];
/// hero/notification panels → [xxl]; badges/avatars/dots → [full].
class AppRadius {
  AppRadius._();

  static const double sm   = 6;
  static const double md   = 8;
  static const double lg   = 10;
  static const double xl   = 17;
  static const double xxl  = 18;
  static const double full = 9999;
}
