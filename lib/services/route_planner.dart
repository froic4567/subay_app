import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'cctv_service.dart';
import 'geo_utils.dart';
import 'routing_test_logger.dart';
import 'road_segment_service.dart';

/// Optional context for route requests triggered by flood-status changes.
class RouteRequestContext {
  final bool isReroute;
  final DateTime? floodChangeDetectedAt;
  final List<Map<String, dynamic>>? previousCctvDocs;

  const RouteRequestContext({
    this.isReroute = false,
    this.floodChangeDetectedAt,
    this.previousCctvDocs,
  });
}

/// Vehicle types available for route planning.
/// Thresholds match the passability table shown in map_screen.dart
/// so the routing logic and the UI display stay consistent.
enum VehicleType { light, medium, heavy }

extension VehicleTypeLabel on VehicleType {
  String get label {
    switch (this) {
      case VehicleType.light:
        return 'Light Vehicle';
      case VehicleType.medium:
        return 'Medium Vehicle';
      case VehicleType.heavy:
        return 'Heavy Vehicle';
    }
  }

  /// Maximum flood water depth (in meters) this vehicle type can safely pass.
  double get maxWaterLevelM {
    switch (this) {
      case VehicleType.light:
        return 0.15;
      case VehicleType.medium:
        return 0.25;
      case VehicleType.heavy:
        return 0.65;
    }
  }

  IconData get icon {
    switch (this) {
      case VehicleType.light:
        return Icons.directions_car;
      case VehicleType.medium:
        return Icons.airport_shuttle;
      case VehicleType.heavy:
        return Icons.local_shipping;
    }
  }
}

/// A single CCTV flood point along the road network.
class RouteNode {
  final String id;
  final String name;
  final String roadName;
  final LatLng location;
  final String status; // stored UPPERCASE: DANGER / ALERT / SAFE / NORMAL
  final double waterLevelM; // in meters, direct from the database
  final List<String> connectedIds;

  const RouteNode({
    required this.id,
    required this.name,
    required this.roadName,
    required this.location,
    required this.status,
    required this.waterLevelM,
    required this.connectedIds,
  });

  /// Whether a given vehicle can safely traverse this flood point.
  /// DANGER is impassable for everyone; ALERT is passable only if the water
  /// level is within the vehicle's tolerance; anything else is passable.
  bool isPassableFor(VehicleType vehicleType) {
    final s = status.toUpperCase();
    if (s == 'DANGER') return false;
    if (s == 'ALERT') return waterLevelM <= vehicleType.maxWaterLevelM;
    return true;
  }
}

/// Result of a route plan. Field names are kept stable because
/// routing_screen.dart consumes [polyline], [etaText], [distanceKm]
/// and [avoidedNodes] directly.
class RoutePlanResult {
  final List<RouteNode> path;
  final double distanceKm;
  final double durationMinutes;
  final List<RouteNode> avoidedNodes;
  final List<LatLng> polyline;
  final String summary;

  /// true = every segment is NORMAL/SAFE; false = passes an ALERT segment.
  final bool isFullySafe;

  /// Non-null when the chosen path still crosses an ALERT zone, or when no
  /// safe route could be produced at all.
  final String? warningMessage;

  const RoutePlanResult({
    required this.path,
    required this.distanceKm,
    required this.durationMinutes,
    required this.avoidedNodes,
    required this.polyline,
    required this.summary,
    this.isFullySafe = true,
    this.warningMessage,
  });

  /// Static helper to format minutes into a human-readable ETA string.
  static String formatEta(double minutes) {
    if (minutes < 1) return '< 1 min';
    if (minutes < 60) return '${minutes.round()} min';
    final hrs = (minutes / 60).floor();
    final mins = (minutes % 60).round();
    if (mins == 0) return '$hrs hr';
    return '$hrs hr $mins min';
  }

  /// Human-readable ETA string e.g. "5 min" or "1 hr 20 min".
  String get etaText => formatEta(durationMinutes);
}

/// ---------------------------------------------------------------------------
/// Internal graph primitives used by the Dijkstra router.
/// ---------------------------------------------------------------------------

/// A weighted edge in the routing graph.
class _Edge {
  final int to;
  final double weight; // meters, penalised by flood conditions
  final bool isAlert; // true if this edge grazes a passable ALERT zone
  const _Edge(this.to, this.weight, this.isAlert);
}

/// A single OSRM alternative route geometry.
class _OsrmRoute {
  final List<LatLng> points;
  final double distanceMeters;
  final double durationSeconds;
  const _OsrmRoute(this.points, this.distanceMeters, this.durationSeconds);
}

/// Segment weight + whether it touches an ALERT zone.
class _SegWeight {
  final double weight;
  final bool isAlert;
  const _SegWeight(this.weight, this.isAlert);
}

/// Outcome of a Dijkstra search.
class _DijkstraResult {
  final List<int> path; // ordered node indices
  final double cost;
  final bool hasAlert;
  const _DijkstraResult(this.path, this.cost, this.hasAlert);
}

/// Built routing graph ready for Dijkstra.
class _GraphBuildResult {
  final List<LatLng> nodes;
  final List<List<_Edge>> adj;
  final int src;
  final int dst;

  const _GraphBuildResult({
    required this.nodes,
    required this.adj,
    required this.src,
    required this.dst,
  });
}

/// A compact binary min-heap keyed by cost. Avoids adding a new dependency
/// just for a priority queue.
class _MinHeap {
  final List<double> _cost = <double>[];
  final List<int> _node = <int>[];

  bool get isEmpty => _node.isEmpty;

  void add(double cost, int node) {
    _cost.add(cost);
    _node.add(node);
    var i = _node.length - 1;
    while (i > 0) {
      final parent = (i - 1) >> 1;
      if (_cost[parent] <= _cost[i]) break;
      _swap(i, parent);
      i = parent;
    }
  }

  (double, int) removeMin() {
    final resultCost = _cost[0];
    final resultNode = _node[0];
    final last = _node.length - 1;
    _cost[0] = _cost[last];
    _node[0] = _node[last];
    _cost.removeLast();
    _node.removeLast();

    var i = 0;
    final len = _node.length;
    while (true) {
      final l = 2 * i + 1;
      final r = 2 * i + 2;
      var smallest = i;
      if (l < len && _cost[l] < _cost[smallest]) smallest = l;
      if (r < len && _cost[r] < _cost[smallest]) smallest = r;
      if (smallest == i) break;
      _swap(i, smallest);
      i = smallest;
    }
    return (resultCost, resultNode);
  }

  void _swap(int a, int b) {
    final tc = _cost[a];
    _cost[a] = _cost[b];
    _cost[b] = tc;
    final tn = _node[a];
    _node[a] = _node[b];
    _node[b] = tn;
  }
}

/// Lexicographic cost used for safety-first routing: (safetyLevel, timeSec, distanceM)
class _Cost implements Comparable<_Cost> {
  final int safetyLevel; // 0 = NORMAL-only, 1 = contains ALERT
  final double timeSec; // cumulative travel time in seconds
  final double distanceM; // cumulative raw distance in meters (unpenalized)

  const _Cost(this.safetyLevel, this.timeSec, this.distanceM);

  static const _infty = _Cost(999999, double.infinity, double.infinity);

  @override
  int compareTo(_Cost other) {
    if (safetyLevel != other.safetyLevel) return safetyLevel - other.safetyLevel;
    if (timeSec != other.timeSec) return timeSec < other.timeSec ? -1 : 1;
    if (distanceM != other.distanceM) return distanceM < other.distanceM ? -1 : 1;
    return 0;
  }
}

/// Min-heap keyed by [_Cost] for lexicographic ordering.
class _MinHeapCost {
  final List<_Cost> _cost = <_Cost>[];
  final List<int> _node = <int>[];

  bool get isEmpty => _node.isEmpty;

  void add(_Cost cost, int node) {
    _cost.add(cost);
    _node.add(node);
    var i = _node.length - 1;
    while (i > 0) {
      final parent = (i - 1) >> 1;
      if (_cost[parent].compareTo(_cost[i]) <= 0) break;
      _swap(i, parent);
      i = parent;
    }
  }

  ( _Cost, int ) removeMin() {
    final resultCost = _cost[0];
    final resultNode = _node[0];
    final last = _node.length - 1;
    _cost[0] = _cost[last];
    _node[0] = _node[last];
    _cost.removeLast();
    _node.removeLast();

    var i = 0;
    final len = _node.length;
    while (true) {
      final l = 2 * i + 1;
      final r = 2 * i + 2;
      var smallest = i;
      if (l < len && _cost[l].compareTo(_cost[smallest]) < 0) smallest = l;
      if (r < len && _cost[r].compareTo(_cost[smallest]) < 0) smallest = r;
      if (smallest == i) break;
      _swap(i, smallest);
      i = smallest;
    }
    return (resultCost, resultNode);
  }

  void _swap(int a, int b) {
    final tc = _cost[a];
    _cost[a] = _cost[b];
    _cost[b] = tc;
    final tn = _node[a];
    _node[a] = _node[b];
    _node[b] = tn;
  }
}

/// Exception thrown when critical OSM geometry required for safety checks
/// is missing and the route cannot be verified.
class _UnableToVerifySafeRoute implements Exception {
  final String message;
  _UnableToVerifySafeRoute(this.message);
  @override
  String toString() => 'UnableToVerifySafeRoute: $message';
}

/// ---------------------------------------------------------------------------
/// Flood-aware, vehicle-aware router using true Dijkstra's algorithm.
///
/// Because OSRM returns a single polyline (a linear chain), running Dijkstra on
/// it alone could only ever reproduce that same line or fail outright. To give
/// Dijkstra genuine alternatives, this planner requests several OSRM route
/// candidates, merges them into one graph with spatial cross-links, blocks any
/// segment that grazes an impassable flood point, then lets Dijkstra stitch
/// together the safest guaranteed path.
/// ---------------------------------------------------------------------------
class RoutePlanner {
  /// Most recent CCTV payload fetched during routing (for reroute snapshots).
  static List<Map<String, dynamic>> lastCctvSnapshot = [];

