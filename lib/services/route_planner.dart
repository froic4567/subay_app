import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'cctv_service.dart';

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
  /// A flood point within this many meters of a segment influences that
  /// segment's cost (or blocks it entirely).
  static const double _detectRadiusM = 80.0;

  /// Points from different OSRM alternatives closer than this are linked so
  /// Dijkstra can switch between candidate roads at crossover points.
  static const double _crossLinkRadiusM = 35.0;

  /// Multiplier applied to a segment that passes a *passable* ALERT zone, so
  /// Dijkstra prefers a fully-normal alternative when one exists.
  static const double _alertPenalty = 6.0;

  static Future<RoutePlanResult?> planRoute({
    required LatLng origin,
    required LatLng destination,
    required VehicleType vehicleType,
  }) async {
    // 1. Fetch live CCTV flood data from MongoDB via the backend API.
    final cctvDocs = await CctvService.fetchCctvData();
    final seedNodes = _seedNodes(cctvDocs);
    final avoidableNodes =
        seedNodes.where((n) => !n.isPassableFor(vehicleType)).toList();
    final hazardNodes = seedNodes.where((n) {
      final s = n.status.toUpperCase();
      return s == 'DANGER' || s == 'ALERT';
    }).toList();

    // 2. Fetch OSRM candidate routes (primary + alternatives).
    final routes = <_OsrmRoute>[...await _fetchOsrmRoutes(origin, destination)];
    if (routes.isEmpty) return null;

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
      routes.addAll(detours);
    }

    // 3. Build one merged graph from all candidates.
    final nodes = <LatLng>[];
    final adj = <List<_Edge>>[];
    final nodeRoute = <int>[]; // which OSRM candidate a node belongs to (-1 = endpoint)

    int addNode(LatLng p, int route) {
      nodes.add(p);
      adj.add(<_Edge>[]);
      nodeRoute.add(route);
      return nodes.length - 1;
    }

    void link(int a, int b, double w, bool alert) {
      adj[a].add(_Edge(b, w, alert));
      adj[b].add(_Edge(a, w, alert));
    }

    final startIdx = <int>[];
    final endIdx = <int>[];

    for (var r = 0; r < routes.length; r++) {
      final pts = routes[r].points;
      final idxs = List<int>.generate(pts.length, (k) => addNode(pts[k], r));
      startIdx.add(idxs.first);
      endIdx.add(idxs.last);
      for (var i = 0; i < idxs.length - 1; i++) {
        final sw = _segmentWeight(
          nodes[idxs[i]],
          nodes[idxs[i + 1]],
          hazardNodes,
          vehicleType,
        );
        // Blocked segments simply get no edge, so Dijkstra can never use them.
        if (sw.weight.isFinite) {
          link(idxs[i], idxs[i + 1], sw.weight, sw.isAlert);
        }
      }
    }

    // 4. Cross-link nearby points from different candidates so Dijkstra can
    //    switch roads mid-route to escape a flooded segment.
    _addCrossLinks(nodes, nodeRoute, hazardNodes, vehicleType, link);

    // 5. Add explicit origin/destination super-nodes wired to every candidate.
    final src = addNode(origin, -1);
    final dst = addNode(destination, -1);
    for (final s in startIdx) {
      final sw = _segmentWeight(origin, nodes[s], hazardNodes, vehicleType);
      if (sw.weight.isFinite) link(src, s, sw.weight, sw.isAlert);
    }
    for (final e in endIdx) {
      final sw = _segmentWeight(nodes[e], destination, hazardNodes, vehicleType);
      if (sw.weight.isFinite) link(dst, e, sw.weight, sw.isAlert);
    }

    // 6. Run Dijkstra to find the safest guaranteed path.
    final dijkstra = _dijkstra(adj, src, dst);

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
  static void _addCrossLinks(
    List<LatLng> nodes,
    List<int> nodeRoute,
    List<RouteNode> hazards,
    VehicleType vehicle,
    void Function(int a, int b, double w, bool alert) link,
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
            final d = _haversine(nodes[i], nodes[j]);
            if (d > _crossLinkRadiusM) continue;
            final sw = _segmentWeight(nodes[i], nodes[j], hazards, vehicle);
            if (sw.weight.isFinite) link(i, j, sw.weight, sw.isAlert);
          }
        }
      }
    }
  }

  /// Computes the cost of travelling between two points. Returns an infinite
  /// weight (a hard block) if the segment grazes an impassable flood point.
  static _SegWeight _segmentWeight(
    LatLng a,
    LatLng b,
    List<RouteNode> hazards,
    VehicleType vehicle,
  ) {
    final base = _haversine(a, b);
    var weight = base;
    var isAlert = false;
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
          return const _SegWeight(double.infinity, false);
        }
        if (n.status.toUpperCase() == 'ALERT') {
          weight = base * _alertPenalty;
          isAlert = true;
        }
      }
    }
    return _SegWeight(weight, isAlert);
  }

  /// Classic Dijkstra shortest path with alert-flag propagation.
  static _DijkstraResult? _dijkstra(List<List<_Edge>> adj, int src, int dst) {
    final n = adj.length;
    final dist = List<double>.filled(n, double.infinity);
    final prev = List<int>.filled(n, -1);
    final alertOnPath = List<bool>.filled(n, false);
    dist[src] = 0;

    final heap = _MinHeap();
    heap.add(0.0, src);

    while (!heap.isEmpty) {
      final (cost, u) = heap.removeMin();
      if (cost > dist[u]) continue;
      if (u == dst) break;

      for (final e in adj[u]) {
        if (!e.weight.isFinite) continue;
        final newCost = dist[u] + e.weight;
        if (newCost < dist[e.to]) {
          dist[e.to] = newCost;
          prev[e.to] = u;
          alertOnPath[e.to] = alertOnPath[u] || e.isAlert;
          heap.add(newCost, e.to);
        }
      }
    }

    if (dist[dst] == double.infinity) return null;

    final path = <int>[];
    var current = dst;
    while (current != -1) {
      path.insert(0, current);
      current = prev[current];
    }
    return _DijkstraResult(path, dist[dst], alertOnPath[dst]);
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
