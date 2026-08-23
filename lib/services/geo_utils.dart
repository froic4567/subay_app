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

    final result = <LatLng>[polyline.first];
    for (var i = 0; i < polyline.length - 1; i++) {
      final a = polyline[i];
      final b = polyline[i + 1];
      final dist = haversineM(a, b);
      final steps = dist > maxSegmentM ? (dist / maxSegmentM).ceil() : 1;
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
}
