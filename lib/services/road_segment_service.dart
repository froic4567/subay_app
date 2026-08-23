import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'geo_utils.dart';

/// The road-coverage segment matched to a single camera coordinate: real OSM
/// road geometry clipped to [RoadSegmentService.clipDistanceM] each direction
/// from the camera's projected point along that road.
class RoadSegmentResult {
  final List<LatLng> points;
  final String? roadName; // OSM `name` tag, for logging/debug only

  const RoadSegmentResult({required this.points, this.roadName});
}

class _OverpassWay {
  final List<LatLng> points;
  final String? name;

  const _OverpassWay({required this.points, this.name});
}

/// Resolves the real road geometry a CCTV camera monitors, via the free
/// Overpass API (OpenStreetMap), and clips it to a fixed distance each
/// direction from the camera's projected point along that road.
///
/// The camera's stored coordinate is the only input — there is no bearing,
/// field-of-view, or coverage-distance data in the database, so this picks
/// the geometrically nearest vehicle-usable road within a snap radius. This
/// is a known limitation: two very close, roughly parallel roads cannot be
/// disambiguated without camera orientation data.
///
/// Road geometry rarely changes, so results are cached in-memory per camera
/// coordinate for the app session — only camera status/water level, polled
/// separately, needs to update on every refresh.
class RoadSegmentService {
  /// Max distance from the camera coordinate to a candidate road to accept
  /// it as a match.
  static const double snapRadiusM = 50.0;

  /// Arc-length distance the returned segment extends in each direction
  /// from the camera's projected point along the matched road.
  static const double clipDistanceM = 200.0;

  static const Duration _timeout = Duration(seconds: 10);
  static const _overpassUrl = 'https://overpass-api.de/api/interpreter';

  // Highway types that aren't usable by the vehicles this app routes for.
  static const _excludedHighwayTypes =
      'footway|path|cycleway|steps|pedestrian|track|bridleway|corridor|'
      'elevator|proposed|construction|platform|raceway|escape|'
      'bus_guideway|via_ferrata|planned|razed|abandoned';

  static final Map<String, RoadSegmentResult?> _cache = {};

  /// Returns the road segment covering [coordinate], or `null` if no
  /// vehicle-usable road was found nearby (graceful degradation — callers
  /// should simply skip drawing a segment, not fabricate one).
  static Future<RoadSegmentResult?> getSegmentForCamera(
    LatLng coordinate,
  ) async {
    final key = _cacheKey(coordinate);
    if (_cache.containsKey(key)) {
      return _cache[key];
    }

    List<_OverpassWay> ways;
    try {
      ways = await _queryOverpass(coordinate).timeout(_timeout);
    } catch (e) {
      print('❌ [RoadSegment] Overpass query failed for $key: $e');
      // Not cached — a transient failure shouldn't permanently blank a
      // camera's segment; the next poll can retry.
      return null;
    }

    if (ways.isEmpty) {
      print('⚠️ [RoadSegment] No candidate roads returned for $key');
      _cache[key] = null;
      return null;
    }

    _OverpassWay? bestWay;
    double bestDistanceM = double.infinity;
    ({LatLng point, int segmentIndex, double distanceM})? bestProjection;

    for (final way in ways) {
      final projection = GeoUtils.nearestPointOnPolyline(
        coordinate,
        way.points,
      );
      if (projection == null) continue;
      if (projection.distanceM > snapRadiusM) continue;
      if (projection.distanceM < bestDistanceM) {
        bestDistanceM = projection.distanceM;
        bestWay = way;
        bestProjection = projection;
      }
    }

    if (bestWay == null || bestProjection == null) {
      print('⚠️ [RoadSegment] No road within ${snapRadiusM}m for $key');
      _cache[key] = null;
      return null;
    }

    final clipped = GeoUtils.clipByArcLength(
      polyline: bestWay.points,
      projectedPoint: bestProjection.point,
      segmentIndex: bestProjection.segmentIndex,
      distanceM: clipDistanceM,
    );

    final result = RoadSegmentResult(points: clipped, roadName: bestWay.name);
    print(
      '✅ [RoadSegment] Matched "${bestWay.name ?? 'unnamed road'}" '
      '(${clipped.length} pts) for $key, snap=${bestDistanceM.toStringAsFixed(1)}m',
    );
    _cache[key] = result;
    return result;
  }

  static String _cacheKey(LatLng c) =>
      '${c.latitude.toStringAsFixed(5)},${c.longitude.toStringAsFixed(5)}';

  static Future<List<_OverpassWay>> _queryOverpass(LatLng coordinate) async {
    final query =
        '[out:json][timeout:15];'
        'way(around:$snapRadiusM,${coordinate.latitude},${coordinate.longitude})'
        '[highway]'
        '[highway!~"^($_excludedHighwayTypes)\$"];'
        'out geom;';

    final response = await http.post(
      Uri.parse(_overpassUrl),
      body: {'data': query},
    );

    if (response.statusCode != 200) {
      throw Exception('Overpass returned ${response.statusCode}');
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final elements = body['elements'] as List<dynamic>? ?? [];

    return elements
        .map((e) {
          final el = e as Map<String, dynamic>;
          final geometry = el['geometry'] as List<dynamic>? ?? [];
          final points = geometry.map((g) {
            final point = g as Map<String, dynamic>;
            final lat = (point['lat'] as num).toDouble();
            final lon = (point['lon'] as num).toDouble();
            return LatLng(lat, lon);
          }).toList();
          final tags = el['tags'] as Map<String, dynamic>?;
          return _OverpassWay(points: points, name: tags?['name'] as String?);
        })
        .where((way) => way.points.length >= 2)
        .toList();
  }
}
