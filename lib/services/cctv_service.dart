import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

/// Fetches CCTV flood monitoring data from the backend API (which connects to MongoDB).
///
/// URL selection:
/// - Web (Chrome): http://localhost:3000
/// - Android emulator: http://10.0.2.2:3000
/// - Physical device: http://your-computer-LAN-IP:3000
class CctvService {
  // Auto-detect the correct base URL based on platform
  static String get _baseUrl {
    if (kIsWeb) {
      // Running on web browser — use localhost directly
      return 'http://localhost:3000';
    }
    // Android emulator maps localhost → 10.0.2.2
    return 'http://10.0.2.2:3000';
  }

  /// Fetches all CCTV documents from the MongoDB backend.
  /// Returns documents in the same format as the database:
  /// { status, water_level, location: { type: "Point", coordinates: [lng, lat] }, timestamp }
  static Future<List<Map<String, dynamic>>> fetchCctvData() async {
    final url = '$_baseUrl/api/cctv';
    print('🔌 [CCTV] Connecting to backend: $url');
    
    try {
      final response = await http.get(
        Uri.parse(url),
        headers: {'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 8));

      print('📡 [CCTV] Response status: ${response.statusCode}');
      
      if (response.statusCode != 200) {
        print('❌ [CCTV] Bad status code: ${response.statusCode}');
        return _fallbackData();
      }

      final List<dynamic> json = jsonDecode(response.body) as List<dynamic>;
      print('✅ [CCTV] Received ${json.length} records from database');
      
      if (json.isEmpty) {
        print('⚠️ [CCTV] Empty response, using fallback data');
        return _fallbackData();
      }

      // Log first record structure for debugging
      if (json.isNotEmpty) {
        print('📋 [CCTV] Sample record: ${json[0]}');
      }

      return json.cast<Map<String, dynamic>>();
    } catch (e) {
      // Backend not running or unreachable — use fallback sample data
      print('❌ [CCTV] Connection failed: $e');
      print('⚠️ [CCTV] Using fallback sample data');
      return _fallbackData();
    }
  }

  /// Fetches only alert and danger documents from the backend.
  /// Used by the Notification screen.
  /// Returns documents in the same format as the database:
  /// { status, water_level, location_name, location: { type: "Point", coordinates: [lng, lat] }, timestamp }
  static Future<List<Map<String, dynamic>>> fetchAlerts() async {
    final url = '$_baseUrl/api/alerts';
    print('🔌 [Alerts] Connecting to backend: $url');
    
    try {
      final response = await http.get(
        Uri.parse(url),
        headers: {'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 8));

      print('📡 [Alerts] Response status: ${response.statusCode}');

      if (response.statusCode != 200) {
        print('❌ [Alerts] Bad status code: ${response.statusCode}');
        return _fallbackAlerts();
      }

      final List<dynamic> json = jsonDecode(response.body) as List<dynamic>;
      print('✅ [Alerts] Received ${json.length} alert records');
      
      if (json.isEmpty) return _fallbackAlerts();

      return json.cast<Map<String, dynamic>>();
    } catch (e) {
      print(' [Alerts] Connection failed: $e');
      return _fallbackAlerts();
    }
  }

  /// Fetches ALL CCTV documents (normal, alert, danger) for the notification screen.
  /// Returns documents sorted by timestamp descending (newest first).
  static Future<List<Map<String, dynamic>>> fetchAllNotifications() async {
    final url = '$_baseUrl/api/cctv';
    print(' [Notifications] Connecting to backend: $url');
    
    try {
      final response = await http.get(
        Uri.parse(url),
        headers: {'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 8));

      print('📡 [Notifications] Response status: ${response.statusCode}');

      if (response.statusCode != 200) {
        print('❌ [Notifications] Bad status code: ${response.statusCode}');
        return _fallbackNotifications();
      }

      final List<dynamic> json = jsonDecode(response.body) as List<dynamic>;
      print('✅ [Notifications] Received ${json.length} records');
      
      if (json.isEmpty) return _fallbackNotifications();

      // Sort by timestamp descending (newest first)
      json.sort((a, b) {
        final ta = DateTime.tryParse(a['timestamp'] ?? '')?.millisecondsSinceEpoch ?? 0;
        final tb = DateTime.tryParse(b['timestamp'] ?? '')?.millisecondsSinceEpoch ?? 0;
        return tb - ta;
      });

      return json.cast<Map<String, dynamic>>();
    } catch (e) {
      print('❌ [Notifications] Connection failed: $e');
      return _fallbackNotifications();
    }
  }

  /// Fallback notifications (all statuses) used when backend is not available.
  static List<Map<String, dynamic>> _fallbackNotifications() => [
    {
      'status': 'danger',
      'water_level': 0.87,
      'location_name': 'Lapasan Highway, CDO',
      'location': {
        'type': 'Point',
        'coordinates': [124.6433, 8.4822],
      },
      'timestamp': '2026-07-16T08:00:00Z',
    },
    {
      'status': 'alert',
      'water_level': 0.52,
      'location_name': 'Macabalan, CDO',
      'location': {
        'type': 'Point',
        'coordinates': [124.6493, 8.4857],
      },
      'timestamp': '2026-07-16T07:47:00Z',
    },
    {
      'status': 'safe',
      'water_level': 0.18,
      'location_name': 'Kauswagan, CDO',
      'location': {
        'type': 'Point',
        'coordinates': [124.6476, 8.4872],
      },
      'timestamp': '2026-07-16T07:02:00Z',
    },
    {
      'status': 'danger',
      'water_level': 0.95,
      'location_name': 'Camaman-an, CDO',
      'location': {
        'type': 'Point',
        'coordinates': [124.6530, 8.4838],
      },
      'timestamp': '2026-07-16T06:30:00Z',
    },
    {
      'status': 'safe',
      'water_level': 0.05,
      'location_name': 'Bugo, CDO',
      'location': {
        'type': 'Point',
        'coordinates': [124.6501, 8.4818],
      },
      'timestamp': '2026-07-16T06:00:00Z',
    },
    {
      'status': 'alert',
      'water_level': 0.30,
      'location_name': 'Agusan, CDO',
      'location': {
        'type': 'Point',
        'coordinates': [124.6512, 8.4900],
      },
      'timestamp': '2026-07-16T05:30:00Z',
    },
  ];

  /// Fallback alerts (alert + danger only) used when backend is not available.
  static List<Map<String, dynamic>> _fallbackAlerts() => _fallbackNotifications()
      .where((d) => d['status'] == 'alert' || d['status'] == 'danger')
      .toList();

  /// Sample data used as fallback when the backend is not available.
  /// Matches the MongoDB document structure.
  static List<Map<String, dynamic>> _fallbackData() => _fallbackNotifications();
}
