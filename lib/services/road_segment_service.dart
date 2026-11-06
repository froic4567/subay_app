import 'dart:convert';
import 'dart:async';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'geo_utils.dart';
import 'road_segment_persistence.dart';

/// The road-coverage segment matched to a single camera coordinate: real OSM
/// road geometry clipped to [RoadSegmentService.clipDistanceM] each direction
/// from the camera's projected point along that road.
class RoadSegmentResult {
  final List<LatLng> points;
  final String? roadName; // OSM `name` tag, for logging/debug only
  final int? wayId;
  final bool fallbackUsed;

  const RoadSegmentResult({
    required this.points,
    this.roadName,
    this.wayId,
    this.fallbackUsed = false,
  });
}

class _OverpassWay {
  final int id;
  final List<int> nodeIds;
  final List<LatLng> points;
  final String? name;

  const _OverpassWay({
    required this.id,
    required this.nodeIds,
    required this.points,
    this.name,
  });
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

  /// Fallback arc-length distance used only when no topology boundary can
  /// be derived from OSM. Topology-derived boundaries (intersections,
  /// T/X/Y junctions) are preferred; this value is used as a graceful
  /// fallback for long isolated roads.
  static const double fallbackClipDistanceM = 200.0;

  static const Duration _timeout = Duration(seconds: 10);
  // Prefer a small set of Overpass endpoints and try fallbacks on failure.
  static const List<String> _overpassUrls = [
    'https://overpass-api.de/api/interpreter',
    'https://overpass.openstreetmap.fr/api/interpreter',
    'https://lz4.overpass-api.de/api/interpreter',
  ];

  // Limit concurrent Overpass requests from the app to avoid overloading
  // the public service when many cameras are visible at once.
  static const int _maxConcurrentRequests = 3;
  static int _activeRequests = 0;
  static final List<Completer<void>> _waitQueue = [];

  // Deduplicate simultaneous lookups for the same coordinate.
  static final Map<String, Future<RoadSegmentResult?>> _inflight = {};

  // Highway types that aren't usable by the vehicles this app routes for.
  static const _excludedHighwayTypes =
      'footway|path|cycleway|steps|pedestrian|track|bridleway|corridor|'
      'elevator|proposed|construction|platform|raceway|escape|'
      'bus_guideway|via_ferrata|planned|razed|abandoned';

  static final Map<String, RoadSegmentResult?> _cache = {};
  static bool _persistenceLoaded = false;

  /// After a full batch failure, don't hammer Overpass again for a short
  /// while. Routing keeps working from the camera-coordinate fallback in the
  /// meantime, and this prevents every reroute from stalling on timeouts.
  static DateTime? _batchRetryNotBefore;