  /// A flood point within this many meters of a segment influences that
  /// segment's cost (or blocks it entirely).
  ///
  /// This MUST be the same radius (or wider) than whatever radius is used
  /// to decide "is a candidate route near this hazard at all" (see
  /// _dangersNearCandidates calls in planRoute()). Previously those calls
  /// used a hardcoded 120.0 while this constant was 80.0 — any hazard
  /// between 80m and 120m of a route got flagged as "candidate routes pass
  /// near hazard" (triggering a detour attempt) but was NEVER actually
  /// marked on a graph vertex or blocked, because every vertex-marking and
  /// blocking check in this file gates on _detectRadiusM. If the detour
  /// attempt for that hazard cluster then failed to clear it, Dijkstra was
  /// completely blind to that hazard and could route straight past it.
  /// Keeping a single named constant, referenced everywhere a hazard
  /// "closeness" decision is made, prevents this class of gap.
  static const double _detectRadiusM = 120.0;

  /// Points from different OSRM alternatives closer than this are linked so
  /// Dijkstra can switch between candidate roads at crossover points.
  static const double _crossLinkRadiusM = 35.0;

  /// Multiplier applied to a segment that passes a *passable* ALERT zone, so
  /// Dijkstra prefers a fully-normal alternative when one exists.
  static const double _alertPenalty = 6.0;

  /// Arc-length distance (meters) a hazard's block/penalty propagates along
  /// a candidate route's polyline in each direction from its nearest point
  /// on that road, so a flood affects the whole nearby stretch instead of
  /// only the one OSRM edge that happens to graze the camera's exact
  /// coordinate. Mirrors the Map tab's camera-coverage clip distance
  /// (RoadSegmentService.clipDistanceM) so both tabs treat "affected road"
  /// consistently.
  static const double _hazardPropagationM = 200.0;

  /// Target maximum edge length (meters) after densifying an OSRM polyline.
  /// OSRM's own vertex spacing is uneven — dense on curves, sparse on long
  /// straights — so without this, a single long straight edge could span
  /// the entire hazard-propagation window and only ever be as accurate as
  /// one lucky/unlucky endpoint check.
  static const double _maxEdgeLengthM = 20.0;

