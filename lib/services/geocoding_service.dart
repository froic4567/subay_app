import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

/// A single geocoding search result from Nominatim (OpenStreetMap).
class GeoSearchResult {
  final String displayName;
  final String shortName;
  final LatLng latLng;

  const GeoSearchResult({
    required this.displayName,
    required this.shortName,
    required this.latLng,
  });

  @override
  String toString() => shortName;
}

class GeocodingService {
  // Cagayan de Oro bounding box (south, north, west, east)
  // Restricts search results to CDO area only
  static const _cdoViewbox = '124.6040,8.5280,124.6980,8.4480';

  /// Searches for a place by text query using the Nominatim API.
  /// Results are restricted to the Cagayan de Oro area.
  ///
  /// Returns a list of matching [GeoSearchResult]s (max 5).
  static Future<List<GeoSearchResult>> searchPlace(String query) async {
    if (query.trim().isEmpty) return const [];

    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/search'
        '?format=json&q=${Uri.encodeQueryComponent(query)}'
        '&limit=5&addressdetails=1'
        '&viewbox=$_cdoViewbox&bounded=1',
      );

      final response = await http.get(
        uri,
        headers: {
          'Accept': 'application/json',
          // Nominatim requires a valid User-Agent identifying the application.
          'User-Agent': 'SUBAY-Flood-App/1.0',
        },
      );

      if (response.statusCode != 200) return const [];

      final List<dynamic> json = jsonDecode(response.body) as List<dynamic>;
      if (json.isEmpty) return const [];

      final results = <GeoSearchResult>[];
      for (final item in json) {
        final lat = double.tryParse(item['lat']?.toString() ?? '');
        final lon = double.tryParse(item['lon']?.toString() ?? '');
        if (lat == null || lon == null) continue;

        final displayName = item['display_name'] as String? ?? '';
        final shortName = _extractShortName(item);

        results.add(GeoSearchResult(
          displayName: displayName,
          shortName: shortName.isEmpty ? displayName.split(',').first.trim() : shortName,
          latLng: LatLng(lat, lon),
        ));
      }

      return results;
    } catch (_) {
      return const [];
    }
  }

  /// Reverse-geocodes a coordinate into a human-readable address.
  static Future<String> reverseGeocode(LatLng point) async {
    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse'
        '?format=json&lat=${point.latitude}&lon=${point.longitude}'
        '&zoom=18&addressdetails=1',
      );

      final response = await http.get(
        uri,
        headers: {
          'Accept': 'application/json',
          'User-Agent': 'SUBAY-Flood-App/1.0',
        },
      );

      if (response.statusCode != 200) return 'Pinned Location';

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final displayName = data['display_name'] as String?;
      if (displayName == null || displayName.isEmpty) return 'Pinned Location';

      // Return a shortened version (first 2-3 comma-separated parts)
      final parts = displayName.split(',');
      if (parts.length <= 2) return displayName.trim();
      return '${parts[0].trim()}, ${parts[1].trim()}';
    } catch (_) {
      return 'Pinned Location';
    }
  }

  static String _extractShortName(Map<String, dynamic> item) {
    // Prefer the "name" field if available
    final name = item['name'] as String?;
    if (name != null && name.isNotEmpty) return name;

    // Fall back to address components
    final address = item['address'] as Map<String, dynamic>?;
    if (address != null) {
      for (final key in ['road', 'neighbourhood', 'suburb', 'city', 'town', 'village']) {
        final value = address[key] as String?;
        if (value != null && value.isNotEmpty) return value;
      }
    }

    // Last resort: first part of display_name
    final display = item['display_name'] as String? ?? '';
    return display.split(',').first.trim();
  }
}
