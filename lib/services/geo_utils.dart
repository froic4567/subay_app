import 'dart:math';
import 'package:latlong2/latlong.dart';

/// Shared geometry helpers for projecting points onto road/route polylines
/// and walking a fixed arc-length distance along them.
///
/// Used by [RoadSegmentService] (Map tab road-coverage lookup) and
/// [RoutePlanner] (Routing tab hazard-segment propagation) so both features
/// model "distance along a road" the same way.
class GeoUtils {
  GeoUtils._();

  /// Great-circle distance between two points, in meters.
  static double haversineM(LatLng a, LatLng b) {
    const earthRadiusM = 6371000.0;
    final lat1 = a.latitude * pi / 180.0;
    final lat2 = b.latitude * pi / 180.0;
    final dLat = (b.latitude - a.latitude) * pi / 180.0;
    final dLng = (b.longitude - a.longitude) * pi / 180.0;

    final h =
        sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1) * cos(lat2) * sin(dLng / 2) * sin(dLng / 2);
    return earthRadiusM * 2 * atan2(sqrt(h), sqrt(1 - h));
  }

  /// Nearest point to [p] on the segment `a`-`b`, and its distance to [p].
  ///
  /// Projects in a local equirectangular approximation (accurate enough at
  /// city scale) rather than true great-circle projection, keeping this
  /// cheap enough to run per-edge inside routing's graph construction.
  static ({LatLng point, double distanceM}) nearestPointOnSegment(
    LatLng p,
    LatLng a,
    LatLng b,
  ) {
    final latRad = a.latitude * pi / 180.0;
    final lngScale = cos(latRad);

    final ax = a.longitude * lngScale;
    final ay = a.latitude;
    final bx = b.longitude * lngScale;
    final by = b.latitude;
    final px = p.longitude * lngScale;
    final py = p.latitude;

    final dx = bx - ax;
    final dy = by - ay;
    final lenSq = dx * dx + dy * dy;

    double t;
    if (lenSq == 0) {
      t = 0;
    } else {
      t = ((px - ax) * dx + (py - ay) * dy) / lenSq;
      t = t.clamp(0.0, 1.0);
    }

    final point = LatLng(
      a.latitude + t * (b.latitude - a.latitude),
      a.longitude + t * (b.longitude - a.longitude),
    );
    return (point: point, distanceM: haversineM(p, point));
  }

  /// Nearest point to [p] anywhere along [polyline]; returns the projected
  /// point, the index of the segment it falls on (between
  /// `polyline[segmentIndex]` and `polyline[segmentIndex + 1]`), and the
  /// distance from [p]. Returns `null` if [polyline] has fewer than 2 points.
  static ({LatLng point, int segmentIndex, double distanceM})?
  nearestPointOnPolyline(LatLng p, List<LatLng> polyline) {
    if (polyline.length < 2) return null;

    var bestDist = double.infinity;
    var bestPoint = polyline.first;
    var bestIndex = 0;

    for (var i = 0; i < polyline.length - 1; i++) {
      final result = nearestPointOnSegment(p, polyline[i], polyline[i + 1]);
      if (result.distanceM < bestDist) {
        bestDist = result.distanceM;
        bestPoint = result.point;
        bestIndex = i;
      }
    }

    return (point: bestPoint, segmentIndex: bestIndex, distanceM: bestDist);
  }

  /// Resamples [polyline] so no two consecutive points are farther apart
  /// than [maxSegmentM], linearly interpolating between existing vertices.
  /// Leaves [polyline] unchanged if it already satisfies the spacing (or has
  /// fewer than 2 points).
  static List<LatLng> densify(List<LatLng> polyline, double maxSegmentM) {
    if (polyline.length < 2 || maxSegmentM <= 0) return polyline;

    // Defensive cap: a legitimate single vertex-to-vertex gap in a real
    // road route is never more than a few km, even on long rural
    // straights. If some upstream source (a third-party routing API, a
    // polyline decoder bug, corrupted data, etc.) ever hands us a pair of
    // points with an enormous gap between them — e.g. one garbled
    // coordinate landing near (0,0) — computing steps = dist/maxSegmentM
    // with no ceiling would try to generate potentially millions of
    // interpolated points and freeze the app. Capping steps per segment
    // makes this function safe regardless of what feeds it; a capped
    // segment is a rare/degenerate case being handled gracefully, not a
    // silently-accepted routing decision (see also the sanity check on
    // the decoded route itself where it's first constructed).
    const maxStepsPerSegment = 500;

    final result = <LatLng>[polyline.first];
    for (var i = 0; i < polyline.length - 1; i++) {
      final a = polyline[i];
      final b = polyline[i + 1];
      final dist = haversineM(a, b);
      var steps = dist > maxSegmentM ? (dist / maxSegmentM).ceil() : 1;
      if (steps > maxStepsPerSegment) {
        // ignore: avoid_print
        print(
          '⚠️ [GeoUtils] densify: capping an abnormally large gap '
          '(${dist.toStringAsFixed(0)}m) to $maxStepsPerSegment steps — '
          'this usually means upstream route data is corrupt.',
        );
        steps = maxStepsPerSegment;
      }
      for (var s = 1; s <= steps; s++) {
        final t = s / steps;
        result.add(
          LatLng(
            a.latitude + t * (b.latitude - a.latitude),
            a.longitude + t * (b.longitude - a.longitude),
          ),
        );
      }
    }
    return result;
  }

  /// Clips [polyline] to the portion within [distanceM] meters of arc length
  /// in each direction from [projectedPoint] (which lies on the segment
  /// starting at [segmentIndex]), clipped shorter if the polyline itself
  /// ends sooner in either direction.
  static List<LatLng> clipByArcLength({
    required List<LatLng> polyline,
    required LatLng projectedPoint,
    required int segmentIndex,
    required double distanceM,
  }) {
    if (polyline.isEmpty) return const [];
    if (polyline.length == 1) return [polyline.first];

    // Walk backward from projectedPoint toward polyline[0].
    final backward = <LatLng>[projectedPoint];
    var remaining = distanceM;
    var cursor = projectedPoint;
    for (var i = segmentIndex; i >= 0 && remaining > 0; i--) {
      final next = polyline[i];
      final d = haversineM(cursor, next);
      if (d <= remaining) {
        backward.add(next);
        remaining -= d;
        cursor = next;
      } else {
        final t = remaining / d;
        backward.add(
          LatLng(
            cursor.latitude + t * (next.latitude - cursor.latitude),
            cursor.longitude + t * (next.longitude - cursor.longitude),
          ),
        );
        remaining = 0;
      }
    }

    // Walk forward from projectedPoint toward the polyline's end.
    final forward = <LatLng>[];
    remaining = distanceM;
    cursor = projectedPoint;
    for (var i = segmentIndex + 1; i < polyline.length && remaining > 0; i++) {
      final next = polyline[i];
      final d = haversineM(cursor, next);
      if (d <= remaining) {
        forward.add(next);
        remaining -= d;
        cursor = next;
      } else {
        final t = remaining / d;
        forward.add(
          LatLng(
            cursor.latitude + t * (next.latitude - cursor.latitude),
            cursor.longitude + t * (next.longitude - cursor.longitude),
          ),
        );
        remaining = 0;
      }
    }

    return [...backward.reversed, ...forward];
  }

  /// Returns true when two polylines come within [toleranceMeters] of each
  /// other or their projected segments intersect. Uses an equirectangular
  /// projection for robust, cheap planar checks at city scale.
  static bool polylineOverlapsPolyline(
    List<LatLng> a,
    List<LatLng> b,
    double toleranceMeters,
  ) {
    if (a.length < 2 || b.length < 2) return false;

    // Quick bbox early-out using lat/lon with small expansion.
    double aminLat = double.infinity, amaxLat = -double.infinity;
    double aminLon = double.infinity, amaxLon = -double.infinity;
    for (final p in a) {
      aminLat = min(aminLat, p.latitude);
      amaxLat = max(amaxLat, p.latitude);
      aminLon = min(aminLon, p.longitude);
      amaxLon = max(amaxLon, p.longitude);
    }
    double bminLat = double.infinity, bmaxLat = -double.infinity;
    double bminLon = double.infinity, bmaxLon = -double.infinity;
    for (final p in b) {
      bminLat = min(bminLat, p.latitude);
      bmaxLat = max(bmaxLat, p.latitude);
      bminLon = min(bminLon, p.longitude);
      bmaxLon = max(bmaxLon, p.longitude);
    }
    // Convert tolerance to degrees roughly for early bbox check.
    final tolDeg = toleranceMeters / 111320.0;
    if (amaxLat + tolDeg < bminLat || bmaxLat + tolDeg < aminLat) return false;
    if (amaxLon + tolDeg < bminLon || bmaxLon + tolDeg < aminLon) return false;

    // Project coordinates using local latitude scale for more accurate XY checks.
    double latRad = ((aminLat + amaxLat + bminLat + bmaxLat) / 4.0) * pi / 180.0;
    final lngScale = cos(latRad);

    bool segsIntersectProjected(LatLng a1, LatLng a2, LatLng b1, LatLng b2) {
      final ax1 = a1.longitude * lngScale;
      final ay1 = a1.latitude;
      final ax2 = a2.longitude * lngScale;
      final ay2 = a2.latitude;
      final bx1 = b1.longitude * lngScale;
      final by1 = b1.latitude;
      final bx2 = b2.longitude * lngScale;
      final by2 = b2.latitude;

      double orient(double x1, double y1, double x2, double y2, double x3, double y3) {
        return (x2 - x1) * (y3 - y1) - (y2 - y1) * (x3 - x1);
      }

      final o1 = orient(ax1, ay1, ax2, ay2, bx1, by1);
      final o2 = orient(ax1, ay1, ax2, ay2, bx2, by2);
      final o3 = orient(bx1, by1, bx2, by2, ax1, ay1);
      final o4 = orient(bx1, by1, bx2, by2, ax2, ay2);

      if (o1 == 0 && o2 == 0 && o3 == 0 && o4 == 0) {
        // Colinear - fallback to distance checks
        return false;
      }

      return (o1 * o2 < 0) && (o3 * o4 < 0);
    }

    for (var i = 0; i < a.length - 1; i++) {
      for (var j = 0; j < b.length - 1; j++) {
        // If projected segments intersect, they overlap
        if (segsIntersectProjected(a[i], a[i + 1], b[j], b[j + 1])) return true;
        // Otherwise check endpoint-to-segment distances
        final d1 = nearestPointOnSegment(a[i], b[j], b[j + 1]).distanceM;
        if (d1 <= toleranceMeters) return true;
        final d2 = nearestPointOnSegment(a[i + 1], b[j], b[j + 1]).distanceM;
        if (d2 <= toleranceMeters) return true;
        final d3 = nearestPointOnSegment(b[j], a[i], a[i + 1]).distanceM;
        if (d3 <= toleranceMeters) return true;
        final d4 = nearestPointOnSegment(b[j + 1], a[i], a[i + 1]).distanceM;
        if (d4 <= toleranceMeters) return true;
      }
    }
    return false;
  }
}