  static Future<RoutePlanResult?> planRoute({
    required LatLng origin,
    required LatLng destination,
    required VehicleType vehicleType,
    RouteRequestContext? context,
  }) async {
    // Measures the complete planRoute execution, including all timed stages.
    final pathGenStopwatch = Stopwatch()..start();
    var dbFetchTime = Duration.zero;
    var overpassFetchTime = Duration.zero;
    var osrmFetchTime = Duration.zero;
    var detourSearchTime = Duration.zero;
    var valhallaFetchTime = Duration.zero;
    var graphConstructionTime = Duration.zero;
    var dijkstraTime = Duration.zero;

    // 1. Fetch live CCTV flood data from MongoDB via the backend API.
    // Measures only the CCTV backend read.
    final dbStopwatch = Stopwatch()..start();
    final cctvDocs = await CctvService.fetchCctvData();
    dbStopwatch.stop();
    dbFetchTime = dbStopwatch.elapsed;
    lastCctvSnapshot = List<Map<String, dynamic>>.from(cctvDocs);

    final seedNodes = _seedNodes(cctvDocs);
    final avoidableNodes =
        seedNodes.where((n) => !n.isPassableFor(vehicleType)).toList();
    final hazardNodes = seedNodes.where((n) {
      final s = n.status.toUpperCase();
      return s == 'DANGER' || s == 'ALERT';
    }).toList();
    final dangerNodes = seedNodes
        .where((n) => n.status.toUpperCase() == 'DANGER')
        .toList();

    // 1b. Fetch real OSM road-segment geometry for every hazard BEFORE
    //     generating any OSRM candidates or detours. This used to happen
    //     much later (right before graph construction), which meant
    //     detour generation and validation (_dangersNearCandidates,
    //     _fetchDetourRoutes) could only check a candidate route against
    //     the hazard's raw camera coordinate + a fixed radius — a much
    //     coarser check than the real OSM segment geometry the graph-
    //     building phase actually enforces. A detour could clear that
    //     coarse check (declared "safe" and stop escalating) while still
    //     crossing the hazard's real road segment, which can extend well
    //     beyond the camera's exact point — only to get blocked anyway
    //     once graph construction ran the accurate check, wasting the one
    //     detour attempt that was accepted and leaving Dijkstra with no
    //     safe path at all. Fetching geometry first lets every downstream
    //     check use the same, accurate definition of "near this hazard."
    final Map<String, RoadSegmentResult?> segmentsById = {};
    // Measures only the Overpass road-segment request.
    final overpassStopwatch = Stopwatch();
    try {
      // Batch fetch segments for all hazard nodes in one Overpass bbox
      // query to reuse cached geometry and avoid many individual requests.
      final idToCoord = {
        for (final n in hazardNodes) n.id: n.location,
      };
      overpassStopwatch.start();
      final fetched = await RoadSegmentService.getSegmentsForCoordinates(idToCoord);
      overpassStopwatch.stop();
      overpassFetchTime = overpassStopwatch.elapsed;
      for (final n in hazardNodes) {
        segmentsById[n.id] = fetched[n.id];
      }
    } catch (e) {
      // Include the request duration when the Overpass call throws.
      if (overpassStopwatch.isRunning) overpassStopwatch.stop();
      overpassFetchTime = overpassStopwatch.elapsed;
      print('⚠️ [RoutePlanner] Road segment lookups failed: $e');
      print('[RoadSegmentCache] TIMEOUT or geometry fetch failure');
      // Conservative behavior: if any hazard is DANGER or an ALERT that
      // is currently impassable for this vehicle, we cannot verify safety
      // and must refuse to return a potentially unsafe route.
      final critical = hazardNodes.where((h) =>
          h.status.toUpperCase() == 'DANGER' ||
          (h.status.toUpperCase() == 'ALERT' && !h.isPassableFor(vehicleType))).toList();
      if (critical.isNotEmpty) {
        for (final c in critical) {
          print('[RoadSegmentCache] Geometry unavailable for critical CCTV ${c.id} status=${c.status}');
        }
        // Build simple origin/destination placeholders for the result.
        final originNode = RouteNode(
          id: 'origin',
          name: 'Origin',
          roadName: 'Your location',
          location: origin,
          status: 'SAFE',
          waterLevelM: 0.0,
          connectedIds: const [],
        );
        final destinationNode = RouteNode(
          id: 'destination',
          name: 'Destination',
          roadName: 'Selected destination',
          location: destination,
          status: 'SAFE',
          waterLevelM: 0.0,
          connectedIds: const [],
        );
        return RoutePlanResult(
          path: [originNode, destinationNode],
          distanceKm: 0.0,
          durationMinutes: 0.0,
          avoidedNodes: avoidableNodes,
          polyline: const [],
          summary: 'Unable to verify safe route',
          isFullySafe: false,
          warningMessage:
              'Unable to verify safe route because road geometry could not be fetched. Please try again later.',
        );
      }
      // Otherwise continue using whatever cache is available and fallbacks.
    }

    // 2. Fetch OSRM candidate routes (primary + alternatives).
    // Measures only the primary OSRM route-fetch call.
    final osrmStopwatch = Stopwatch()..start();
    final routes = <_OsrmRoute>[...await _fetchOsrmRoutes(origin, destination)];
    osrmStopwatch.stop();
    osrmFetchTime = osrmStopwatch.elapsed;
    if (routes.isEmpty) {
      pathGenStopwatch.stop();
      _emitRoutingLog(
        origin: origin,
        destination: destination,
        context: context,
        pathGenerationLatency: pathGenStopwatch.elapsed,
        graphConstructionTime: graphConstructionTime,
        dbFetchTime: dbFetchTime,
        overpassFetchTime: overpassFetchTime,
        osrmFetchTime: osrmFetchTime,
        detourSearchTime: detourSearchTime,
        valhallaFetchTime: valhallaFetchTime,
        dijkstraTime: dijkstraTime,
        cctvDocs: cctvDocs,
        hazardNodes: hazardNodes,
        dangerNodes: dangerNodes,
        routes: routes,
        vehicleType: vehicleType,
        routeFound: false,
        adj: null,
        src: 0,
        dst: 0,
      );
      return null;
    }

    // 2b. If any candidate grazes an impassable flood point, actively request
    //     detour routes that steer OSRM around those points via offset
    //     waypoints. OSRM's own alternatives often all funnel through the same
    //     choke point on straight roads, so without this Dijkstra would have no
    //     genuinely safe candidate to choose. Both checks now use the real
    //     OSM segment geometry fetched above (see step 1b) wherever
    //     available, not just the hazard's raw coordinate.
    // Measures candidate danger checks and all OSRM detour-search attempts.
    final detourStopwatch = Stopwatch()..start();
    final dangersOnRoute = _dangersNearCandidates(
      routes,
      avoidableNodes,
      _detectRadiusM,
      segmentsById: segmentsById,
    );
    if (dangersOnRoute.isNotEmpty) {
      final detours = await _fetchDetourRoutes(
        origin: origin,
        destination: destination,
        dangers: dangersOnRoute,
        avoidableNodes: avoidableNodes,
        segmentsById: segmentsById,
      );
      detourStopwatch.stop();
      detourSearchTime = detourStopwatch.elapsed;
      // _fetchDetourRoutes already validates each candidate against
      // avoidableNodes internally (needed so it can stop escalating once a
      // clean detour is found), so every route returned here is confirmed
      // hazard-free — just add them all as Dijkstra candidates.
      routes.addAll(detours);
    } else {
      detourStopwatch.stop();
      detourSearchTime = detourStopwatch.elapsed;
    }

    // 2c. Ask Valhalla's public routing service for a route that is
    //     computed directly against the real road network while explicitly
    //     excluding every currently-blocked road. This is fundamentally
    //     different from (and complements) the OSRM candidates/detours
    //     above: those can only nudge an existing route sideways within a
    //     limited search cone (a fixed perpendicular offset, capped
    //     distance), so a genuine alternate bridge/crossing outside that
    //     cone can be permanently invisible to them no matter how far the
    //     destination is. Valhalla's exclude_polygons makes the routing
    //     engine itself avoid these roads while searching the FULL graph,
    //     so it can find a real detour regardless of direction or distance.
    //     If this fails or times out, that's fine — it's treated as "this
    //     extra candidate wasn't available," and the OSRM candidates/
    //     detours computed above still run independently either way.
    if (avoidableNodes.isNotEmpty) {
      // Measures only the Valhalla route-fetch call.
      final valhallaStopwatch = Stopwatch()..start();
      final valhallaRoute = await _fetchValhallaAvoidRoute(
        origin: origin,
        destination: destination,
        avoidableNodes: avoidableNodes,
        segmentsById: segmentsById,
      );
      valhallaStopwatch.stop();
      valhallaFetchTime = valhallaStopwatch.elapsed;
      if (valhallaRoute != null) {
        routes.add(valhallaRoute);
      }
    }

    // Measures only local graph construction in _buildGraph.
    final graphStopwatch = Stopwatch()..start();
    final graph = _buildGraph(
      routes: routes,
      origin: origin,
      destination: destination,
      hazardNodes: hazardNodes,
      vehicleType: vehicleType,
      segmentsById: segmentsById,
    );
    graphStopwatch.stop();
    graphConstructionTime = graphStopwatch.elapsed;

    final nodes = graph.nodes;
    final adj = graph.adj;
    final src = graph.src;
    final dst = graph.dst;

    // 6. Run Dijkstra to find the safest guaranteed path.
    // Measures only the Dijkstra shortest-path computation.
    final dijkstraStopwatch = Stopwatch()..start();
    final dijkstra = _dijkstra(adj, src, dst);
    dijkstraStopwatch.stop();
    dijkstraTime = dijkstraStopwatch.elapsed;

    final originNode = RouteNode(
      id: 'origin',
      name: 'Origin',
      roadName: 'Your location',
      location: origin,
      status: 'SAFE',
      waterLevelM: 0.0,
      connectedIds: const [],
    );
    final destinationNode = RouteNode(
      id: 'destination',
      name: 'Destination',
      roadName: 'Selected destination',
      location: destination,
      status: 'SAFE',
      waterLevelM: 0.0,
      connectedIds: const [],
    );

    // 7a. No fully-safe path survives the flood blocks. Do NOT fall back to
    //     the raw OSRM route here — that route is guaranteed to cross at
    //     least one DANGER/blocked segment (that's exactly why Dijkstra
    //     couldn't find a path), and a rendered polyline looks the same to
    //     a driver whether it's marked safe or not. Return no route at all,
    //     matching the same empty-polyline "no safe route" shape used by
    //     the other refusal branches in this function (see the
    //     _UnableToVerifySafeRoute catch block and the post-Dijkstra
    //     validation-failure branch below), so the caller/UI has nothing
    //     drivable-looking to draw and must show the refusal explicitly.
    if (dijkstra == null) {
      pathGenStopwatch.stop();

      _emitRoutingLog(
        origin: origin,
        destination: destination,
        context: context,
        pathGenerationLatency: pathGenStopwatch.elapsed,
        graphConstructionTime: graphConstructionTime,
        dbFetchTime: dbFetchTime,
        overpassFetchTime: overpassFetchTime,
        osrmFetchTime: osrmFetchTime,
        detourSearchTime: detourSearchTime,
        valhallaFetchTime: valhallaFetchTime,
        dijkstraTime: dijkstraTime,
        cctvDocs: cctvDocs,
        hazardNodes: hazardNodes,
        dangerNodes: dangerNodes,
        routes: routes,
        vehicleType: vehicleType,
        routeFound: false,
        adj: adj,
        src: src,
        dst: dst,
        dijkstraPath: const [],
        routePoints: const [],
        distanceKm: 0.0,
        durationMinutes: 0.0,
        chosenHasAlert: false,
      );

      return RoutePlanResult(
        path: [originNode, destinationNode],
        distanceKm: 0.0,
        durationMinutes: 0.0,
        avoidedNodes: avoidableNodes,
        polyline: const [],
        summary: 'No safe route available',
        isFullySafe: false,
        warningMessage:
            'No safe route could be found for your vehicle — every nearby road passes through a flooded or blocked area. Please wait for conditions to improve or choose a different destination.',
      );
    }
    // 7b. Assemble the winning polyline and derived metrics.
    final routePoints = dijkstra.path.map((i) => nodes[i]).toList();

    // Final validation: ensure resulting route does NOT intersect any
    // blocked OSM segment for the selected vehicle (defensive check).
    try {
      final valid = _validateRouteAgainstBlockedSegments(routePoints, segmentsById, hazardNodes, vehicleType);
      if (!valid) {
        print('[RouteValidation] Selected route intersects blocked OSM segment — rejecting');
        // Treat as no valid path so we use fallback behavior.
        pathGenStopwatch.stop();
        // Log and return as unsafe fallback
        _emitRoutingLog(
          origin: origin,
          destination: destination,
          context: context,
          pathGenerationLatency: pathGenStopwatch.elapsed,
          graphConstructionTime: graphConstructionTime,
          dbFetchTime: dbFetchTime,
          overpassFetchTime: overpassFetchTime,
          osrmFetchTime: osrmFetchTime,
          detourSearchTime: detourSearchTime,
          valhallaFetchTime: valhallaFetchTime,
          dijkstraTime: dijkstraTime,
          cctvDocs: cctvDocs,
          hazardNodes: hazardNodes,
          dangerNodes: dangerNodes,
          routes: routes,
          vehicleType: vehicleType,
          routeFound: false,
          adj: adj,
          src: src,
          dst: dst,
        );

        return RoutePlanResult(
          path: [
            RouteNode(
              id: 'origin',
              name: 'Origin',
              roadName: 'Your location',
              location: origin,
              status: 'SAFE',
              waterLevelM: 0.0,
              connectedIds: const [],
            ),
            RouteNode(
              id: 'destination',
              name: 'Destination',
              roadName: 'Selected destination',
              location: destination,
              status: 'SAFE',
              waterLevelM: 0.0,
              connectedIds: const [],
            ),
          ],
          distanceKm: 0.0,
          durationMinutes: 0.0,
          avoidedNodes: avoidableNodes,
          polyline: const [],
          summary: 'No safe route available',
          isFullySafe: false,
          warningMessage: 'No safe route is available for this vehicle.',
        );
      }
    } on _UnableToVerifySafeRoute catch (e) {
      print('[RouteValidation] Unable to verify safe route: ${e.message}');
      pathGenStopwatch.stop();
      return RoutePlanResult(
        path: [
          RouteNode(
            id: 'origin',
            name: 'Origin',
            roadName: 'Your location',
            location: origin,
            status: 'SAFE',
            waterLevelM: 0.0,
            connectedIds: const [],
          ),
          RouteNode(
            id: 'destination',
            name: 'Destination',
            roadName: 'Selected destination',
            location: destination,
            status: 'SAFE',
            waterLevelM: 0.0,
            connectedIds: const [],
          ),
        ],
        distanceKm: 0.0,
        durationMinutes: 0.0,
        avoidedNodes: avoidableNodes,
        polyline: const [],
        summary: 'Unable to verify safe route',
        isFullySafe: false,
        warningMessage:
            'Unable to verify safe route because road geometry could not be fetched. Please try again later.',
      );
    }
    
    final chosenDistanceM = _sumMeters(routePoints);

    // Estimate duration using the primary candidate's average speed.
    final primary = routes.first;
    final avgSpeed = primary.durationSeconds > 0
        ? primary.distanceMeters / primary.durationSeconds
        : 8.33; // ~30 km/h fallback
    final durationSec = avgSpeed > 0 ? chosenDistanceM / avgSpeed : 0.0;
    final distanceKm = chosenDistanceM / 1000.0;
    final durationMinutes = durationSec / 60.0;

    final warning = dijkstra.hasAlert
        ? 'Route passes through a flood alert zone. Proceed with caution for your vehicle type.'
        : null;

    pathGenStopwatch.stop();

    _emitRoutingLog(
      origin: origin,
      destination: destination,
      context: context,
      pathGenerationLatency: pathGenStopwatch.elapsed,
      graphConstructionTime: graphConstructionTime,
      dbFetchTime: dbFetchTime,
      overpassFetchTime: overpassFetchTime,
      osrmFetchTime: osrmFetchTime,
      detourSearchTime: detourSearchTime,
      valhallaFetchTime: valhallaFetchTime,
      dijkstraTime: dijkstraTime,
      cctvDocs: cctvDocs,
      hazardNodes: hazardNodes,
      dangerNodes: dangerNodes,
      routes: routes,
      vehicleType: vehicleType,
      routeFound: true,
      adj: adj,
      src: src,
      dst: dst,
      dijkstraPath: dijkstra.path,
      routePoints: routePoints,
      distanceKm: distanceKm,
      durationMinutes: durationMinutes,
      chosenHasAlert: dijkstra.hasAlert,
    );

    return RoutePlanResult(
      path: [originNode, destinationNode],
      distanceKm: distanceKm,
      durationMinutes: durationMinutes,
      avoidedNodes: avoidableNodes,
      polyline: routePoints,
      summary:
          '${distanceKm.toStringAsFixed(1)} km · ${RoutePlanResult.formatEta(durationMinutes)}',
      isFullySafe: !dijkstra.hasAlert,
      warningMessage: warning,
    );
  }

