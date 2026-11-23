import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

/// Fetches CCTV flood monitoring data from the backend API (which connects to MongoDB).
///
/// This service is fully database-driven: flood hazards (danger/alert) come
/// exclusively from the live database. If the backend is unreachable or returns
/// nothing, these methods return an EMPTY list — no hardcoded/sample hazards are
/// ever injected, so routing only ever avoids real, database-marked flood points.
///
/// URL selection:
/// - `BACKEND_URL` in `.env`, if set — used as-is (needed for a physical device,
///   since `localhost`/`10.0.2.2` are not reachable from real hardware).
/// - Web (Chrome): http://localhost:3000
/// - Android emulator: http://10.0.2.2:3000
class CctvService {
  // Auto-detect the correct base URL based on platform, unless overridden.
  static String get _baseUrl {
    final override = dotenv.env['BACKEND_URL'];
    if (override != null && override.trim().isNotEmpty) {
      return override.trim();
    }
    if (kIsWeb) {
      // Running on web browser — use localhost directly
      return 'http://localhost:3000';
    }
    // Android emulator maps localhost → 10.0.2.2
    return 'http://10.0.2.2:3000';
  }

  /// Whether a document carries a usable GeoJSON point.
  ///
  /// The database is not guaranteed to be uniform: a record can be missing
  /// `location` (or `location.coordinates`) entirely. Consumers index into
  /// `coordinates` directly, so one malformed document used to throw and break
  /// the whole load. Filtering here keeps every consumer safe.
  static bool hasValidLocation(Map<String, dynamic> doc) {
    final location = doc['location'];
    if (location is! Map) return false;
    final coordinates = location['coordinates'];
    if (coordinates is! List || coordinates.length < 2) return false;
    return coordinates[0] is num && coordinates[1] is num;
  }

  /// Fetches all CCTV documents from the MongoDB backend.
  /// Returns documents in the same format as the database:
  /// { status, water_level, location: { type: "Point", coordinates: [lng, lat] }, timestamp }
  ///
  /// Documents without a valid location are dropped, since they cannot be
  /// rendered on the map or used for routing.
  ///
  /// Returns an empty list when the backend is unreachable or has no data.
  static Future<List<Map<String, dynamic>>> fetchCctvData() async {
    final url = '$_baseUrl/api/cctv';
    print('🔌 [CCTV] Connecting to backend: $url');

    try {
      final response = await http.get(
        Uri.parse(url),
        headers: {'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 30));

      print('📡 [CCTV] Response status: ${response.statusCode}');

      if (response.statusCode != 200) {
        print('❌ [CCTV] Bad status code: ${response.statusCode}');
        return <Map<String, dynamic>>[];
      }

      final List<dynamic> json = jsonDecode(response.body) as List<dynamic>;
      print('✅ [CCTV] Received ${json.length} records from database');

      if (json.isEmpty) {
        print('⚠️ [CCTV] Empty response from database');
        return <Map<String, dynamic>>[];
      }

      final records = json.cast<Map<String, dynamic>>();
      final valid = records.where(hasValidLocation).toList();
      if (valid.length != records.length) {
        print('⚠️ [CCTV] Skipped ${records.length - valid.length} '
            'record(s) without valid coordinates');
      }
      return valid;
    } catch (e) {
      // Backend not running or unreachable — return no data so routing depends
      // purely on the live database's flood markers.
      print('❌ [CCTV] Connection failed: $e');
      return <Map<String, dynamic>>[];
    }
  }

  /// Fetches only alert and danger documents from the backend.
  /// Used by the Notification screen.
  /// Returns an empty list when the backend is unreachable or has no data.
  static Future<List<Map<String, dynamic>>> fetchAlerts() async {
    final url = '$_baseUrl/api/alerts';
    print('🔌 [Alerts] Connecting to backend: $url');

    try {
      final response = await http.get(
        Uri.parse(url),
        headers: {'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 30));

      print('📡 [Alerts] Response status: ${response.statusCode}');

      if (response.statusCode != 200) {
        print('❌ [Alerts] Bad status code: ${response.statusCode}');
        return <Map<String, dynamic>>[];
      }

      final List<dynamic> json = jsonDecode(response.body) as List<dynamic>;
      print('✅ [Alerts] Received ${json.length} alert records');

      if (json.isEmpty) return <Map<String, dynamic>>[];

      return json.cast<Map<String, dynamic>>().where(hasValidLocation).toList();
    } catch (e) {
      print('❌ [Alerts] Connection failed: $e');
      return <Map<String, dynamic>>[];
    }
  }

  /// Fetches ALL CCTV documents (normal, alert, danger) for the notification screen.
  /// Returns documents sorted by timestamp descending (newest first).
  /// Returns an empty list when the backend is unreachable or has no data.
  static Future<List<Map<String, dynamic>>> fetchAllNotifications() async {
    // Opt out of the location filter so location-less cameras still surface as
    // notifications (their label comes from `location_name` when present).
    final url = '$_baseUrl/api/cctv?includeWithoutLocation=true';
    print('🔌 [Notifications] Connecting to backend: $url');

    try {
      final response = await http.get(
        Uri.parse(url),
        headers: {'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 30));

      print('📡 [Notifications] Response status: ${response.statusCode}');

      if (response.statusCode != 200) {
        print('❌ [Notifications] Bad status code: ${response.statusCode}');
        return <Map<String, dynamic>>[];
      }

      final List<dynamic> json = jsonDecode(response.body) as List<dynamic>;
      print('✅ [Notifications] Received ${json.length} records');

      if (json.isEmpty) return <Map<String, dynamic>>[];

      // Sort by timestamp descending (newest first)
      json.sort((a, b) {
        final ta = DateTime.tryParse(a['timestamp'] ?? '')?.millisecondsSinceEpoch ?? 0;
        final tb = DateTime.tryParse(b['timestamp'] ?? '')?.millisecondsSinceEpoch ?? 0;
        return tb - ta;
      });

      return json.cast<Map<String, dynamic>>();
    } catch (e) {
      print('❌ [Notifications] Connection failed: $e');
      return <Map<String, dynamic>>[];
    }
  }
}
