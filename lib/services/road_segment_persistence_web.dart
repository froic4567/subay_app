// Web implementation using window.localStorage

import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;

const _kStorageKey = 'road_segment_cache_v1';

Future<Map<String, dynamic>> loadPersistentRoadSegmentCache() async {
  try {
    final raw = html.window.localStorage[_kStorageKey];
    if (raw == null) return <String, dynamic>{};
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    return decoded;
  } catch (_) {
    return <String, dynamic>{};
  }
}

Future<void> savePersistentRoadSegmentCache(Map<String, dynamic> cache) async {
  try {
    final raw = jsonEncode(cache);
    html.window.localStorage[_kStorageKey] = raw;
  } catch (_) {
    // ignore
  }
}