  /// Links nearby points that belong to *different* OSRM candidates, forming
  /// crossover junctions in the merged graph. Uses a coarse spatial hash grid
  /// to stay close to O(n).
  static _GraphBuildResult _buildGraph({
    required List<_OsrmRoute> routes,
    required LatLng origin,
    required LatLng destination,
    required List<RouteNode> hazardNodes,
    required VehicleType vehicleType,
    Map<String, RoadSegmentResult?>? segmentsById,
  }) {
    final nodes = <LatLng>[];
    final adj = <List<_Edge>>[];
    final nodeRoute = <int>[];
    // Precomputed hazard (if any) affecting each node, from arc-length
    // propagation along its own candidate route. Shared with _addCrossLinks
    // so cross-candidate edges use the same hazard model as within-candidate
    // edges, instead of re-deriving it from a raw point-radius check.
    final nodeHazard = <RouteNode?>[];

    int addNode(LatLng p, int route, RouteNode? hazard) {
      nodes.add(p);
      adj.add(<_Edge>[]);
      nodeRoute.add(route);
      nodeHazard.add(hazard);
      return nodes.length - 1;
    }

    void link(int a, int b, double w, bool alert) {
      adj[a].add(_Edge(b, w, alert));
      adj[b].add(_Edge(a, w, alert));
    }

    final startIdx = <int>[];
    final endIdx = <int>[];

    for (var r = 0; r < routes.length; r++) {
      final densified = GeoUtils.densify(routes[r].points, _maxEdgeLengthM);
      final vertexHazards = _computeVertexHazards(densified, hazardNodes, segmentsById);
      final idxs = List<int>.generate(
        densified.length,
        (k) => addNode(densified[k], r, vertexHazards[k]),
      );
      startIdx.add(idxs.first);
      endIdx.add(idxs.last);
      for (var i = 0; i < idxs.length - 1; i++) {
        final sw = _edgeWeightFromVertexHazards(
          nodes[idxs[i]],
          nodes[idxs[i + 1]],
          vertexHazards[i],
          vertexHazards[i + 1],
          vehicleType,
          segmentsById,
          hazardNodes,
        );
        if (sw.weight.isFinite) {
          link(idxs[i], idxs[i + 1], sw.weight, sw.isAlert);
        }
      }
    }

    _addCrossLinks(nodes, nodeRoute, nodeHazard, vehicleType, link, hazardNodes, segmentsById);

    final src = addNode(origin, -1, null);
    final dst = addNode(destination, -1, null);
    for (final s in startIdx) {
      final sw = _segmentWeight(origin, nodes[s], hazardNodes, vehicleType, segmentsById);
      if (sw.weight.isFinite) link(src, s, sw.weight, sw.isAlert);
    }
    for (final e in endIdx) {
      final sw = _segmentWeight(nodes[e], destination, hazardNodes, vehicleType, segmentsById);
      if (sw.weight.isFinite) link(dst, e, sw.weight, sw.isAlert);
    }

    // Enforce blocking and penalties based on full OSM segments. Any edge
    // overlapping a blocked OSM segment becomes impassable (infinite).
    const overlapTol = 8.0; // meters tolerance for geometric overlap
    for (var u = 0; u < adj.length; u++) {
      final a = nodes[u];
      for (var k = 0; k < adj[u].length; k++) {
        final e = adj[u][k];
        final b = nodes[e.to];
        // Skip already-infinite edges
        if (!e.weight.isFinite) continue;
        // As in _edgeWeightFromVertexHazards: scan every overlapping hazard
        // before deciding. Do not stop at the first ALERT match — a later
        // hazard in the list could be a DANGER (or vehicle-impassable
        // ALERT) overlapping the same short edge, which must win and hard
        // -block the edge regardless of iteration order.
        var blocked = false;
        RouteNode? worstAlert;
        for (final hazard in hazardNodes) {
          final seg = segmentsById != null ? segmentsById[hazard.id] : null;
          if (seg == null || seg.points.length < 2) continue;
          final overlaps = GeoUtils.polylineOverlapsPolyline([a, b], seg.points, overlapTol);
          if (!overlaps) continue;
          // If hazard blocks this vehicle, make infinite
          if (!hazard.isPassableFor(vehicleType) || hazard.status.toUpperCase() == 'DANGER') {
            adj[u][k] = _Edge(e.to, double.infinity, e.isAlert);
            blocked = true;
            print('[RouteSafety] Edge $u->${e.to} BLOCKED by ${hazard.id} (way=${seg.wayId})');
            break;
          }
          // Otherwise an ALERT applies: track the worst one, but keep
          // scanning in case a DANGER hazard also overlaps this edge.
          if (hazard.status.toUpperCase() == 'ALERT') {
            if (worstAlert == null || _hazardSeverity(hazard) > _hazardSeverity(worstAlert)) {
              worstAlert = hazard;
            }
          }
        }
        if (!blocked && worstAlert != null) {
          final base = _haversine(a, b);
          adj[u][k] = _Edge(e.to, base * _alertPenalty, true);
          print('[RouteSafety] Edge $u->${e.to} penalized (ALERT ${worstAlert.id})');
        }
      }
    }

    return _GraphBuildResult(nodes: nodes, adj: adj, src: src, dst: dst);
  }

  static void _emitRoutingLog({
    required LatLng origin,
    required LatLng destination,
    required RouteRequestContext? context,
    required Duration pathGenerationLatency,
    required Duration graphConstructionTime,
    required Duration dbFetchTime,
    required Duration overpassFetchTime,
    required Duration osrmFetchTime,
    required Duration detourSearchTime,
    required Duration valhallaFetchTime,
    required Duration dijkstraTime,
    required List<Map<String, dynamic>> cctvDocs,
    required List<RouteNode> hazardNodes,
    required List<RouteNode> dangerNodes,
    required List<_OsrmRoute> routes,
    required VehicleType vehicleType,
    required bool routeFound,
    List<List<_Edge>>? adj,
    int src = 0,
    int dst = 0,
    List<int> dijkstraPath = const [],
    List<LatLng> routePoints = const [],
    double distanceKm = 0,
    double durationMinutes = 0,
    bool chosenHasAlert = false,
  }) {
    final dangerFree = routePoints.length >= 2 &&
        !_routeTouchesDanger(routePoints, dangerNodes);
    final alertFreeExists =
        adj != null && _alertFreePathExists(adj, src, dst);
    final hasAlertAlternatives =
        adj != null && _graphHasAlertEdges(adj);
    final alertApplicable = alertFreeExists && hasAlertAlternatives;
    final normalChosen = !chosenHasAlert;

    final illegalDetours = adj != null && dijkstraPath.length >= 2
        ? _countIllegalDetours(adj, dijkstraPath)
        : (routePoints.length >= 2 ? routePoints.length - 1 : 0);
    final allLegal = illegalDetours == 0;

    final overheadMs = _measureMultiFeedOverhead(
      routes: routes,
      hazardNodes: hazardNodes,
      vehicleType: vehicleType,
      feedCount: cctvDocs.length,
    );

    Duration? rerouteLatency;
    bool? rerouteAccurate;
    if (context?.isReroute == true && context?.floodChangeDetectedAt != null) {
      rerouteLatency =
          DateTime.now().difference(context!.floodChangeDetectedAt!);
      if (context.previousCctvDocs != null && routePoints.length >= 2) {
        rerouteAccurate = _checkRerouteAccuracy(
          previousDocs: context.previousCctvDocs!,
          currentDocs: cctvDocs,
          routePoints: routePoints,
          vehicleType: vehicleType,
        );
      }
    }

    RoutingTestLogger.logRoutingTest(
      RoutingTestSnapshot(
        origin: origin,
        destination: destination,
        graphConstructionTime: graphConstructionTime,
        pathGenerationLatency: pathGenerationLatency,
        dbFetchTime: dbFetchTime,
        overpassFetchTime: overpassFetchTime,
        osrmFetchTime: osrmFetchTime,
        detourSearchTime: detourSearchTime,
        valhallaFetchTime: valhallaFetchTime,
        dijkstraTime: dijkstraTime,
        dangerFreeRoute: dangerFree,
        alertPreferenceApplicable: alertApplicable,
        normalChosenWhenBothExist: normalChosen,
        illegalDetours: illegalDetours,
        allSegmentsLegal: allLegal,
        isReroute: context?.isReroute ?? false,
        rerouteTriggerLatency: rerouteLatency,
        rerouteAccurate: rerouteAccurate,
        multiFeedOverheadMsPerFeed: overheadMs,
        activeFeedCount: cctvDocs.length,
        nodeSequence: dijkstraPath,
        distanceKm: distanceKm,
        etaText: RoutePlanResult.formatEta(durationMinutes),
        routeFound: routeFound,
      ),
    );
  }

  /// True when any route segment passes within the danger detection radius.
  static bool _routeTouchesDanger(List<LatLng> routePoints, List<RouteNode> dangerNodes) {
    for (var i = 0; i < routePoints.length - 1; i++) {
      final a = routePoints[i];
      final b = routePoints[i + 1];
      final mid = LatLng(
        (a.latitude + b.latitude) / 2,
        (a.longitude + b.longitude) / 2,
      );
      for (final d in dangerNodes) {
        final dist = [
          _haversine(a, d.location),
          _haversine(b, d.location),
          _haversine(mid, d.location),
        ].reduce(min);
        if (dist <= _detectRadiusM) return true;
      }
    }
    return false;
  }

  /// Counts consecutive path hops with no matching edge in the adjacency graph.
  static int _countIllegalDetours(List<List<_Edge>> adj, List<int> path) {
    var illegal = 0;
    for (var i = 0; i < path.length - 1; i++) {
      final u = path[i];
      final v = path[i + 1];
      final connected = adj[u].any((e) => e.to == v);
      if (!connected) illegal++;
    }
    return illegal;
  }

  /// Returns true when a path exists that avoids all ALERT-classified edges.
  static bool _alertFreePathExists(List<List<_Edge>> adj, int src, int dst) {
    final n = adj.length;
    final dist = List<double>.filled(n, double.infinity);
    final prev = List<int>.filled(n, -1);
    dist[src] = 0;

    final heap = _MinHeap();
    heap.add(0.0, src);

    while (!heap.isEmpty) {
      final (cost, u) = heap.removeMin();
      if (cost > dist[u]) continue;
      if (u == dst) break;

      for (final e in adj[u]) {
        if (e.isAlert || !e.weight.isFinite) continue;
        final newCost = dist[u] + e.weight;
        if (newCost < dist[e.to]) {
          dist[e.to] = newCost;
          prev[e.to] = u;
          heap.add(newCost, e.to);
        }
      }
    }

    return dist[dst] < double.infinity;
  }

