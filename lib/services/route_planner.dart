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
enum VehicleType { bicycle, motorcycle, sedan, suv, truck }

extension VehicleTypeLabel on VehicleType {
  String get label {
    switch (this) {
      case VehicleType.bicycle:
        return 'Bicycle';
      case VehicleType.motorcycle:
        return 'Motorcycle';
      case VehicleType.sedan:
        return 'Sedan / Car';
      case VehicleType.suv:
        return 'SUV / Van';
      case VehicleType.truck:
        return 'Truck / Bus';
    }
  }

  /// Maximum flood water depth (in meters) this vehicle type can safely pass.
  double get maxWaterLevelM {
    switch (this) {
      case VehicleType.bicycle:
        return 0.15;
      case VehicleType.motorcycle:
        return 0.25;
      case VehicleType.sedan:
        return 0.40;
      case VehicleType.suv:
        return 0.65;
      case VehicleType.truck:
        return 0.90;
    }
  }

  IconData get icon {
    switch (this) {
      case VehicleType.bicycle:
        return Icons.pedal_bike;
      case VehicleType.motorcycle:
        return Icons.two_wheeler;
      case VehicleType.sedan:
        return Icons.directions_car;
      case VehicleType.suv:
        return Icons.airport_shuttle;
      case VehicleType.truck:
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
  static const double _detectRadiusM = 80.0;

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
    final pathGenStopwatch = Stopwatch()..start();
    var dbFetchTime = Duration.zero;
    var osrmFetchTime = Duration.zero;
    var graphConstructionTime = Duration.zero;
    var dijkstraTime = Duration.zero;

    // 1. Fetch live CCTV flood data from MongoDB via the backend API.
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

    // 2. Fetch OSRM candidate routes (primary + alternatives).
    final osrmStopwatch = Stopwatch()..start();
    final routes = <_OsrmRoute>[...await _fetchOsrmRoutes(origin, destination)];
    if (routes.isEmpty) {
      pathGenStopwatch.stop();
      _emitRoutingLog(
        origin: origin,
        destination: destination,
        context: context,
        pathGenerationLatency: pathGenStopwatch.elapsed,
        graphConstructionTime: graphConstructionTime,
        dbFetchTime: dbFetchTime,
        osrmFetchTime: osrmStopwatch.elapsed,
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
    //     genuinely safe candidate to choose.
    final dangersOnRoute =
        _dangersNearCandidates(routes, avoidableNodes, 120.0);
    if (dangersOnRoute.isNotEmpty) {
      final detours = await _fetchDetourRoutes(
        origin: origin,
        destination: destination,
        dangers: dangersOnRoute,
      );
      // Only include detours that do not still intersect the impassable
      // danger nodes we are trying to avoid.
      for (final d in detours) {
        final stillNear = _dangersNearCandidates([d], avoidableNodes, 120.0);
        if (stillNear.isEmpty) routes.add(d);
      }
    }
    osrmStopwatch.stop();
    osrmFetchTime = osrmStopwatch.elapsed;

    // 3–5. Build one merged graph from all candidates. Attempt to fetch
    // RoadSegment geometry for hazards so vertex-hazard checks can use the
    // actual road polyline where available; fall back to point-distance if
    // Overpass/segment lookup fails or is missing.
    final graphStopwatch = Stopwatch()..start();
    final Map<String, RoadSegmentResult?> segmentsById = {};
    try {
      // Batch fetch segments for all hazard nodes in one Overpass bbox
      // query to reuse cached geometry and avoid many individual requests.
      final idToCoord = {
        for (final n in hazardNodes) n.id: n.location,
      };
      final fetched = await RoadSegmentService.getSegmentsForCoordinates(idToCoord);
      for (final n in hazardNodes) {
        segmentsById[n.id] = fetched[n.id];
      }
    } catch (e) {
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

    // 7a. No fully-safe path survives the flood blocks. Rather than fail
    //     silently, fall back to the primary OSRM route so the user still sees
    //     a line, but flag it clearly as not safe.
    if (dijkstra == null) {
      final fallback = routes.first.points;
      final fbDistM = _sumMeters(fallback);
      final fbSpeed = routes.first.durationSeconds > 0
          ? routes.first.distanceMeters / routes.first.durationSeconds
          : 8.33;
      final fbKm = fbDistM / 1000.0;
      final fbMin = (fbSpeed > 0 ? fbDistM / fbSpeed : 0.0) / 60.0;
      pathGenStopwatch.stop();

      _emitRoutingLog(
        origin: origin,
        destination: destination,
        context: context,
        pathGenerationLatency: pathGenStopwatch.elapsed,
        graphConstructionTime: graphConstructionTime,
        dbFetchTime: dbFetchTime,
        osrmFetchTime: osrmFetchTime,
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
        dijkstraPath: const [],
        routePoints: fallback,
        distanceKm: fbKm,
        durationMinutes: fbMin,
        chosenHasAlert: true,
      );

      return RoutePlanResult(
        path: [originNode, destinationNode],
        distanceKm: fbKm,
        durationMinutes: fbMin,
        avoidedNodes: avoidableNodes,
        polyline: fallback,
        summary:
            '${fbKm.toStringAsFixed(1)} km · ${RoutePlanResult.formatEta(fbMin)}',
        isFullySafe: false,
        warningMessage:
            'No fully safe route found for your vehicle. Showing the best available route — flooded areas may be present. Proceed with extreme caution.',
      );
    }
    // 7b. Assemble the winning polyline and derived metrics.
    final routePoints = dijkstra.path.map((i) => nodes[i]).toList();

    // Final validation: ensure resulting route does NOT intersect any
    // blocked OSM segment for the selected vehicle (defensive check).
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
        osrmFetchTime: osrmFetchTime,
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
      osrmFetchTime: osrmFetchTime,
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
        var replaced = false;
        for (final hazard in hazardNodes) {
          final seg = segmentsById != null ? segmentsById[hazard.id] : null;
          if (seg == null || seg.points.length < 2) continue;
          final overlaps = GeoUtils.polylineOverlapsPolyline([a, b], seg.points, overlapTol);
          if (!overlaps) continue;
          // If hazard blocks this vehicle, make infinite
          if (!hazard.isPassableFor(vehicleType) || hazard.status.toUpperCase() == 'DANGER') {
            adj[u][k] = _Edge(e.to, double.infinity, e.isAlert);
            replaced = true;
            print('[RouteSafety] Edge $u->${e.to} BLOCKED by ${hazard.id} (way=${seg.wayId})');
            break;
          }
          // Otherwise an ALERT applies: penalize
          if (hazard.status.toUpperCase() == 'ALERT') {
            final base = _haversine(a, b);
            adj[u][k] = _Edge(e.to, base * _alertPenalty, true);
            replaced = true;
            print('[RouteSafety] Edge $u->${e.to} penalized (ALERT ${hazard.id})');
            break;
          }
        }
        if (replaced) continue;
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
    required Duration osrmFetchTime,
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
        osrmFetchTime: osrmFetchTime,
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
  static bool _validateRouteAgainstBlockedSegments(
    List<LatLng> routePoints,
    Map<String, RoadSegmentResult?>? segmentsById,
    List<RouteNode> hazardNodes,
    VehicleType vehicle,
  ) {
    if (routePoints.length < 2) return true;
    const overlapTol = 8.0;
    for (var i = 0; i < routePoints.length - 1; i++) {
      final edge = [routePoints[i], routePoints[i + 1]];
      for (final hazard in hazardNodes) {
        final seg = segmentsById != null ? segmentsById[hazard.id] : null;
        if (seg == null || seg.points.length < 2) continue;
        final overlaps = GeoUtils.polylineOverlapsPolyline(edge, seg.points, overlapTol);
        if (!overlaps) continue;
        // If hazard is DANGER or not passable for this vehicle, route invalid
        if (hazard.status.toUpperCase() == 'DANGER' || !hazard.isPassableFor(vehicle)) {
          print('[RouteValidation] Route edge ${i} intersects blocked segment ${hazard.id}');
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
      // Prefer to classify vertices by overlap with the cached OSM segment
      // when available. This marks every densified vertex whose distance to
      // the OSM polyline is within the detection radius. Only if no such
      // overlap is found do we fall back to nearest-vertex + propagation.
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
          continue; // done with this hazard
        }
      }

      // No segment-overlap found — fall back to nearest-vertex + arc-length
      // propagation (this is the legacy behavior and is used only as a
      // fallback when OSM topology/geometry is unavailable).
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
    const overlapTol = 8.0; // meters
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
        print('[RouteSafety] OSRM edge overlaps ALERT OSM segment ${hazard.id} — applying penalty');
        return _SegWeight(base * _alertPenalty, true);
      }
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

  /// Returns the impassable flood nodes that any candidate route passes near.
  static List<RouteNode> _dangersNearCandidates(
    List<_OsrmRoute> routes,
    List<RouteNode> impassable,
    double radiusM,
  ) {
    final found = <RouteNode>[];
    for (final node in impassable) {
      var near = false;
      for (final route in routes) {
        for (final p in route.points) {
          if (_haversine(p, node.location) <= radiusM) {
            near = true;
            break;
          }
        }
        if (near) break;
      }
      if (near) found.add(node);
    }
    return found;
  }

  /// Requests detour routes that steer around the given danger points by
  /// injecting offset waypoints, then asking OSRM to route through them.
  static Future<List<_OsrmRoute>> _fetchDetourRoutes({
    required LatLng origin,
    required LatLng destination,
    required List<RouteNode> dangers,
  }) async {
    final results = <_OsrmRoute>[];
    final bearing = _bearing(origin, destination);

    // Try a couple of offset distances so at least one lands on a real
    // parallel road that OSRM can follow around the danger.
    for (final offsetKm in const [0.4, 0.8]) {
      final waypoints = <LatLng>[];
      for (final d in dangers) {
        final left = _offsetPoint(d.location, bearing + 90, offsetKm);
        final right = _offsetPoint(d.location, bearing - 90, offsetKm);
        // Pick the side that stays farther from every danger point.
        final leftClear = _minDistanceToNodes(left, dangers);
        final rightClear = _minDistanceToNodes(right, dangers);
        waypoints.add(leftClear > rightClear ? left : right);
      }
      waypoints.sort(
        (a, b) => _haversine(origin, a).compareTo(_haversine(origin, b)),
      );
      final route =
          await _fetchOsrmViaWaypoints(origin, destination, waypoints);
      if (route != null) results.add(route);
    }
    return results;
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

  static List<RouteNode> _seedNodes(List<Map<String, dynamic>> docs) {
    return docs.asMap().entries.map((entry) {
      final index = entry.key;
      final doc = entry.value;
      final coordinates = doc['location']['coordinates'] as List<dynamic>;
      final longitude = coordinates[0] as num;
      final latitude = coordinates[1] as num;
      final status = (doc['status'] as String).toUpperCase();
      final waterLevelM = (doc['water_level'] as num).toDouble();

      return RouteNode(
        id: 'c${index + 1}',
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
