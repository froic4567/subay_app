import 'dart:convert';

import 'package:flutter/foundation.dart'
    show debugPrint, defaultTargetPlatform, kIsWeb;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

/// Sends routing performance metrics to the backend so they are stored in
/// MongoDB instead of only being visible in the browser/terminal console.
///
/// This is especially important on mobile, where there is no DevTools console
/// to inspect the routing test log.
class RoutingMetricsService {
  RoutingMetricsService._();

  /// Mirrors [CctvService]'s backend URL selection.
  static String get _baseUrl {
    final override = dotenv.env['BACKEND_URL'];
    if (override != null && override.trim().isNotEmpty) {
      return override.trim();
    }
    if (kIsWeb) return 'http://localhost:3000';
    return 'http://10.0.2.2:3000';
  }

  static String get platformName =>
      kIsWeb ? 'web' : defaultTargetPlatform.name;

  /// Fire-and-forget upload of one routing metrics document.
  static Future<void> send(Map<String, dynamic> payload) async {
    final url = '$_baseUrl/api/routing-metrics';
    try {
      final response = await http
          .post(
            Uri.parse(url),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 8));

      if (response.statusCode != 200 && response.statusCode != 201) {
        debugPrint(
          '⚠️ [RoutingMetrics] Backend rejected metrics '
          '(${response.statusCode}): ${response.body}',
        );
      }
    } catch (e) {
      debugPrint('❌ [RoutingMetrics] Failed to upload metrics: $e');
    }
  }
}
