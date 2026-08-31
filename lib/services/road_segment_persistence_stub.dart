// Stub persistence for non-web platforms.
// Methods are no-ops so the app behaves the same on mobile/desktop.

import 'dart:async';

Future<Map<String, dynamic>> loadPersistentRoadSegmentCache() async {
  return <String, dynamic>{};
}

Future<void> savePersistentRoadSegmentCache(Map<String, dynamic> cache) async {
  // no-op on non-web
}
