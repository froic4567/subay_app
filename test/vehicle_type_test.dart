import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:subay/services/route_planner.dart';

void main() {
  group('VehicleType water-level thresholds', () {
    test('uses the configured light, medium, and heavy tolerances', () {
      expect(VehicleType.light.maxWaterLevelM, 0.15);
      expect(VehicleType.medium.maxWaterLevelM, 0.25);
      expect(VehicleType.heavy.maxWaterLevelM, 0.65);
    });

    test('allows ALERT water up to each vehicle tolerance', () {
      final alert = RouteNode(
        id: 'alert',
        name: 'Alert',
        roadName: 'Test road',
        location: const LatLng(8.5, 124.6),
        status: 'ALERT',
        waterLevelM: 0.25,
        connectedIds: const [],
      );

      expect(alert.isPassableFor(VehicleType.light), isFalse);
      expect(alert.isPassableFor(VehicleType.medium), isTrue);
      expect(alert.isPassableFor(VehicleType.heavy), isTrue);
    });

    test('blocks DANGER for every vehicle class', () {
      final danger = RouteNode(
        id: 'danger',
        name: 'Danger',
        roadName: 'Test road',
        location: const LatLng(8.5, 124.6),
        status: 'DANGER',
        waterLevelM: 0.1,
        connectedIds: const [],
      );

      for (final vehicle in VehicleType.values) {
        expect(danger.isPassableFor(vehicle), isFalse);
      }
    });
  });
}