  /// Measures per-feed hazard-check overhead vs. idle (no hazards) baseline.
  static double _measureMultiFeedOverhead({
    required List<_OsrmRoute> routes,
    required List<RouteNode> hazardNodes,
    required VehicleType vehicleType,
    required int feedCount,
  }) {
    if (routes.isEmpty) return 0;

    final segments = <(LatLng, LatLng)>[];
    for (final route in routes) {
      for (var i = 0; i < route.points.length - 1; i++) {
        segments.add((route.points[i], route.points[i + 1]));
      }
    }
    if (segments.isEmpty) return 0;

    final idleSw = Stopwatch()..start();
    for (final (a, b) in segments) {
      _haversine(a, b);
    }
    idleSw.stop();

    final fullSw = Stopwatch()..start();
    for (final (a, b) in segments) {
      _segmentWeight(a, b, hazardNodes, vehicleType, null);
    }
    fullSw.stop();

    final deltaMs =
        (fullSw.elapsedMicroseconds - idleSw.elapsedMicroseconds) / 1000.0;
    final divisor = feedCount >= 3 ? 3 : max(feedCount, 1);
    return deltaMs / divisor;
  }

  /// True when the graph contains at least one ALERT-weighted edge.
  static bool _graphHasAlertEdges(List<List<_Edge>> adj) {
    for (final edges in adj) {
      for (final e in edges) {
        if (e.isAlert && e.weight.isFinite) return true;
      }
    }
    return false;
  }

  /// Validates that [routePoints] do not intersect any blocked OSM segment
  /// (DANGER or vehicle-impassable ALERT) from [hazardNodes]/[segmentsById].
  ///
  /// When a hazard has no resolvable OSM geometry (e.g. Overpass has no
  /// road within snapping distance of that camera), this falls back to a
  /// raw-coordinate proximity check using the same _detectRadiusM already
  /// used throughout graph construction — it does NOT refuse outright.
  /// Refusing unconditionally here would be stricter than the actual
  /// safety logic that already built and chose this route (which already
  /// has this same fallback), so an already-safe route could be needlessly
  /// discarded just because one unrelated hazard's road couldn't be
  /// resolved, even if the route never went anywhere near that hazard.
  static bool _validateRouteAgainstBlockedSegments(
    List<LatLng> routePoints,
    Map<String, RoadSegmentResult?>? segmentsById,
    List<RouteNode> hazardNodes,
    VehicleType vehicle,
  ) {
    if (routePoints.length < 2) return true;
    const overlapTol = 8.0;
    for (var i = 0; i < routePoints.length - 1; i++) {
      final a = routePoints[i];
      final b = routePoints[i + 1];
      final edge = [a, b];
      for (final hazard in hazardNodes) {
        final isCritical = hazard.status.toUpperCase() == 'DANGER' ||
            !hazard.isPassableFor(vehicle);
        if (!isCritical) continue;

        final seg = segmentsById != null ? segmentsById[hazard.id] : null;
        if (seg != null && seg.points.length >= 2) {
          final overlaps =
              GeoUtils.polylineOverlapsPolyline(edge, seg.points, overlapTol);
          if (overlaps) {
            print('[RouteValidation] Route edge $i intersects blocked segment ${hazard.id}');
            return false;
          }
          continue;
        }

        // No OSM geometry available for this critical hazard — fall back
        // to raw-coordinate distance, same radius used everywhere else.
        final d1 = GeoUtils.haversineM(a, hazard.location);
        final d2 = GeoUtils.haversineM(b, hazard.location);
        if (d1 <= _detectRadiusM || d2 <= _detectRadiusM) {
          print(
            '[RouteValidation] Route edge $i passes within ${_detectRadiusM}m '
            'of critical hazard ${hazard.id} with no OSM geometry available '
            '— rejecting.',
          );
          return false;
        }
      }
    }
    return true;
  }

  /// Confirms the rerouted path avoids segments that just became impassable.
  static bool _checkRerouteAccuracy({
    required List<Map<String, dynamic>> previousDocs,
    required List<Map<String, dynamic>> currentDocs,
    required List<LatLng> routePoints,
    required VehicleType vehicleType,
  }) {
    final previous = _seedNodes(previousDocs);
    final current = _seedNodes(currentDocs);

    final newlyImpassable = <RouteNode>[];
    for (final cur in current) {
      RouteNode? prev;
      for (final p in previous) {
        if (_haversine(p.location, cur.location) < 1.0) {
          prev = p;
          break;
        }
      }
      final wasPassable = prev == null || prev.isPassableFor(vehicleType);
      if (wasPassable && !cur.isPassableFor(vehicleType)) {
        newlyImpassable.add(cur);
      }
    }

    if (newlyImpassable.isEmpty) return true;
    return !_routeTouchesDanger(routePoints, newlyImpassable);
  }

  static void _addCrossLinks(
    List<LatLng> nodes,
    List<int> nodeRoute,
    List<RouteNode?> nodeHazard,
    VehicleType vehicle,
    void Function(int a, int b, double w, bool alert) link,
    List<RouteNode> hazardNodes,
    Map<String, RoadSegmentResult?>? segmentsById,
  ) {
    final cellDeg = _crossLinkRadiusM / 111320.0; // meters → degrees (approx)
    final grid = <String, List<int>>{};

    String cellKey(int gx, int gy) => '$gx:$gy';

    for (var i = 0; i < nodes.length; i++) {
      if (nodeRoute[i] < 0) continue; // skip endpoints (added later)
      final gx = (nodes[i].longitude / cellDeg).floor();
      final gy = (nodes[i].latitude / cellDeg).floor();
      grid.putIfAbsent(cellKey(gx, gy), () => <int>[]).add(i);
    }

    for (var i = 0; i < nodes.length; i++) {
      if (nodeRoute[i] < 0) continue;
      final gx = (nodes[i].longitude / cellDeg).floor();
      final gy = (nodes[i].latitude / cellDeg).floor();
      for (var dx = -1; dx <= 1; dx++) {
        for (var dy = -1; dy <= 1; dy++) {
          final bucket = grid[cellKey(gx + dx, gy + dy)];
          if (bucket == null) continue;
          for (final j in bucket) {
            if (j <= i) continue; // add each pair once
            if (nodeRoute[j] == nodeRoute[i]) continue; // only across candidates
            // Only allow a cross-candidate link when it's relevant to
            // navigating around a hazard. Without this, any two OSRM
            // alternatives that happen to run within _crossLinkRadiusM of
            // each other ANYWHERE on the map get a free "teleport" edge,
            // letting Dijkstra hop candidates for a trivial geometric
            // shortcut that isn't a real turn lane — producing unnecessary
            // turns/detours far from any flood. Escape/rejoin links near an
            // actual hazard are preserved: _computeVertexHazards flags every
            // vertex within _hazardPropagationM of a hazard on its own
            // candidate, so at least one side of a genuine escape link is
            // always non-null here.
            if (nodeHazard[i] == null && nodeHazard[j] == null) continue;
            final d = _haversine(nodes[i], nodes[j]);
            if (d > _crossLinkRadiusM) continue;
            final sw = _edgeWeightFromVertexHazards(
              nodes[i],
              nodes[j],
              nodeHazard[i],
              nodeHazard[j],
              vehicle,
              segmentsById,
              hazardNodes,
            );
            if (sw.weight.isFinite) link(i, j, sw.weight, sw.isAlert);
          }
        }
      }
    }
  }

  /// Ranks hazard severity so the more restrictive hazard wins where two
  /// hazards' propagation windows overlap the same vertex. DANGER always
  /// outranks ALERT; among ALERTs, higher water level (more restrictive,
  /// closer to blocking more vehicle types) wins.
  static double _hazardSeverity(RouteNode hazard) {
    if (hazard.status.toUpperCase() == 'DANGER') return double.infinity;
    return hazard.waterLevelM;
  }

  /// For one candidate route's densified polyline, determines which hazard
  /// (if any) affects each vertex, by finding each hazard's nearest vertex
  /// on this polyline (gated by [_detectRadiusM], same as the original
  /// point-radius check) and then propagating it up to
  /// [_hazardPropagationM] meters of arc length in both directions. This is
  /// what makes a flood affect the whole nearby road segment instead of
  /// only the exact camera coordinate.
  static List<RouteNode?> _computeVertexHazards(
    List<LatLng> densified,
    List<RouteNode> hazardNodes,
    Map<String, RoadSegmentResult?>? segmentsById,
  ) {
    final result = List<RouteNode?>.filled(densified.length, null);
    if (densified.isEmpty) return result;

    void mark(int idx, RouteNode hazard) {
      final existing = result[idx];
      if (existing == null ||
          _hazardSeverity(hazard) > _hazardSeverity(existing)) {
        result[idx] = hazard;
      }
    }

    for (final hazard in hazardNodes) {
      // Classify vertices two ways and take the union of both: by overlap
      // with the cached OSM segment (when available), AND by raw distance
      // to the camera's own coordinate with arc-length propagation. These
      // used to be mutually exclusive (segment match => skip the raw-
      // coordinate fallback entirely for this hazard), but that is unsafe:
      // RoadSegmentService can snap a camera to the wrong parallel road
      // (a documented limitation — two close roads can't be disambiguated
      // without camera bearing data). If that wrong segment happens to
      // cross this candidate route somewhere irrelevant, it sets
      // markedFromSeg=true and used to suppress ever checking the camera's
      // real coordinate against this route at all — silently missing a
      // genuine close pass elsewhere on the same route. mark() only ever
      // raises a vertex's severity, never lowers it, so running both
      // checks unconditionally is always safe (more conservative), never
      // redundant-but-wrong.
      final seg = segmentsById != null ? segmentsById[hazard.id] : null;
      var markedFromSeg = false;
      if (seg != null && seg.points.length >= 2) {
        for (var i = 0; i < densified.length; i++) {
          final proj = GeoUtils.nearestPointOnPolyline(densified[i], seg.points);
          final d = proj?.distanceM ?? double.infinity;
          if (d <= _detectRadiusM) {
            mark(i, hazard);
            markedFromSeg = true;
          }
        }
        if (markedFromSeg) {
          print('ℹ️ [RoutePlanner] Using cached OSM segment for ${hazard.id} to mark ${densified.length} vertices');
        }
      }

      // ALWAYS also check the hazard's raw coordinate against this route,
      // regardless of whether the segment-based check above matched
      // anything. This is the fallback used when OSM topology/geometry is
      // unavailable, but it also acts as a safety net against a wrong-road
      // segment match.
      var nearestIdx = 0;
      var nearestDist = double.infinity;
      for (var i = 0; i < densified.length; i++) {
        final d = GeoUtils.haversineM(densified[i], hazard.location);
        if (d < nearestDist) {
          nearestDist = d;
          nearestIdx = i;
        }
      }
      if (nearestDist > _detectRadiusM) continue;

      mark(nearestIdx, hazard);

      var accumulated = 0.0;
      for (var i = nearestIdx; i > 0; i--) {
        accumulated += GeoUtils.haversineM(densified[i], densified[i - 1]);
        if (accumulated > _hazardPropagationM) break;
        mark(i - 1, hazard);
      }

      accumulated = 0.0;
      for (var i = nearestIdx; i < densified.length - 1; i++) {
        accumulated += GeoUtils.haversineM(densified[i], densified[i + 1]);
        if (accumulated > _hazardPropagationM) break;
        mark(i + 1, hazard);
      }
    }

    return result;
  }

