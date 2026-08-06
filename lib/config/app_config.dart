/// Application-wide configuration flags.
class AppConfig {
  /// When true, prints detailed routing performance metrics to the terminal
  /// on every route request / recalculation. Set to false for production builds.
  ///
  /// Can also be enabled at compile time:
  /// `flutter run --dart-define=DEBUG_ROUTING_LOG=true`
  static const bool debugRoutingLog = bool.fromEnvironment(
    'DEBUG_ROUTING_LOG',
    defaultValue: true,
  );
}
