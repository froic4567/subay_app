import 'package:latlong2/latlong.dart';

import '../config/app_config.dart';

/// Raw measurements collected around a single routing computation.
class RoutingTestSnapshot {
  final LatLng origin;
  final LatLng destination;

  final Duration graphConstructionTime;
  final Duration pathGenerationLatency;
  final Duration dbFetchTime;
  final Duration osrmFetchTime;
  final Duration dijkstraTime;

  final bool dangerFreeRoute;
  final bool alertPreferenceApplicable;
  final bool normalChosenWhenBothExist;

  final int illegalDetours;
  final bool allSegmentsLegal;

  final bool isReroute;
  final Duration? rerouteTriggerLatency;
  final bool? rerouteAccurate;

  final double multiFeedOverheadMsPerFeed;
  final int activeFeedCount;

  final List<int> nodeSequence;
  final double distanceKm;
  final String etaText;
  final bool routeFound;

  const RoutingTestSnapshot({
    required this.origin,
    required this.destination,
    required this.graphConstructionTime,
    required this.pathGenerationLatency,
    required this.dbFetchTime,
    required this.osrmFetchTime,
    required this.dijkstraTime,
    required this.dangerFreeRoute,
    required this.alertPreferenceApplicable,
    required this.normalChosenWhenBothExist,
    required this.illegalDetours,
    required this.allSegmentsLegal,
    required this.isReroute,
    this.rerouteTriggerLatency,
    this.rerouteAccurate,
    required this.multiFeedOverheadMsPerFeed,
    required this.activeFeedCount,
    required this.nodeSequence,
    required this.distanceKm,
    required this.etaText,
    required this.routeFound,
  });
}

/// Session-persisted counters for cumulative percentage metrics.
class _RoutingTestSession {
  int totalRouteRequests = 0;
  int dangerFreeCount = 0;

  int alertPreferenceCases = 0;
  int alertPreferenceSuccesses = 0;

  int legalComplianceChecks = 0;
  int legalComplianceSuccesses = 0;

  int rerouteEvents = 0;
  int rerouteAccurateCount = 0;
}

/// Terminal logger for routing advisory performance validation.
class RoutingTestLogger {
  RoutingTestLogger._();

  static final _RoutingTestSession _session = _RoutingTestSession();