  /// Edge weight derived from precomputed per-vertex hazard assignments
  /// (see [_computeVertexHazards]), replacing the old 3-point-sample radius
  /// check for polyline-internal and cross-candidate edges. Same
  /// `(weight, isAlert)` contract as [_segmentWeight].
  static _SegWeight _edgeWeightFromVertexHazards(
    LatLng a,
    LatLng b,
    RouteNode? hazardA,
    RouteNode? hazardB,
    VehicleType vehicle,
    Map<String, RoadSegmentResult?>? segmentsById,
    List<RouteNode> hazardNodes,
  ) {
    final base = _haversine(a, b);

    // First: check full OSM segment overlaps against all hazards when
    // available. If an OSRM edge geometry overlaps a DANGER or vehicle-
    // impassable ALERT segment, it must be blocked.
    //
    // IMPORTANT: we must inspect every overlapping hazard before deciding,
    // not return on the first match. A single short edge can overlap more
    // than one hazard's road segment (e.g. an ALERT camera and a DANGER
    // camera on the same stretch of road). If we returned as soon as we
    // found the ALERT match, a DANGER hazard appearing later in
    // [hazardNodes] would never be checked, and the edge would incorrectly
    // stay "passable with penalty" instead of being hard-blocked — letting
    // routes cross a red/DANGER zone. So: scan all overlapping hazards,
    // block immediately on any hard block, and only fall back to the ALERT
    // penalty once we know none of them block.
    const overlapTol = 8.0; // meters
    RouteNode? worstOverlappingAlert;
    for (final hazard in hazardNodes) {
      final seg = segmentsById != null ? segmentsById[hazard.id] : null;
      if (seg == null || seg.points.length < 2) continue;
      final overlaps = GeoUtils.polylineOverlapsPolyline([a, b], seg.points, overlapTol);
      if (!overlaps) continue;
      // Overlaps a known OSM segment for this hazard.
      if (!hazard.isPassableFor(vehicle) || hazard.status.toUpperCase() == 'DANGER') {
        print('[RouteSafety] OSRM edge overlaps BLOCKED OSM segment ${hazard.id} (way=${seg.wayId})');
        return const _SegWeight(double.infinity, false);
      }
      if (hazard.status.toUpperCase() == 'ALERT') {
        if (worstOverlappingAlert == null ||
            _hazardSeverity(hazard) > _hazardSeverity(worstOverlappingAlert)) {
          worstOverlappingAlert = hazard;
        }
      }
    }
    if (worstOverlappingAlert != null) {
      print('[RouteSafety] OSRM edge overlaps ALERT OSM segment ${worstOverlappingAlert.id} — applying penalty');
      return _SegWeight(base * _alertPenalty, true);
    }

    // No overlapping OSM segment found — fall back to vertex-based hazard
    // mapping previously used.
    RouteNode? worst;
    if (hazardA != null && hazardB != null) {
      worst = _hazardSeverity(hazardA) >= _hazardSeverity(hazardB) ? hazardA : hazardB;
    } else {
      worst = hazardA ?? hazardB;
    }
    if (worst == null) return _SegWeight(base, false);
    if (!worst.isPassableFor(vehicle)) {
      print('⚠️ [RoutePlanner] DANGER/ALERT segment BLOCKED: ${worst.id} vehicle=${vehicle.label} water=${worst.waterLevelM}');
      return const _SegWeight(double.infinity, false);
    }
    print('⚠️ [RoutePlanner] ALERT segment ALLOWED with penalty: ${worst.id} water=${worst.waterLevelM} vehicle=${vehicle.label}');
    return _SegWeight(base * _alertPenalty, true);
  }

  /// Computes the cost of travelling between two points. Returns an infinite
  /// weight (a hard block) if the segment grazes an impassable flood point.
  static _SegWeight _segmentWeight(
    LatLng a,
    LatLng b,
    List<RouteNode> hazards,
    VehicleType vehicle,
    Map<String, RoadSegmentResult?>? segmentsById,
  ) {
    final base = _haversine(a, b);
    var weight = base;
    var isAlert = false;

    // First check full OSM segment overlaps when available.
    const overlapTol = 8.0;
    for (final n in hazards) {
      final seg = segmentsById != null ? segmentsById[n.id] : null;
      if (seg != null && seg.points.length >= 2) {
        final overlaps = GeoUtils.polylineOverlapsPolyline([a, b], seg.points, overlapTol);
        if (overlaps) {
          if (!n.isPassableFor(vehicle) || n.status.toUpperCase() == 'DANGER') {
            print('[RouteSafety] _segmentWeight BLOCKED by ${n.id} (way=${seg.wayId})');
            return const _SegWeight(double.infinity, false);
          }
          if (n.status.toUpperCase() == 'ALERT') {
            weight = base * _alertPenalty;
            isAlert = true;
            print('[RouteSafety] _segmentWeight ALERT penalty by ${n.id}');
          }
          // If we've handled this segment, continue to next hazard
          continue;
        }
      }
    }

    // Fallback to midpoint radius check when OSM geometry unavailable.
    final mid = LatLng(
      (a.latitude + b.latitude) / 2,
      (a.longitude + b.longitude) / 2,
    );
    for (final n in hazards) {
      final d = [
        _haversine(a, n.location),
        _haversine(b, n.location),
        _haversine(mid, n.location),
      ].reduce(min);

      if (d <= _detectRadiusM) {
        if (!n.isPassableFor(vehicle)) {
          print('⚠️ [RoutePlanner] _segmentWeight BLOCKED by ${n.id} water=${n.waterLevelM} vehicle=${vehicle.label}');
          return const _SegWeight(double.infinity, false);
        }
        if (n.status.toUpperCase() == 'ALERT') {
          weight = base * _alertPenalty;
          isAlert = true;
          print('⚠️ [RoutePlanner] _segmentWeight ALERT penalty by ${n.id} water=${n.waterLevelM} vehicle=${vehicle.label}');
        }
      }
    }
    return _SegWeight(weight, isAlert);
  }

  /// Classic Dijkstra shortest path with alert-flag propagation.
  static _DijkstraResult? _dijkstra(List<List<_Edge>> adj, int src, int dst) {
    final n = adj.length;
    final prev = List<int>.filled(n, -1);
    final dist = List<_Cost>.filled(n, _Cost._infty);
    // initial node: safety 0, time 0, distance 0
    dist[src] = const _Cost(0, 0.0, 0.0);

    final heap = _MinHeapCost();
    heap.add(dist[src], src);

    // assumed travel speed (m/s) for converting distance to time
    const double speedMps = 8.33; // ~30 km/h fallback

    while (!heap.isEmpty) {
      final (cost, u) = heap.removeMin();
      // skip stale heap entries
      if (cost.compareTo(dist[u]) != 0) continue;
      if (u == dst) break;

      for (final e in adj[u]) {
        if (!e.weight.isFinite) continue;
        // e.weight is potentially already penalized (alert multiplier applied)
        final edgePenalizedDistance = e.weight;
        final edgeBaseDistance = e.isAlert ? (e.weight / _alertPenalty) : e.weight;
        final edgeTimeSec = edgePenalizedDistance / speedMps;
        final newSafety = dist[u].safetyLevel == 1 || e.isAlert ? 1 : 0;
        final newTime = dist[u].timeSec + edgeTimeSec;
        final newDist = dist[u].distanceM + edgeBaseDistance;

        final newCost = _Cost(newSafety, newTime, newDist);
        if (newCost.compareTo(dist[e.to]) < 0) {
          dist[e.to] = newCost;
          prev[e.to] = u;
          heap.add(newCost, e.to);
        }
      }
    }

    if (dist[dst].timeSec == double.infinity) return null;

    final path = <int>[];
    var current = dst;
    while (current != -1) {
      path.insert(0, current);
      current = prev[current];
    }
    final hasAlert = dist[dst].safetyLevel == 1;
    // Return travel-time (seconds) as cost for compatibility with logs.
    return _DijkstraResult(path, dist[dst].timeSec, hasAlert);
  }