  /// Returns the road segment covering [coordinate], or `null` if no
  /// vehicle-usable road was found nearby (graceful degradation — callers
  /// should simply skip drawing a segment, not fabricate one).
  static Future<RoadSegmentResult?> getSegmentForCamera(
    LatLng coordinate,
  ) async {
    final key = _cacheKey(coordinate);
    if (!_persistenceLoaded) await _restorePersistentCacheIfNeeded();
    if (_cache.containsKey(key)) {
      print('ℹ️ [RoadSegmentCache] HIT: $key');
      return _cache[key];
    }

    // If a lookup for the same coordinate is already in flight, await it.
    if (_inflight.containsKey(key)) {
      return _inflight[key];
    }

    final completer = Completer<RoadSegmentResult?>();
    _inflight[key] = completer.future;

    List<_OverpassWay> ways;
    try {
      ways = await _performLimitedQuery(coordinate);
    } catch (e) {
      print('❌ [RoadSegment] Overpass query failed for $key: $e');
      // Ensure inflight is cleared and don't cache a permanent null here —
      // allow future retries, but return null for now.
      completer.complete(null);
      _inflight.remove(key);
      return null;
    }

    if (ways.isEmpty) {
      print('⚠️ [RoadSegment] No candidate roads returned for $key');
      _cache[key] = null;
      completer.complete(null);
      _inflight.remove(key);
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
      completer.complete(null);
      _inflight.remove(key);
      return null;
    }

    // Attempt topology-aware clipping using node connectivity discovered
    // among the returned nearby ways. Build a node usage map counting how
    // many distinct ways reference each node within the query window.
    final nodeUsage = <int, int>{};
    for (final w in ways) {
      for (final nid in w.nodeIds) {
        nodeUsage[nid] = (nodeUsage[nid] ?? 0) + 1;
      }
    }

    // Map the bestWay's node IDs to their geometry indices (geometry and
    // node lists are expected to align 1:1 from Overpass 'geom' + 'nodes').
    final nodeIds = bestWay.nodeIds;
    final geom = bestWay.points;

    // Find the nearest geometry index to the projected point. The
    // projection may fall between two geometry points; use the segment
    // index reported by GeoUtils.
    final projSegIdx = bestProjection.segmentIndex;

    // Find candidate boundary nodes: walk outward along the node index
    // list until a node appears to be a junction (referenced by >1 way),
    // or until the way ends. Use those as logical boundaries.
    int projNodeIdx = -1;
    // Try to align projected segment to a nearby node index.
    for (var i = 0; i < geom.length; i++) {
      final d = GeoUtils.haversineM(geom[i], bestProjection.point);
      if (d <= 1.0) {
        projNodeIdx = i;
        break;
      }
    }
    // If no near-exact node found, use segment index as insertion point.
    if (projNodeIdx < 0) projNodeIdx = projSegIdx;

    int prevNodeIdx = -1;
    for (var i = projNodeIdx; i >= 0; i--) {
      final nid = i < nodeIds.length ? nodeIds[i] : -1;
      final uses = nid >= 0 ? (nodeUsage[nid] ?? 0) : 0;
      if (uses > 1 || i == 0) {
        prevNodeIdx = i;
        break;
      }
    }

    int nextNodeIdx = -1;
    for (var i = projNodeIdx; i < geom.length; i++) {
      final nid = i < nodeIds.length ? nodeIds[i] : -1;
      final uses = nid >= 0 ? (nodeUsage[nid] ?? 0) : 0;
      if (uses > 1 || i == geom.length - 1) {
        nextNodeIdx = i;
        break;
      }
    }

    List<LatLng> finalPoints = [];
    var usedFallback = false;

    if (prevNodeIdx >= 0 && nextNodeIdx >= 0 && prevNodeIdx < nextNodeIdx) {
      // Build the points from prevNodeIdx..nextNodeIdx inclusive. Insert
      // the projected point at the correct position if it doesn't
      // exactly equal an existing vertex so the segment starts/ends at
      // the projection where appropriate.
      finalPoints = geom.sublist(prevNodeIdx, nextNodeIdx + 1);

      // Insert projected point if it's between two vertices and not
      // already present.
      final proj = bestProjection.point;
      var insertPos = projSegIdx - prevNodeIdx + 1;
      if (insertPos < 0) insertPos = 0;
      if (insertPos > finalPoints.length) insertPos = finalPoints.length;
      // Avoid duplicating a nearly-equal point.
      bool almostEqual = false;
      if (insertPos - 1 >= 0 && GeoUtils.haversineM(finalPoints[insertPos - 1], proj) < 0.5) {
        almostEqual = true;
      }
      if (insertPos < finalPoints.length && GeoUtils.haversineM(finalPoints[insertPos], proj) < 0.5) {
        almostEqual = true;
      }
      if (!almostEqual) {
        finalPoints.insert(insertPos, proj);
      }
    } else {
      // No meaningful topology boundary found — fall back to fixed arc
      // distance clipping and log the fallback.
      usedFallback = true;
      print('⚠️ [RoadSegment] No topology boundary found for $key; using fallback ${fallbackClipDistanceM}m');
      finalPoints = GeoUtils.clipByArcLength(
        polyline: bestWay.points,
        projectedPoint: bestProjection.point,
        segmentIndex: bestProjection.segmentIndex,
        distanceM: fallbackClipDistanceM,
      );
    }

    final result = RoadSegmentResult(
      points: finalPoints,
      roadName: bestWay.name,
      wayId: bestWay.id,
      fallbackUsed: usedFallback,
    );
    print(
      '✅ [RoadSegment] Matched "${bestWay.name ?? 'unnamed road'}" '
      '(${finalPoints.length} pts) for $key, snap=${bestDistanceM.toStringAsFixed(1)}m, fallback=$usedFallback',
    );
    _cache[key] = result;
    // Persist cache asynchronously when new geometry is saved.
    try {
      savePersistentRoadSegmentCache(_serializeCache());
    } catch (_) {}
    completer.complete(result);
    _inflight.remove(key);
    return result;
  }