  /// Prints the full routing test log when [AppConfig.debugRoutingLog] is true.
  static void logRoutingTest(RoutingTestSnapshot snapshot) {
    if (!AppConfig.debugRoutingLog) return;

    _updateSessionCounters(snapshot);

    final ts = DateTime.now().toUtc().toIso8601String();
    final graphMs = snapshot.graphConstructionTime.inMicroseconds / 1000.0;
    final pathMs = snapshot.pathGenerationLatency.inMicroseconds / 1000.0;

    final dangerRate = _pct(_session.dangerFreeCount, _session.totalRouteRequests);
    final alertScore = _pct(
      _session.alertPreferenceSuccesses,
      _session.alertPreferenceCases,
    );
    final legalRate = _pct(
      _session.legalComplianceSuccesses,
      _session.legalComplianceChecks,
    );
    final rerouteAccuracy = _session.rerouteEvents == 0
        ? null
        : _pct(_session.rerouteAccurateCount, _session.rerouteEvents);

    final graphPass = graphMs <= 50.0;
    final pathPass = pathMs <= 150.0;
    final dangerPass = dangerRate >= 100.0;
    final alertPass = _session.alertPreferenceCases == 0 || alertScore >= 95.0;
    final legalPass = legalRate >= 100.0;
    final detourPass = snapshot.illegalDetours == 0;

    final rerouteLatencyStr = snapshot.isReroute && snapshot.rerouteTriggerLatency != null
        ? '${(snapshot.rerouteTriggerLatency!.inMicroseconds / 1000000).toStringAsFixed(1)} s'
        : '—';
    final rerouteLatencyPass = snapshot.isReroute &&
        snapshot.rerouteTriggerLatency != null &&
        snapshot.rerouteTriggerLatency!.inMilliseconds <= 3000;
    final rerouteAccuracyPass =
        rerouteAccuracy != null && rerouteAccuracy >= 99.0;

    final overheadPass = snapshot.multiFeedOverheadMsPerFeed <= 10.0;

    final nodeSeq = snapshot.nodeSequence.isEmpty
        ? '[no path]'
        : '[${snapshot.nodeSequence.join(', ')}]';

    final buffer = StringBuffer()
      ..writeln('=== ROUTING ADVISORY TEST LOG ===')
      ..writeln('Timestamp: $ts')
      ..writeln(
        'Source: [${snapshot.origin.latitude.toStringAsFixed(6)}, '
        '${snapshot.origin.longitude.toStringAsFixed(6)}]   '
        'Destination: [${snapshot.destination.latitude.toStringAsFixed(6)}, '
        '${snapshot.destination.longitude.toStringAsFixed(6)}]',
      )
      ..writeln()
      ..writeln('[1] Algorithm Execution Speed')
      ..writeln(
        '    Graph Construction Time : ${graphMs.toStringAsFixed(0)} ms   '
        '(Target: ≤ 50 ms)   [${graphPass ? 'PASS' : 'FAIL'}]',
      )
      ..writeln(
        '    Path Generation Latency : ${pathMs.toStringAsFixed(0)} ms   '
        '(Target: ≤ 150 ms)  [${pathPass ? 'PASS' : 'FAIL'}]',
      )
      ..writeln()
      ..writeln('[2] Obstruction Avoidance')
      ..writeln(
        '    DANGER Zone Avoidance Rate : ${dangerRate.toStringAsFixed(0)}%  '
        '(Target: 100%)      [${dangerPass ? 'PASS' : 'FAIL'}]',
      )
      ..writeln(
        '    ALERT Zone Preference Score: ${alertScore.toStringAsFixed(0)}%  '
        '(Target: ≥ 95%)     [${alertPass ? 'PASS' : 'FAIL'}]',
      )
      ..writeln()
      ..writeln('[3] Route Deviation Legality')
      ..writeln(
        '    Legal Route Compliance Rate: ${legalRate.toStringAsFixed(0)}%  '
        '(Target: 100%)      [${legalPass ? 'PASS' : 'FAIL'}]',
      )
      ..writeln(
        '    Illegal Detours Detected   : ${snapshot.illegalDetours}     '
        '(Target: 0)        [${detourPass ? 'PASS' : 'FAIL'}]',
      )
      ..writeln()
      ..writeln('[4] Dynamic Rerouting')
      ..writeln(
        '    Re-route Trigger Latency : $rerouteLatencyStr  '
        '(Target: ≤ 3.0 s)   [${snapshot.isReroute ? (rerouteLatencyPass ? 'PASS' : 'FAIL') : 'N/A'}]',
      )
      ..writeln(
        '    Rerouting Accuracy       : ${rerouteAccuracy == null ? '—' : '${rerouteAccuracy.toStringAsFixed(0)}%'}    '
        '(Target: ≥ 99%)     [${rerouteAccuracy == null ? 'N/A' : (rerouteAccuracyPass ? 'PASS' : 'FAIL')}]',
      )
      ..writeln()
      ..writeln('[5] Scalability')
      ..writeln(
        '    Multi-Feed Routing Overhead: ${snapshot.multiFeedOverheadMsPerFeed.toStringAsFixed(1)} ms/feed '
        '(Target: ≤ 10 ms) [${overheadPass ? 'PASS' : 'FAIL'}]',
      )
      ..writeln()
      ..writeln('End-to-End Latency Chain (available stages):')
      ..writeln(
        '    DB Read (flood sync)     : ${(snapshot.dbFetchTime.inMicroseconds / 1000).toStringAsFixed(0)} ms',
      )
      ..writeln(
        '    OSRM Fetch               : ${(snapshot.osrmFetchTime.inMicroseconds / 1000).toStringAsFixed(0)} ms',
      )
      ..writeln(
        '    Graph Construction       : ${graphMs.toStringAsFixed(0)} ms',
      )
      ..writeln(
        '    Dijkstra Computation     : ${(snapshot.dijkstraTime.inMicroseconds / 1000).toStringAsFixed(0)} ms',
      )
      ..writeln(
        '    Total Path Generation    : ${pathMs.toStringAsFixed(0)} ms  '
        '(Tresponse full-cycle proxy)',
      )
      ..writeln(
        '    Active CCTV Feeds        : ${snapshot.activeFeedCount}',
      )
      ..writeln()
      ..writeln('Route Output: $nodeSeq')
      ..writeln(
        'Distance: ${snapshot.distanceKm.toStringAsFixed(1)} km | '
        'Est. Travel Time: ${snapshot.etaText}',
      )
      ..writeln('==================================');

    // ignore: avoid_print
    print(buffer.toString());
  }

  static void _updateSessionCounters(RoutingTestSnapshot snapshot) {
    if (!snapshot.routeFound) return;

    _session.totalRouteRequests++;
    if (snapshot.dangerFreeRoute) _session.dangerFreeCount++;

    if (snapshot.alertPreferenceApplicable) {
      _session.alertPreferenceCases++;
      if (snapshot.normalChosenWhenBothExist) {
        _session.alertPreferenceSuccesses++;
      }
    }

    _session.legalComplianceChecks++;
    if (snapshot.allSegmentsLegal) _session.legalComplianceSuccesses++;

    if (snapshot.isReroute && snapshot.rerouteAccurate != null) {
      _session.rerouteEvents++;
      if (snapshot.rerouteAccurate!) _session.rerouteAccurateCount++;
    }
  }

  static double _pct(int numerator, int denominator) {
    if (denominator == 0) return 100.0;
    return (numerator / denominator) * 100.0;
  }

  /// Resets session counters (useful between test runs).
  static void resetSession() {
    _session
      ..totalRouteRequests = 0
      ..dangerFreeCount = 0
      ..alertPreferenceCases = 0
      ..alertPreferenceSuccesses = 0
      ..legalComplianceChecks = 0
      ..legalComplianceSuccesses = 0
      ..rerouteEvents = 0
      ..rerouteAccurateCount = 0;
  }
}
