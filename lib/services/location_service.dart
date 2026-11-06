import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

/// Outcome of the standard location-access check. Carries enough detail for
/// each caller to reproduce its own existing user-facing message — this
/// service does not show any UI itself, since map_screen.dart and
/// routing_screen.dart use different message text for the same states.
enum LocationAccessStatus {
  granted,
  serviceDisabled,
  permissionDenied,
  permissionDeniedForever,
}

/// Centralizes the location-services-enabled → permission-check →
/// permission-request flow that was previously duplicated across
/// map_screen.dart and routing_screen.dart, and provides thin wrappers
/// around Geolocator for one-shot fetches and continuous position streams.
class LocationService {
  LocationService._();

  /// Runs the standard access-check sequence: service enabled, then
  /// permission granted (requesting it once if not yet decided).
  static Future<LocationAccessStatus> ensureAccess() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return LocationAccessStatus.serviceDisabled;

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        return LocationAccessStatus.permissionDenied;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      return LocationAccessStatus.permissionDeniedForever;
    }

    return LocationAccessStatus.granted;
  }

  /// One-shot high-accuracy position fetch. Returns null if access isn't
  /// granted or the platform call throws.
  static Future<Position?> getCurrentPosition() async {
    final status = await ensureAccess();
    if (status != LocationAccessStatus.granted) return null;
    try {
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  /// Wraps Geolocator.getPositionStream after confirming access. Returns
  /// null (no stream) if access isn't granted, so callers can skip
  /// subscribing entirely instead of subscribing to a stream that will
  /// never emit.
  static Future<Stream<Position>?> watchPosition({
    LocationAccuracy accuracy = LocationAccuracy.high,
    int distanceFilter = 0,
    Duration intervalDuration = const Duration(seconds: 1),
  }) async {
    final status = await ensureAccess();
    if (status != LocationAccessStatus.granted) return null;
    // `intervalDuration` only exists on AndroidSettings in geolocator 13;
    // the generic LocationSettings type rejects it at compile time.
    final LocationSettings settings =
        defaultTargetPlatform == TargetPlatform.android
            ? AndroidSettings(
                accuracy: accuracy,
                distanceFilter: distanceFilter,
                intervalDuration: intervalDuration,
              )
            : LocationSettings(
                accuracy: accuracy,
                distanceFilter: distanceFilter,
              );
    return Geolocator.getPositionStream(locationSettings: settings);
  }
}