  /// Batch query: fetch all highway ways within a bounding box covering the
  /// supplied coordinates (+snapRadiusM margin). Returns a map of results
  /// keyed by the cache key for each coordinate. Uses cache where possible
  /// and performs a single Overpass bbox query for all uncached coordinates.
  static Future<Map<String, RoadSegmentResult?>> getSegmentsForCoordinates(
      Map<String, LatLng> idToCoord) async {
    final out = <String, RoadSegmentResult?>{};

    // Separate cached vs uncached
    final missing = <String, LatLng>{};
    for (final entry in idToCoord.entries) {
      final key = _cacheKey(entry.value);
      if (_cache.containsKey(key)) {
        out[entry.key] = _cache[key];
        print('ℹ️ [RoadSegmentCache] HIT: ${entry.key} -> $key');
      } else {
        missing[entry.key] = entry.value;
        print('ℹ️ [RoadSegmentCache] MISS: ${entry.key} -> $key');
      }
    }

    if (missing.isEmpty) return out;

    if (!_persistenceLoaded) await _restorePersistentCacheIfNeeded();

    // Compute bbox around missing coordinates, expand by snapRadiusM
    double minLat = double.infinity;
    double maxLat = -double.infinity;
    double minLon = double.infinity;
    double maxLon = -double.infinity;
    for (final p in missing.values) {
      minLat = min(minLat, p.latitude);
      maxLat = max(maxLat, p.latitude);
      minLon = min(minLon, p.longitude);
      maxLon = max(maxLon, p.longitude);
    }
    // Expand by approx degrees
    final expandDeg = snapRadiusM / 111320.0;
    minLat -= expandDeg;
    maxLat += expandDeg;
    minLon -= expandDeg;
    maxLon += expandDeg;

    print('ℹ️ [RoadSegmentCache] Fetching ${missing.length} missing coordinates in ONE Overpass request: $minLat,$minLon -> $maxLat,$maxLon');

    // Respect the short cooldown set after a previous complete failure.
    final retryNotBefore = _batchRetryNotBefore;
    if (retryNotBefore != null && DateTime.now().isBefore(retryNotBefore)) {
      print('⚠️ [RoadSegment] Batch Overpass cooling down; using cached/null geometry');
      if (out.isNotEmpty) return out;
      throw Exception('Overpass batch fetch cooling down after a recent failure');
    }

    // Single bbox Overpass query
    List<_OverpassWay> ways;
    try {
      ways = await _performLimitedQueryBox(minLat, minLon, maxLat, maxLon);
      _batchRetryNotBefore = null;
      print('✅ [RoadSegment] Batch OSM query completed: ${ways.length} ways');
    } catch (e) {
      print('❌ [RoadSegment] Batch Overpass failed: $e');
      _batchRetryNotBefore = DateTime.now().add(const Duration(seconds: 45));
      // If some cameras were already resolved from cache, return that partial
      // map so routing can proceed; only rethrow when there is nothing usable.
      if (out.isNotEmpty) return out;
      // Propagate the failure so callers (routing) can fall back to the
      // camera-coordinate checks instead of silently assuming "no hazard".
      rethrow;
    }

    // For each missing coordinate, pick best way locally
    for (final entry in missing.entries) {
      final id = entry.key;
      final coord = entry.value;
      final key = _cacheKey(coord);

      _OverpassWay? bestWay;
      double bestDistanceM = double.infinity;
      ({LatLng point, int segmentIndex, double distanceM})? bestProjection;

      for (final way in ways) {
        final projection = GeoUtils.nearestPointOnPolyline(coord, way.points);
        if (projection == null) continue;
        if (projection.distanceM > snapRadiusM) continue;
        if (projection.distanceM < bestDistanceM) {
          bestDistanceM = projection.distanceM;
          bestWay = way;
          bestProjection = projection;
        }
      }

      if (bestWay == null || bestProjection == null) {
        print('⚠️ [RoadSegment] No nearby road within ${snapRadiusM}m for $id ($key) in batch');
        _cache[key] = null;
        out[id] = null;
        continue;
      }

      // Build nodeUsage map limited to the returned ways
      final nodeUsage = <int, int>{};
      for (final w in ways) {
        for (final nid in w.nodeIds) {
          nodeUsage[nid] = (nodeUsage[nid] ?? 0) + 1;
        }
      }

      final nodeIds = bestWay.nodeIds;
      final geom = bestWay.points;
      final projSegIdx = bestProjection.segmentIndex;

      int projNodeIdx = -1;
      for (var i = 0; i < geom.length; i++) {
        final d = GeoUtils.haversineM(geom[i], bestProjection.point);
        if (d <= 1.0) {
          projNodeIdx = i;
          break;
        }
      }
      if (projNodeIdx < 0) projNodeIdx = projSegIdx;

      int prevNodeIdx = -1;
      for (var i = projNodeIdx; i >= 0; i--) {
        final nid = i < nodeIds.length ? nodeIds[i] : -1;
        final uses = nid >= 0 ? (nodeUsage[nid] ?? 0) : 0;
        if (uses > 1 || i == 0) {
          prevNodeIdx = i;
          break;
        }
      }

      int nextNodeIdx = -1;
      for (var i = projNodeIdx; i < geom.length; i++) {
        final nid = i < nodeIds.length ? nodeIds[i] : -1;
        final uses = nid >= 0 ? (nodeUsage[nid] ?? 0) : 0;
        if (uses > 1 || i == geom.length - 1) {
          nextNodeIdx = i;
          break;
        }
      }

      List<LatLng> finalPoints = [];
      var usedFallback = false;
      if (prevNodeIdx >= 0 && nextNodeIdx >= 0 && prevNodeIdx < nextNodeIdx) {
        finalPoints = geom.sublist(prevNodeIdx, nextNodeIdx + 1);
        final proj = bestProjection.point;
        var insertPos = projSegIdx - prevNodeIdx + 1;
        if (insertPos < 0) insertPos = 0;
        if (insertPos > finalPoints.length) insertPos = finalPoints.length;
        bool almostEqual = false;
        if (insertPos - 1 >= 0 && GeoUtils.haversineM(finalPoints[insertPos - 1], proj) < 0.5) {
          almostEqual = true;
        }
        if (insertPos < finalPoints.length && GeoUtils.haversineM(finalPoints[insertPos], proj) < 0.5) {
          almostEqual = true;
        }
        if (!almostEqual) {
          finalPoints.insert(insertPos, proj);
        }
      } else {
        usedFallback = true;
        print('⚠️ [RoadSegment] No topology boundary found for $id ($key) in batch; using fallback ${fallbackClipDistanceM}m');
        finalPoints = GeoUtils.clipByArcLength(
          polyline: bestWay.points,
          projectedPoint: bestProjection.point,
          segmentIndex: bestProjection.segmentIndex,
          distanceM: fallbackClipDistanceM,
        );
      }

      final result = RoadSegmentResult(
        points: finalPoints,
        roadName: bestWay.name,
        wayId: bestWay.id,
        fallbackUsed: usedFallback,
      );
      _cache[key] = result;
      out[id] = result;
      print('✅ [RoadSegmentCache] Saved: ${id} -> way=${bestWay.id} pts=${finalPoints.length} fallback=$usedFallback');
    }

    print('ℹ️ [RoadSegmentCache] Saved ${missing.length} geometries');
    // Persist updated cache
    try {
      savePersistentRoadSegmentCache(_serializeCache());
    } catch (_) {}
    return out;
  }