  /// Fetches OSRM candidate routes (primary + alternatives) as geometry lists.
  static Future<List<_OsrmRoute>> _fetchOsrmRoutes(
    LatLng origin,
    LatLng destination,
  ) async {
    try {
      final coords =
          '${_formatCoordinate(origin)};${_formatCoordinate(destination)}';
      final uri = Uri.parse(
        'https://router.project-osrm.org/route/v1/driving/$coords'
        '?overview=full&geometries=geojson&alternatives=3',
      );

      final response = await http.get(uri).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return const [];

      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final routes = body['routes'] as List<dynamic>?;
      if (routes == null || routes.isEmpty) return const [];

      final out = <_OsrmRoute>[];
      for (final r in routes) {
        final geometry = r['geometry'] as Map<String, dynamic>?;
        final coordinates = geometry?['coordinates'] as List<dynamic>?;
        if (coordinates == null || coordinates.isEmpty) continue;

        final pts = <LatLng>[];
        for (final c in coordinates) {
          if (c is! List || c.length < 2) continue;
          final lng = (c[0] as num).toDouble();
          final lat = (c[1] as num).toDouble();
          if (lat.abs() > 90 || lng.abs() > 180) continue;
          pts.add(LatLng(lat, lng));
        }
        if (pts.length < 2) continue;

        final dist = (r['distance'] as num?)?.toDouble() ?? 0;
        final dur = (r['duration'] as num?)?.toDouble() ?? 0;
        out.add(_OsrmRoute(pts, dist, dur));
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// Buffers a hazard's road geometry (or a single point, if no OSM
  /// geometry is available) into an axis-aligned rectangular polygon
  /// expanded by [bufferM] meters in every direction.
  ///
  /// This is deliberately simple rather than a precise polyline buffer —
  /// a slightly generous rectangular avoid-zone around a flooded/blocked
  /// road is the conservative, safe choice here, and a rectangle is always
  /// a valid, non-self-intersecting polygon regardless of the input
  /// geometry's shape, which matters because a malformed polygon would
  /// simply be rejected by Valhalla rather than degrade gracefully.
  static List<List<double>> _bufferToPolygon(
    List<LatLng> points,
    double bufferM,
  ) {
    if (points.isEmpty) return const [];
    var minLat = points.first.latitude, maxLat = points.first.latitude;
    var minLng = points.first.longitude, maxLng = points.first.longitude;
    for (final p in points) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    final midLatRad = ((minLat + maxLat) / 2) * pi / 180.0;
    final latPad = bufferM / 111320.0;
    final lngScale = cos(midLatRad).abs().clamp(0.05, 1.0);
    final lngPad = bufferM / (111320.0 * lngScale);

    final swLat = minLat - latPad, neLat = maxLat + latPad;
    final swLng = minLng - lngPad, neLng = maxLng + lngPad;

    // Valhalla expects [lon, lat] pairs; ring must be closed (first point
    // repeated as the last point).
    return [
      [swLng, swLat],
      [neLng, swLat],
      [neLng, neLat],
      [swLng, neLat],
      [swLng, swLat],
    ];
  }

  /// Requests a route from Valhalla's public routing service, computed
  /// against the full road network while explicitly excluding every
  /// currently-blocked road (see the call site in planRoute() for why this
  /// matters and how it differs from the OSRM-based candidates/detours).
  ///
  /// Uses Valhalla's public community demo server — like OSRM's public
  /// demo already used elsewhere in this file, this is shared and best-
  /// effort, not something to depend on for production/life-safety use
  /// without self-hosting. A failure here just means this extra candidate
  /// is unavailable for this request.
  static Future<_OsrmRoute?> _fetchValhallaAvoidRoute({
    required LatLng origin,
    required LatLng destination,
    required List<RouteNode> avoidableNodes,
    required Map<String, RoadSegmentResult?> segmentsById,
  }) async {
    try {
      const bufferM = 25.0; // safety margin around each blocked road
      final polygons = <List<List<double>>>[];
      for (final node in avoidableNodes) {
        final seg = segmentsById[node.id];
        final points = (seg != null && seg.points.length >= 2)
            ? seg.points
            : [node.location];
        final poly = _bufferToPolygon(points, bufferM);
        if (poly.isNotEmpty) polygons.add(poly);
      }
      if (polygons.isEmpty) return null;

      // Defensive cap: Valhalla limits total exclude_polygons vertices per
      // request. A very large flood event shouldn't produce an oversized
      // request that gets rejected outright — better to exclude the most
      // relevant hazards than none at all.
      final limitedPolygons =
          polygons.length > 50 ? polygons.sublist(0, 50) : polygons;

      final body = jsonEncode({
        'locations': [
          {'lat': origin.latitude, 'lon': origin.longitude},
          {'lat': destination.latitude, 'lon': destination.longitude},
        ],
        'costing': 'auto',
        'exclude_polygons': limitedPolygons,
      });

      final uri = Uri.parse('https://valhalla1.openstreetmap.de/route');
      final response = await http
          .post(uri, headers: {'Content-Type': 'application/json'}, body: body)
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        print('[RouteSafety] Valhalla avoid-route request failed: HTTP ${response.statusCode}');
        return null;
      }

      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final trip = decoded['trip'] as Map<String, dynamic>?;
      if (trip == null) return null;
      final legs = trip['legs'] as List<dynamic>?;
      if (legs == null || legs.isEmpty) return null;

      final pts = <LatLng>[];
      for (final leg in legs) {
        final shape = (leg as Map<String, dynamic>)['shape'] as String?;
        if (shape == null) continue;
        pts.addAll(_decodePolyline6(shape));
      }
      if (pts.length < 2) return null;

      // Sanity-check the decoded geometry before trusting it. A legitimate
      // in-city route never has a multi-kilometer gap between two
      // consecutive shape points; a jump like that means the polyline was
      // decoded incorrectly (or the response was malformed) rather than
      // describing a real road. Feeding that into the graph would let
      // GeoUtils.densify() try to interpolate an enormous number of points
      // between the two ends of that "gap" — freezing the app. Reject the
      // whole route here instead of letting a bad point slip through.
      const maxPlausibleGapM = 5000.0;
      for (var i = 0; i < pts.length - 1; i++) {
        final gap = GeoUtils.haversineM(pts[i], pts[i + 1]);
        if (gap > maxPlausibleGapM) {
          print(
            '[RouteSafety] Valhalla avoid-route rejected: implausible '
            '${gap.toStringAsFixed(0)}m gap between consecutive points '
            '(likely a decode/response error) — discarding this candidate.',
          );
          return null;
        }
      }

      final summary = trip['summary'] as Map<String, dynamic>?;
      final lengthKm = (summary?['length'] as num?)?.toDouble() ?? 0.0;
      final durationSec = (summary?['time'] as num?)?.toDouble() ?? 0.0;

      print('[RouteSafety] Valhalla avoid-route succeeded, excluding ${polygons.length} blocked-road polygon(s)');
      return _OsrmRoute(pts, lengthKm * 1000.0, durationSec);
    } catch (e) {
      print('[RouteSafety] Valhalla avoid-route request errored: $e');
      return null;
    }
  }

  /// Decodes a Valhalla polyline6-encoded shape string into LatLng points.
  /// Valhalla encodes with 6 decimal places of precision (Google's
  /// standard polyline algorithm uses 5), so a generic polyline5 decoder
  /// would silently produce wrong coordinates rather than fail loudly.
  static List<LatLng> _decodePolyline6(String encoded) {
    final points = <LatLng>[];
    var index = 0, lat = 0, lng = 0;
    while (index < encoded.length) {
      var result = 0, shift = 0;
      int b;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      final dlat = (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
      lat += dlat;

      result = 0;
      shift = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      final dlng = (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
      lng += dlng;

      points.add(LatLng(lat / 1e6, lng / 1e6));
    }
    return points;
  }

  /// Returns the impassable flood nodes that any candidate route passes near.
  static List<RouteNode> _dangersNearCandidates(
    List<_OsrmRoute> routes,
    List<RouteNode> impassable,
    double radiusM, {
    Map<String, RoadSegmentResult?>? segmentsById,
  }) {
    // Densify each OSRM candidate before testing proximity so hazards that
    // fall in the interior of long OSRM edges are detected reliably.
    //
    // IMPORTANT: check against the hazard's real OSM road-segment geometry
    // (when available) first, not just its raw camera coordinate. The
    // graph-building phase (_computeVertexHazards) marks a route as
    // affected by a hazard whenever it comes within [radiusM] of that
    // hazard's actual road polyline — which can extend well beyond the
    // camera's exact point. If this function only checked the raw
    // coordinate, a detour could be accepted here as "clear" while still
    // crossing the real road segment, only to be blocked once graph
    // construction ran its more accurate check — wasting the accepted
    // detour and potentially leaving no safe path at all.
    final found = <RouteNode>[];
    for (final node in impassable) {
      var near = false;
      final seg = segmentsById != null ? segmentsById[node.id] : null;
      for (final route in routes) {
        // densify route to ensure we sample interior points on long straights
        final dens = GeoUtils.densify(route.points, _maxEdgeLengthM);
        if (seg != null && seg.points.length >= 2) {
          for (final p in dens) {
            final proj = GeoUtils.nearestPointOnPolyline(p, seg.points);
            if ((proj?.distanceM ?? double.infinity) <= radiusM) {
              near = true;
              break;
            }
          }
        }
        if (!near) {
          for (final p in dens) {
            if (_haversine(p, node.location) <= radiusM) {
              near = true;
              break;
            }
          }
        }
        if (near) break;
      }
      if (near) {
        found.add(node);
        print('[RouteSafety] Candidate routes pass near hazard ${node.id} status=${node.status} water=${node.waterLevelM}');
      }
    }
    return found;
  }

  /// Hazards within this many meters of each other are treated as one
  /// cluster when generating detour waypoints, so a corridor with several
  /// nearby cameras gets ONE wide detour around the whole affected stretch
  /// instead of several tightly-spaced offset points that no real road can
  /// thread between.
  static const double _hazardClusterRadiusM = 300.0;

  /// Requests detour routes that steer around the given danger points by
  /// injecting offset waypoints, then asking OSRM to route through them.
  ///
  /// Escalates through a widening range of offsets and tries both sides of
  /// the direct path explicitly, stopping as soon as a candidate is
  /// confirmed (via [avoidableNodes]) to clear every impassable hazard.
  /// This matters because if no detour here ever clears the hazards,
  /// planRoute() has no safe graph edges to route through at all — Dijkstra
  /// returns null, and the caller falls back to showing the raw, unsafe
  /// OSRM route. Trying harder here is the difference between a genuine
  /// safe (if longer) route and an unsafe one being shown to the user.
  ///
  /// The offset list intentionally reaches much farther than a typical
  /// in-city detour (up to 12km) because a large or elongated hazard
  /// cluster can require going most of the way around a river/floodplain
  /// via a bridge/crossing that is genuinely far from the direct
  /// origin-destination line — see planRoute() callers' notes on why a
  /// perpendicular offset that stops too early makes a real, if longer,
  /// safe route invisible even when one exists.
  static Future<List<_OsrmRoute>> _fetchDetourRoutes({
    required LatLng origin,
    required LatLng destination,
    required List<RouteNode> dangers,
    required List<RouteNode> avoidableNodes,
    Map<String, RoadSegmentResult?>? segmentsById,
  }) async {
    final results = <_OsrmRoute>[];
    final bearing = _bearing(origin, destination);
    final clusters = _clusterHazards(dangers, _hazardClusterRadiusM);

    const offsetsKm = [0.3, 0.6, 1.0, 1.5, 2.2, 3.0, 4.5, 6.5, 9.0, 12.0];

    for (final offsetKm in offsetsKm) {
      for (final sideSign in [1, -1]) {
        final waypoints = <LatLng>[];
        for (final cluster in clusters) {
          final center = _clusterCentroid(cluster);
          // Push the waypoint out far enough to clear the offset AND the
          // cluster's own spread — a tight point-offset from a cluster's
          // centroid can still land inside the cluster's outer members.
          final spreadM = _clusterMaxRadiusM(cluster, center);
          final effectiveOffsetKm = offsetKm + (spreadM / 1000.0);
          waypoints.add(
            _offsetPoint(center, bearing + (90 * sideSign), effectiveOffsetKm),
          );
        }
        waypoints.sort(
          (a, b) => _haversine(origin, a).compareTo(_haversine(origin, b)),
        );

        final route = await _fetchOsrmViaWaypoints(origin, destination, waypoints);
        if (route == null) continue;

        // Validated against real road-segment geometry when available (see
        // _dangersNearCandidates) — not just the hazard's raw coordinate —
        // so a route accepted here is confirmed clear by the same standard
        // graph construction will apply, instead of being re-blocked later.
        final stillNear = _dangersNearCandidates(
          [route],
          avoidableNodes,
          _detectRadiusM,
          segmentsById: segmentsById,
        );
        final sideLabel = sideSign > 0 ? 'left' : 'right';
        if (stillNear.isEmpty) {
          print('[RouteSafety] Detour cleared all hazards at offset=${offsetKm}km side=$sideLabel');
          results.add(route);
        } else {
          print(
            '[RouteSafety] Detour attempt offset=${offsetKm}km side=$sideLabel '
            'still near: ${stillNear.map((h) => h.id).join(', ')}',
          );
        }
      }
      // Stop escalating once at least one fully clear detour exists — no
      // need to keep hammering OSRM once a safe alternative is available.
      if (results.isNotEmpty) break;
    }

    if (results.isEmpty) {
      print(
        '[RouteSafety] No detour offset up to ${offsetsKm.last}km cleared all '
        'hazards for ${dangers.map((d) => d.id).join(', ')} — no safe '
        'alternative could be constructed.',
      );
    }

    return results;
  }

  /// Groups hazards into clusters where every member is within
  /// [radiusM] of at least one other member of the same cluster
  /// (single-linkage clustering). Used so a stretch of road with several
  /// nearby cameras gets one combined detour instead of one per camera.
  static List<List<RouteNode>> _clusterHazards(
    List<RouteNode> hazards,
    double radiusM,
  ) {
    final clusters = <List<RouteNode>>[];
    for (final h in hazards) {
      List<RouteNode>? joined;
      for (final cluster in clusters) {
        final closeToCluster = cluster.any(
          (member) => _haversine(member.location, h.location) <= radiusM,
        );
        if (closeToCluster) {
          joined = cluster;
          break;
        }
      }
      if (joined != null) {
        joined.add(h);
      } else {
        clusters.add([h]);
      }
    }
    return clusters;
  }

  /// Simple average-position centroid of a hazard cluster.
  static LatLng _clusterCentroid(List<RouteNode> cluster) {
    var lat = 0.0, lng = 0.0;
    for (final h in cluster) {
      lat += h.location.latitude;
      lng += h.location.longitude;
    }
    return LatLng(lat / cluster.length, lng / cluster.length);
  }

  /// Farthest distance (meters) from [center] to any member of [cluster].
  static double _clusterMaxRadiusM(List<RouteNode> cluster, LatLng center) {
    var maxDist = 0.0;
    for (final h in cluster) {
      final d = _haversine(center, h.location);
      if (d > maxDist) maxDist = d;
    }
    return maxDist;
  }

  /// Fetches a single OSRM route that passes through the given intermediate
  /// waypoints (in order).
  static Future<_OsrmRoute?> _fetchOsrmViaWaypoints(
    LatLng origin,
    LatLng destination,
    List<LatLng> waypoints,
  ) async {
    try {
      final all = <LatLng>[origin, ...waypoints, destination];
      final coords = all.map(_formatCoordinate).join(';');
      final uri = Uri.parse(
        'https://router.project-osrm.org/route/v1/driving/$coords'
        '?overview=full&geometries=geojson&alternatives=false',
      );
      final response = await http.get(uri).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return null;

      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final routes = body['routes'] as List<dynamic>?;
      if (routes == null || routes.isEmpty) return null;

      final geometry = routes.first['geometry'] as Map<String, dynamic>?;
      final coordinates = geometry?['coordinates'] as List<dynamic>?;
      if (coordinates == null || coordinates.isEmpty) return null;

      final pts = <LatLng>[];
      for (final c in coordinates) {
        if (c is! List || c.length < 2) continue;
        final lng = (c[0] as num).toDouble();
        final lat = (c[1] as num).toDouble();
        if (lat.abs() > 90 || lng.abs() > 180) continue;
        pts.add(LatLng(lat, lng));
      }
      if (pts.length < 2) return null;

      final dist = (routes.first['distance'] as num?)?.toDouble() ?? 0;
      final dur = (routes.first['duration'] as num?)?.toDouble() ?? 0;
      return _OsrmRoute(pts, dist, dur);
    } catch (_) {
      return null;
    }
  }

  /// Offsets a point by [distanceKm] along the given [bearingDeg].
  static LatLng _offsetPoint(
    LatLng point,
    double bearingDeg,
    double distanceKm,
  ) {
    const earthRadiusKm = 6371.0;
    final bearingRad = bearingDeg * pi / 180.0;
    final latRad = point.latitude * pi / 180.0;
    final lngRad = point.longitude * pi / 180.0;
    final newLat = latRad + (distanceKm / earthRadiusKm) * cos(bearingRad);
    final newLng =
        lngRad + (distanceKm / (earthRadiusKm * cos(latRad))) * sin(bearingRad);
    return LatLng(newLat * 180.0 / pi, newLng * 180.0 / pi);
  }

  /// Initial bearing (degrees) from [a] to [b].
  static double _bearing(LatLng a, LatLng b) {
    final lat1 = a.latitude * pi / 180.0;
    final lat2 = b.latitude * pi / 180.0;
    final dLng = (b.longitude - a.longitude) * pi / 180.0;
    final y = sin(dLng) * cos(lat2);
    final x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLng);
    return (atan2(y, x) * 180.0 / pi + 360.0) % 360.0;
  }

  /// Minimum distance (meters) from [point] to any of [nodes].
  static double _minDistanceToNodes(LatLng point, List<RouteNode> nodes) {
    var minDist = double.infinity;
    for (final n in nodes) {
      final d = _haversine(point, n.location);
      if (d < minDist) minDist = d;
    }
    return minDist;
  }

  static String _formatCoordinate(LatLng point) {
    return '${point.longitude.toStringAsFixed(6)},${point.latitude.toStringAsFixed(6)}';
  }

  /// Extracts a stable string identifier for a CCTV document.
  ///
  /// IMPORTANT: this must be based on the document's own database identity
  /// (_id), never on its position in the docs list. An index-based ID
  /// (e.g. 'c${index+1}') silently reassigns every camera's "identity"
  /// whenever a document is added, removed, or reordered upstream —
  /// deleting one camera would make the next camera in the list inherit
  /// its old label. That breaks anyone reasoning about "camera cN" across
  /// two points in time (a person reading logs, or _checkRerouteAccuracy
  /// comparing previousDocs vs currentDocs camera-by-camera), because the
  /// label no longer reliably points at the same physical camera.
  static String _stableCctvId(Map<String, dynamic> doc, int fallbackIndex) {
    final rawId = doc['_id'];
    if (rawId is String && rawId.isNotEmpty) return rawId;
    if (rawId is Map && rawId[r'$oid'] is String) {
      return rawId[r'$oid'] as String;
    }
    final altId = doc['id'] ?? doc['camera_id'] ?? doc['cctv_id'];
    if (altId is String && altId.isNotEmpty) return altId;
    // Fallback only if the document truly has no stable identifier at all
    // (shouldn't happen for a real MongoDB document, which always has an
    // _id) — flagged loudly since this reintroduces the reshuffling risk.
    print(
      '⚠️ [RoutePlanner] CCTV doc at index $fallbackIndex has no _id/id/'
      'camera_id field — falling back to a positional ID, which will NOT '
      'stay stable if the document list is ever reordered or another '
      'document is added/removed.',
    );
    return 'idx$fallbackIndex';
  }

  static List<RouteNode> _seedNodes(List<Map<String, dynamic>> docs) {
    return docs.asMap().entries.map((entry) {
      final index = entry.key;
      final doc = entry.value;
      final coordinates = doc['location']['coordinates'] as List<dynamic>;
      final longitude = coordinates[0] as num;
      final latitude = coordinates[1] as num;
      final status = (doc['status'] as String).toUpperCase();
      final waterLevelM = (doc['water_level'] as num).toDouble();
      final stableId = _stableCctvId(doc, index);

      return RouteNode(
        id: stableId,
        name: 'CCTV-${(index + 1).toString().padLeft(2, '0')}',
        roadName: 'CCTV node ${index + 1}',
        location: LatLng(latitude.toDouble(), longitude.toDouble()),
        status: status,
        waterLevelM: waterLevelM,
        connectedIds: const [],
      );
    }).toList();
  }

  static double _sumMeters(List<LatLng> points) {
    var total = 0.0;
    for (var i = 1; i < points.length; i++) {
      total += _haversine(points[i - 1], points[i]);
    }
    return total;
  }

  /// Great-circle distance between two points, in meters.
  static double _haversine(LatLng a, LatLng b) {
    const earthRadiusM = 6371000.0;
    final lat1 = a.latitude * pi / 180.0;
    final lat2 = b.latitude * pi / 180.0;
    final dLat = (b.latitude - a.latitude) * pi / 180.0;
    final dLng = (b.longitude - a.longitude) * pi / 180.0;

    final h = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1) * cos(lat2) * sin(dLng / 2) * sin(dLng / 2);
    return earthRadiusM * 2 * atan2(sqrt(h), sqrt(1 - h));
  }
}