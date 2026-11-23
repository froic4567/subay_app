/// App version shown on the login screen.
///
/// Keep this in sync with `version:` in pubspec.yaml and the GitHub release
/// tag when publishing a new APK.
class AppVersion {
  AppVersion._();

  static const String number = '1.0.7';
  static const String build = '7';

  /// e.g. "Version 1.0.7 (7)"
  static const String label = 'Version $number ($build)';
}