  static Future<void> _restorePersistentCacheIfNeeded() async {
    if (_persistenceLoaded) return;
    try {
      final map = await loadPersistentRoadSegmentCache();
      if (map.isNotEmpty) {
        for (final entry in map.entries) {
          try {
            final v = entry.value as Map<String, dynamic>;
            final pts = (v['points'] as List<dynamic>?)
                    ?.map((p) => LatLng((p[0] as num).toDouble(), (p[1] as num).toDouble()))
                    .toList() ??
                <LatLng>[];
            final rs = RoadSegmentResult(
              points: pts,
              roadName: v['roadName'] as String?,
              wayId: v['wayId'] as int?,
              fallbackUsed: v['fallbackUsed'] as bool? ?? false,
            );
            _cache[entry.key] = rs;
          } catch (_) {}
        }
        print('ℹ️ [RoadSegmentCache] Loaded ${map.length} geometries from persistent cache');
      }
    } catch (e) {
      print('⚠️ [RoadSegmentCache] Failed to restore persistent cache: $e');
    }
    _persistenceLoaded = true;
  }

  static Map<String, dynamic> _serializeCache() {
    final out = <String, dynamic>{};
    for (final entry in _cache.entries) {
      final key = entry.key;
      final val = entry.value;
      if (val == null) continue;
      out[key] = {
        'points': val.points.map((p) => [p.latitude, p.longitude]).toList(),
        'roadName': val.roadName,
        'wayId': val.wayId,
        'fallbackUsed': val.fallbackUsed,
      };
    }
    return out;
  }

