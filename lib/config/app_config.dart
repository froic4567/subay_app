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

  /// When true, each routing metrics snapshot is also uploaded to the backend
  /// and stored in MongoDB. This is what makes metrics available on mobile,
  /// where there is no browser DevTools console.
  ///
  /// Can be disabled at compile time:
  /// `flutter run --dart-define=COLLECT_ROUTING_METRICS=false`
  static const bool collectRoutingMetrics = bool.fromEnvironment(
    'COLLECT_ROUTING_METRICS',
    defaultValue: true,
  );
}
