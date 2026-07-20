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

  /// Maximum flood water depth (in cm) this vehicle type can safely pass.
  double get maxWaterLevelCm {
    switch (this) {
      case VehicleType.bicycle:
        return 15;
      case VehicleType.motorcycle:
        return 25;
      case VehicleType.sedan:
        return 40;
      case VehicleType.suv:
        return 65;
      case VehicleType.truck:
        return 90;
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

class RouteNode {
  final String id;
  final String name;
  final String roadName;
  final LatLng location;
  final String status;
  final int waterLevelCm;
  final List<String> connectedIds;

  const RouteNode({
    required this.id,
    required this.name,
    required this.roadName,
    required this.location,
    required this.status,
    required this.waterLevelCm,
    required this.connectedIds,
  });

  bool isPassableFor(VehicleType vehicleType) {
    if (status.toUpperCase() == 'DANGER') {
      return false;
    }

    if (status.toUpperCase() == 'ALERT') {
      return waterLevelCm <= vehicleType.maxWaterLevelCm;
    }

    return true;
  }
}

class RoutePlanResult {
  final List<RouteNode> path;
  final double distanceKm;
  final double durationMinutes;
  final List<RouteNode> avoidedNodes;
  final List<LatLng> polyline;
  final String summary;

  const RoutePlanResult({
    required this.path,
    required this.distanceKm,
    required this.durationMinutes,
    required this.avoidedNodes,
    required this.polyline,
    required this.summary,
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

class RoutePlanner {
  static List<Map<String, dynamic>> sampleCctvDocuments() => [
    {
      'status': 'danger',
      'water_level': 1.345,
      'location': {
        'type': 'Point',
        'coordinates': [124.6433, 8.4822],
      },
      'timestamp': '2026-07-15T07:30:00Z',
    },
    {
      'status': 'alert',
      'water_level': 0.42,
      'location': {
        'type': 'Point',
        'coordinates': [124.6493, 8.4857],
      },
      'timestamp': '2026-07-15T07:31:00Z',
    },
    {
      'status': 'safe',
      'water_level': 0.08,
      'location': {
        'type': 'Point',
        'coordinates': [124.6476, 8.4872],
      },
      'timestamp': '2026-07-15T07:32:00Z',
    },
    {
      'status': 'danger',
      'water_level': 0.95,
      'location': {
        'type': 'Point',
        'coordinates': [124.6530, 8.4838],
      },
      'timestamp': '2026-07-15T07:33:00Z',
    },
    {
      'status': 'safe',
      'water_level': 0.05,
      'location': {
        'type': 'Point',
        'coordinates': [124.6501, 8.4818],
      },
      'timestamp': '2026-07-15T07:34:00Z',
    },
    {
      'status': 'alert',
      'water_level': 0.3,
      'location': {
        'type': 'Point',
        'coordinates': [124.6512, 8.4900],
      },
      'timestamp': '2026-07-15T07:35:00Z',
    },
  ];

  static Future<RoutePlanResult?> planRoute({
    required LatLng origin,
    required LatLng destination,
    required VehicleType vehicleType,
  }) async {
    // Fetch live CCTV data from MongoDB via backend API
    final cctvDocs = await CctvService.fetchCctvData();
    final seedNodes = _seedNodes(cctvDocs);
    final avoidableNodes = seedNodes.where((node) => !node.isPassableFor(vehicleType)).toList();

    print('🚗 [Route] Planning route for ${vehicleType.label}');
    print('🚗 [Route] Total CCTV nodes: ${seedNodes.length}');
    print('🚗 [Route] Impassable nodes: ${avoidableNodes.length}');

    // Determine the OSRM profile based on vehicle type.
    final profile = _osrmProfile(vehicleType);

    // First attempt: get direct route
    var polyline = await _fetchRoadPolyline(
      origin: origin,
      destination: destination,
      profile: profile,
    );

    if (polyline.isEmpty) {
      return null;
    }

    // Check if route passes through dangerous areas
    var dangerousNodesOnRoute = _findDangerousNodesOnRoute(
      polyline: polyline,
      avoidableNodes: avoidableNodes,
    );

    print('🚗 [Route] Dangerous nodes on initial route: ${dangerousNodesOnRoute.length}');

    // If route passes through danger, try to re-route with avoidance waypoints
    if (dangerousNodesOnRoute.isNotEmpty) {
      final avoidanceWaypoints = _generateAvoidanceWaypoints(
        origin: origin,
        destination: destination,
        dangerousNodes: dangerousNodesOnRoute,
      );

      if (avoidanceWaypoints.isNotEmpty) {
        print('🚗 [Route] Attempting re-route with ${avoidanceWaypoints.length} waypoints');
        
        final reroutedPolyline = await _fetchRoadPolylineWithWaypoints(
          origin: origin,
          destination: destination,
          waypoints: avoidanceWaypoints,
          profile: profile,
        );

        if (reroutedPolyline.isNotEmpty) {
          // Check if new route is safer
          final newDangerousNodes = _findDangerousNodesOnRoute(
            polyline: reroutedPolyline,
            avoidableNodes: avoidableNodes,
          );

          print('🚗 [Route] Dangerous nodes on re-routed path: ${newDangerousNodes.length}');

          // Use re-routed path if it's safer (fewer dangerous nodes)
          if (newDangerousNodes.length < dangerousNodesOnRoute.length) {
            polyline = reroutedPolyline;
            dangerousNodesOnRoute = newDangerousNodes;
            print('✅ [Route] Re-route successful! Safer path found.');
          } else {
            print('⚠️ [Route] Re-route did not improve safety. Using original route.');
          }
        }
      }
    }

    final durationMinutes = await _fetchRouteDuration(
      origin: origin,
      destination: destination,
      profile: profile,
    );

    final originNode = RouteNode(
      id: 'origin',
      name: 'Origin',
      roadName: 'Your location',
      location: origin,
      status: 'SAFE',
      waterLevelCm: 0,
      connectedIds: const [],
    );
    final destinationNode = RouteNode(
      id: 'destination',
      name: 'Destination',
      roadName: 'Selected destination',
      location: destination,
      status: 'SAFE',
      waterLevelCm: 0,
      connectedIds: const [],
    );

    final distance = _sumDistance(polyline);

    return RoutePlanResult(
      path: [originNode, destinationNode],
      distanceKm: distance,
      durationMinutes: durationMinutes,
      avoidedNodes: avoidableNodes,
      polyline: polyline,
      summary: '${distance.toStringAsFixed(1)} km · ${RoutePlanResult.formatEta(durationMinutes)}',
    );
  }

  /// Finds which impassable CCTV nodes the route passes through
  static List<RouteNode> _findDangerousNodesOnRoute({
    required List<LatLng> polyline,
    required List<RouteNode> avoidableNodes,
  }) {
    const thresholdMeters = 150; // Within 150m of route = considered "on route"
    final dangerousNodes = <RouteNode>[];

    for (final node in avoidableNodes) {
      for (final point in polyline) {
        final distanceMeters = const Distance().as(
          LengthUnit.Meter,
          node.location,
          point,
        );
        if (distanceMeters <= thresholdMeters) {
          dangerousNodes.add(node);
          print('⚠️ [Route] Route passes near ${node.name} (${node.status}, ${node.waterLevelCm}cm)');
          break;
        }
      }
    }

    return dangerousNodes;
  }

  /// Generates intermediate waypoints to steer route around dangerous areas
  static List<LatLng> _generateAvoidanceWaypoints({
    required LatLng origin,
    required LatLng destination,
    required List<RouteNode> dangerousNodes,
  }) {
    if (dangerousNodes.isEmpty) return [];

    final waypoints = <LatLng>[];
    const offsetKm = 0.5; // Offset 500m to avoid danger zone

    // Calculate the general direction of travel
    final bearing = const Distance().bearing(
      LatLng(origin.latitude, origin.longitude),
      LatLng(destination.latitude, destination.longitude),
    );

    // For each dangerous node, create a waypoint that steers around it
    for (final node in dangerousNodes) {
      final dangerPoint = node.location;
      
      // Calculate perpendicular offset (left or right of route)
      // Try both sides and pick the one farther from other danger zones
      final leftOffset = _offsetPoint(dangerPoint, bearing + 90, offsetKm);
      final rightOffset = _offsetPoint(dangerPoint, bearing - 90, offsetKm);

      // Choose the offset point that's farther from all dangerous nodes
      final leftScore = _minDistanceToNodes(leftOffset, dangerousNodes);
      final rightScore = _minDistanceToNodes(rightOffset, dangerousNodes);

      final waypoint = leftScore > rightScore ? leftOffset : rightOffset;
      waypoints.add(waypoint);
      
      print('📍 [Route] Adding avoidance waypoint near ${node.name}');
    }

    // Sort waypoints by distance from origin to ensure proper order
    waypoints.sort((a, b) {
      final distA = const Distance().as(LengthUnit.Kilometer, origin, a);
      final distB = const Distance().as(LengthUnit.Kilometer, origin, b);
      return distA.compareTo(distB);
    });

    return waypoints;
  }

  /// Offsets a point by a given distance in a given bearing (in degrees)
  static LatLng _offsetPoint(LatLng point, double bearingDeg, double distanceKm) {
    const earthRadiusKm = 6371.0;
    final bearingRad = bearingDeg * pi / 180.0;
    final latRad = point.latitude * pi / 180.0;
    final lngRad = point.longitude * pi / 180.0;

    final newLatRad = latRad + (distanceKm / earthRadiusKm) * cos(bearingRad);
    final newLngRad = lngRad + (distanceKm / (earthRadiusKm * cos(latRad))) * sin(bearingRad);

    return LatLng(
      newLatRad * 180.0 / pi,
      newLngRad * 180.0 / pi,
    );
  }

  /// Finds minimum distance from a point to any node in the list
  static double _minDistanceToNodes(LatLng point, List<RouteNode> nodes) {
    var minDist = double.infinity;
    for (final node in nodes) {
      final dist = const Distance().as(LengthUnit.Meter, point, node.location);
      if (dist < minDist) minDist = dist;
    }
    return minDist;
  }

  /// Fetches route with intermediate waypoints
  static Future<List<LatLng>> _fetchRoadPolylineWithWaypoints({
    required LatLng origin,
    required LatLng destination,
    required List<LatLng> waypoints,
    String profile = 'driving',
  }) async {
    try {
      final allCoords = <LatLng>[origin, ...waypoints, destination];
      final coords = allCoords.map(_formatCoordinate).join(';');

      final uri = Uri.parse(
        'https://router.project-osrm.org/route/v1/$profile/$coords?overview=full&geometries=geojson&alternatives=false',
      );

      print('🌐 [Route] Requesting route with ${waypoints.length} waypoints');

      final response = await http.get(uri).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        return const [];
      }

      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final routes = body['routes'] as List<dynamic>?;
      if (routes == null || routes.isEmpty) {
        return const [];
      }

      final geometry = routes.first['geometry'] as Map<String, dynamic>?;
      if (geometry == null) return const [];

      final coordinates = geometry['coordinates'] as List<dynamic>?;
      if (coordinates == null || coordinates.isEmpty) {
        return const [];
      }

      final points = <LatLng>[];
      for (final coord in coordinates) {
        if (coord is! List || coord.length < 2) continue;
        final lng = (coord[0] as num).toDouble();
        final lat = (coord[1] as num).toDouble();
        if (lat.abs() > 90 || lng.abs() > 180) continue;
        points.add(LatLng(lat, lng));
      }
      return points;
    } catch (e) {
      print('❌ [Route] Waypoint routing failed: $e');
      return const [];
    }
  }

  static String _osrmProfile(VehicleType vehicleType) {
    // OSRM public server only supports 'driving' profile
    return 'driving';
  }

  static Future<List<LatLng>> _fetchRoadPolyline({
    required LatLng origin,
    required LatLng destination,
    String profile = 'driving',
  }) async {
    try {
      final coords = <String>[
        _formatCoordinate(origin),
        _formatCoordinate(destination),
      ];

      final uri = Uri.parse(
        'https://router.project-osrm.org/route/v1/$profile/${coords.join(';')}?overview=full&geometries=geojson&alternatives=false',
      );

      final response = await http.get(uri).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        return const [];
      }

      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final routes = body['routes'] as List<dynamic>?;
      if (routes == null || routes.isEmpty) {
        return const [];
      }

      final geometry = routes.first['geometry'] as Map<String, dynamic>?;
      if (geometry == null) return const [];

      final coordinates = geometry['coordinates'] as List<dynamic>?;
      if (coordinates == null || coordinates.isEmpty) {
        return const [];
      }

      // GeoJSON returns [ [lng, lat], [lng, lat], ... ]
      final points = <LatLng>[];
      for (final coord in coordinates) {
        if (coord is! List || coord.length < 2) continue;
        final lng = (coord[0] as num).toDouble();
        final lat = (coord[1] as num).toDouble();
        // Validate coordinate ranges
        if (lat.abs() > 90 || lng.abs() > 180) continue;
        points.add(LatLng(lat, lng));
      }
      return points;
    } catch (_) {
      return const [];
    }
  }

  /// Fetches the travel duration (in minutes) for the route.
  static Future<double> _fetchRouteDuration({
    required LatLng origin,
    required LatLng destination,
    String profile = 'driving',
  }) async {
    try {
      final coords = <String>[
        _formatCoordinate(origin),
        _formatCoordinate(destination),
      ];

      final uri = Uri.parse(
        'https://router.project-osrm.org/route/v1/$profile/${coords.join(';')}?overview=false',
      );

      final response = await http.get(uri).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return 0;

      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final routes = body['routes'] as List<dynamic>?;
      if (routes == null || routes.isEmpty) return 0;

      final durationSec = routes.first['duration'] as num?;
      if (durationSec == null) return 0;

      return durationSec.toDouble() / 60.0; // convert seconds → minutes
    } catch (_) {
      return 0;
    }
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
      final waterLevelCm = ((doc['water_level'] as num) * 100).round();

      return RouteNode(
        id: 'c${index + 1}',
        name: 'CCTV-${(index + 1).toString().padLeft(2, '0')}',
        roadName: 'CCTV node ${index + 1}',
        location: LatLng(latitude.toDouble(), longitude.toDouble()),
        status: status,
        waterLevelCm: waterLevelCm,
        connectedIds: const [],
      );
    }).toList();
  }

  static double _sumDistance(List<LatLng> points) {
    var total = 0.0;
    for (var i = 1; i < points.length; i++) {
      total += _distanceKm(points[i - 1], points[i]);
    }
    return total;
  }

  static double _distanceKm(LatLng from, LatLng to) {
    final distance = const Distance();
    return distance.as(LengthUnit.Kilometer, from, to);
  }
}