  static Future<List<_OverpassWay>> _performLimitedQueryBox(double minLat, double minLon, double maxLat, double maxLon) async {
    await _acquireSlot();
    try {
        // Request ways within bbox plus their referenced nodes (via '>')
        // so we can compute node usage counts for topology-aware clipping.
        final query =
          '[out:json][timeout:20];'
          'way($minLat,$minLon,$maxLat,$maxLon)'
          '[highway]'
          '[highway!~"^($_excludedHighwayTypes)\$"];'
          '(._;>;);'
          'out geom;';

      const int maxAttempts = 1;
      for (final endpoint in _overpassUrls) {
        for (var attempt = 1; attempt <= maxAttempts; attempt++) {
          try {
            final response = await http.post(Uri.parse(endpoint), body: {'data': query}).timeout(_timeout);
            if (response.statusCode != 200) throw Exception('Overpass ${endpoint} returned ${response.statusCode}');
            final body = jsonDecode(response.body) as Map<String, dynamic>;
            final elements = body['elements'] as List<dynamic>? ?? [];
            final ways = elements
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
                  final id = (el['id'] as num).toInt();
                  final nodeIds = (el['nodes'] as List<dynamic>?)
                          ?.map((n) => (n as num).toInt())
                          .toList() ??
                      <int>[];
                  return _OverpassWay(id: id, nodeIds: nodeIds, points: points, name: tags?['name'] as String?);
                })
                .where((way) => way.points.length >= 2)
                .toList();
            return ways;
          } catch (e) {
            print('⚠️ [RoadSegment] Overpass bbox attempt $attempt to $endpoint failed: $e');
            await Future.delayed(Duration(milliseconds: 300 * attempt));
          }
        }
      }
      throw Exception('All Overpass bbox endpoints failed');
    } finally {
      _releaseSlot();
    }
  }

  static String _cacheKey(LatLng c) =>
      '${c.latitude.toStringAsFixed(5)},${c.longitude.toStringAsFixed(5)}';

  

  static Future<List<_OverpassWay>> _performLimitedQuery(LatLng coordinate) async {
    final key = _cacheKey(coordinate);
    await _acquireSlot();
    try {
      // Build the Overpass query once.
        // Request nearby ways and their nodes to ensure we receive node IDs
        // and can detect junctions via shared node references.
        final query =
          '[out:json][timeout:15];'
          'way(around:$snapRadiusM,${coordinate.latitude},${coordinate.longitude})'
          '[highway]'
          '[highway!~"^($_excludedHighwayTypes)\$"];'
          '(._;>;);'
          'out geom;';

      const int maxAttempts = 3;
      int attempt = 0;
      for (final endpoint in _overpassUrls) {
        attempt = 0;
        while (attempt < maxAttempts) {
          attempt++;
          try {
            final response = await http
                .post(Uri.parse(endpoint), body: {'data': query}).timeout(_timeout);
            if (response.statusCode != 200) {
              throw Exception('Overpass ${endpoint} returned ${response.statusCode}');
            }
            final body = jsonDecode(response.body) as Map<String, dynamic>;
            final elements = body['elements'] as List<dynamic>? ?? [];
            final ways = elements
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
                  final id = (el['id'] as num).toInt();
                  final nodeIds = (el['nodes'] as List<dynamic>?)
                          ?.map((n) => (n as num).toInt())
                          .toList() ??
                      <int>[];
                  return _OverpassWay(id: id, nodeIds: nodeIds, points: points, name: tags?['name'] as String?);
                })
                .where((way) => way.points.length >= 2)
                .toList();
            return ways;
          } catch (e) {
            print('⚠️ [RoadSegment] Overpass request attempt $attempt to $endpoint failed for $key: $e');
            if (attempt >= maxAttempts) break; // try next endpoint
            // Exponential backoff before retrying same endpoint.
            await Future.delayed(Duration(milliseconds: 200 * (1 << (attempt - 1))));
          }
        }
      }
      // All endpoints/attempts failed.
      throw Exception('All Overpass endpoints failed for $key');
    } finally {
      _releaseSlot();
    }
  }

  static Future<void> _acquireSlot() async {
    if (_activeRequests < _maxConcurrentRequests) {
      _activeRequests++;
      return;
    }
    final completer = Completer<void>();
    _waitQueue.add(completer);
    await completer.future;
  }

  static void _releaseSlot() {
    if (_waitQueue.isNotEmpty) {
      final next = _waitQueue.removeAt(0);
      // complete next queued waiter, keeping active count constant.
      next.complete();
    } else {
      _activeRequests = max(0, _activeRequests - 1);
    }
  }
}
