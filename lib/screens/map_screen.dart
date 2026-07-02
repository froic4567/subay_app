import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:geolocator/geolocator.dart';
import '../theme/app_colors.dart';

// ── Vehicle passability model ─────────────────────────────────────────────────

class VehicleType {
  final String name;
  final IconData icon;
  final double maxPassableHeight; // cm — above this = unpassable

  const VehicleType({
    required this.name,
    required this.icon,
    required this.maxPassableHeight,
  });

  bool canPass(double waterLevel) => waterLevel <= maxPassableHeight;
}

// Thresholds based on typical vehicle ground clearance + safety margin
const _vehicleTypes = [
  VehicleType(name: 'Bicycle',    icon: Icons.pedal_bike,        maxPassableHeight: 15),
  VehicleType(name: 'Motorcycle', icon: Icons.two_wheeler,       maxPassableHeight: 25),
  VehicleType(name: 'Sedan / Car',icon: Icons.directions_car,    maxPassableHeight: 40),
  VehicleType(name: 'SUV / Van',  icon: Icons.airport_shuttle,   maxPassableHeight: 65),
  VehicleType(name: 'Truck / Bus',icon: Icons.local_shipping,    maxPassableHeight: 90),
];

// ── Data model ────────────────────────────────────────────────────────────────

class CctvLocation {
  final String id;
  final String name;
  final String address;
  final String status;
  final double floodHeight;
  final String lastUpdated;
  final LatLng position;

  const CctvLocation({
    required this.id,
    required this.name,
    required this.address,
    required this.status,
    required this.floodHeight,
    required this.lastUpdated,
    required this.position,
  });

  Color get statusColor {
    switch (status) {
      case 'DANGER': return AppColors.danger;
      case 'ALERT':  return AppColors.alert;
      default:       return AppColors.normal;
    }
  }

  Color get statusLightColor {
    switch (status) {
      case 'DANGER': return AppColors.dangerLight;
      case 'ALERT':  return AppColors.alertLight;
      default:       return AppColors.normalLight;
    }
  }

  Color get statusTextColor {
    switch (status) {
      case 'DANGER': return AppColors.dangerText;
      case 'ALERT':  return AppColors.alertText;
      default:       return AppColors.normalText;
    }
  }
}

// ── Sample CCTV data ──────────────────────────────────────────────────────────

final List<CctvLocation> _cctvLocations = [
  CctvLocation(
    id: '1',
    name: 'Gym Lobby',
    address: 'USTP, CM Recto Ave, CDO',
    status: 'NORMAL',
    floodHeight: 18,
    lastUpdated: '2 min ago',
    position: const LatLng(8.4838, 124.6565),
  ),
  CctvLocation(
    id: '2',
    name: 'Lapasan Highway',
    address: 'Lapasan, Cagayan de Oro',
    status: 'DANGER',
    floodHeight: 87,
    lastUpdated: '2 min ago',
    position: const LatLng(8.4922, 124.6601),
  ),
  CctvLocation(
    id: '3',
    name: 'Macabalan Bridge',
    address: 'Macabalan, Cagayan de Oro',
    status: 'ALERT',
    floodHeight: 52,
    lastUpdated: '15 min ago',
    position: const LatLng(8.4963, 124.6523),
  ),
  CctvLocation(
    id: '4',
    name: 'Kauswagan Ave.',
    address: 'Kauswagan, Cagayan de Oro',
    status: 'NORMAL',
    floodHeight: 14,
    lastUpdated: '5 min ago',
    position: const LatLng(8.4791, 124.6657),
  ),
];

// ── Screen ────────────────────────────────────────────────────────────────────

class MapScreen extends StatefulWidget {
  // Callback so the "Go to Route" button can switch bottom nav tabs
  final VoidCallback? onGoToRoute;

  const MapScreen({super.key, this.onGoToRoute});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final MapController _mapController = MapController();
  bool _isLocating = false;
  LatLng? _currentLocation;

  static const LatLng _cdoCenter = LatLng(8.4822, 124.6472);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _goToCurrentLocation();
    });
  }

  // ── GPS ───────────────────────────────────────────────────────────────────

  Future<Position?> _determinePosition() async {
    final messenger = ScaffoldMessenger.of(context);

    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Location services are disabled.')));
      return null;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Location permission denied.')));
        return null;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      messenger.showSnackBar(const SnackBar(
        content: Text('Enable location permissions in settings.')));
      return null;
    }

    try {
      return await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Failed to get location: $e')));
      return null;
    }
  }

  Future<void> _goToCurrentLocation() async {
    setState(() => _isLocating = true);

    final pos = await _determinePosition();
    if (pos != null) {
      final latlng = LatLng(pos.latitude, pos.longitude);
      if (mounted) {
        setState(() => _currentLocation = latlng);
        try {
          _mapController.move(latlng, 16);
        } catch (_) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            try {
              _mapController.move(latlng, 16);
            } catch (_) {}
          });
        }
      }
    }

    if (mounted) setState(() => _isLocating = false);
  }

  // ── Pin tapped ────────────────────────────────────────────────────────────

  void _onPinTapped(CctvLocation loc) {
    _mapController.move(
      LatLng(loc.position.latitude - 0.003, loc.position.longitude),
      15.5,
    );
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _CctvBottomSheet(
        location: loc,
        onGoToRoute: () {
          Navigator.pop(context); // close bottom sheet first
          widget.onGoToRoute?.call(); // then switch tab
        },
      ),
    );
  }

  // ── Markers ───────────────────────────────────────────────────────────────

  List<Marker> _buildMarkers() {
    final markers = <Marker>[];

    for (final loc in _cctvLocations) {
      markers.add(Marker(
        point: loc.position,
        width: 90,
        height: 44,
        child: GestureDetector(
          onTap: () => _onPinTapped(loc),
          child: _CctvPin(location: loc),
        ),
      ));
    }

    if (_currentLocation != null) {
      markers.add(Marker(
        point: _currentLocation!,
        width: 40,
        height: 40,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: const Color(0xFF4A90E2).withValues(alpha: 0.18),
                shape: BoxShape.circle,
              ),
            ),
            Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                color: const Color(0xFF4A90E2),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2.5),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF4A90E2).withValues(alpha: 0.4),
                    blurRadius: 6,
                  ),
                ],
              ),
            ),
          ],
        ),
      ));
    }

    return markers;
  }

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.of(context).padding.top;

    return Scaffold(
      body: Stack(
        children: [

          // ── MAP ───────────────────────────────────────────────────────────
          FlutterMap(
            mapController: _mapController,
            options: const MapOptions(
              initialCenter: _cdoCenter,
              initialZoom: 14.5,
              minZoom: 10,
              maxZoom: 19,
            ),
            children: [
              TileLayer(
                urlTemplate:
                    'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.subay.app',
                maxZoom: 19,
              ),
              MarkerLayer(markers: _buildMarkers()),
            ],
          ),

          // ── SEARCH BAR ────────────────────────────────────────────────────
          Positioned(
            top: topPad + 8,
            left: 12,
            right: 12,
            child: Material(
              elevation: 3,
              borderRadius: BorderRadius.circular(10),
              child: const TextField(
                decoration: InputDecoration(
                  hintText: 'Search here',
                  hintStyle:
                      TextStyle(color: AppColors.textMuted, fontSize: 14),
                  prefixIcon: Icon(Icons.search,
                      color: AppColors.textMuted, size: 20),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(vertical: 13),
                  fillColor: Colors.white,
                  filled: true,
                ),
              ),
            ),
          ),

          // ── LEGEND ───────────────────────────────────────────────────────
          Positioned(
            top: topPad + 64,
            right: 12,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.95),
                borderRadius: BorderRadius.circular(8),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.1),
                    blurRadius: 4,
                  ),
                ],
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _LegendItem(color: AppColors.danger, label: 'Danger'),
                  SizedBox(height: 4),
                  _LegendItem(color: AppColors.alert, label: 'Alert'),
                  SizedBox(height: 4),
                  _LegendItem(color: AppColors.normal, label: 'Normal'),
                ],
              ),
            ),
          ),

          // ── MY LOCATION + ROUTE FABS ──────────────────────────────────────
          Positioned(
            bottom: 86,
            right: 14,
            child: FloatingActionButton.small(
              heroTag: 'loc',
              onPressed: _goToCurrentLocation,
              backgroundColor: Colors.white,
              elevation: 3,
              child: _isLocating
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: AppColors.primary),
                    )
                  : const Icon(Icons.my_location,
                      color: AppColors.primary, size: 20),
            ),
          ),
          Positioned(
            bottom: 20,
            right: 14,
            child: FloatingActionButton(
              heroTag: 'route',
              onPressed: widget.onGoToRoute,
              backgroundColor: AppColors.primary,
              child: const Icon(Icons.route, color: Colors.white),
            ),
          ),

        ],
      ),
    );
  }
} // ← closes _MapScreenState

// ── CCTV Pin ──────────────────────────────────────────────────────────────────

class _CctvPin extends StatelessWidget {
  final CctvLocation location;
  const _CctvPin({required this.location});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            color: location.statusColor,
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              BoxShadow(
                color: location.statusColor.withValues(alpha: 0.35),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.videocam, color: Colors.white, size: 11),
              const SizedBox(width: 3),
              Text(
                location.status,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
        CustomPaint(
          painter: _TrianglePainter(color: location.statusColor),
          size: const Size(10, 6),
        ),
      ],
    );
  }
}

class _TrianglePainter extends CustomPainter {
  final Color color;
  const _TrianglePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_) => false;
}

// ── Legend Item ───────────────────────────────────────────────────────────────

class _LegendItem extends StatelessWidget {
  final Color color;
  final String label;
  const _LegendItem({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Text(label,
            style: const TextStyle(
                fontSize: 10, color: AppColors.textSecondary)),
      ],
    );
  }
}

// ── CCTV Bottom Sheet ─────────────────────────────────────────────────────────

class _CctvBottomSheet extends StatelessWidget {
  final CctvLocation location;
  final VoidCallback onGoToRoute;

  const _CctvBottomSheet({
    required this.location,
    required this.onGoToRoute,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [

          // ── Drag handle ───────────────────────────────────────────────────
          Center(
            child: Container(
              width: 32, height: 3,
              decoration: BoxDecoration(
                color: const Color(0xFFDDDDDD),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 14),

          // ── Header: name + address + status badge ─────────────────────────
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Container(
                        width: 9, height: 9,
                        decoration: BoxDecoration(
                          color: location.statusColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 7),
                      Flexible(
                        child: Text(location.name,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textPrimary,
                          )),
                      ),
                    ]),
                    const SizedBox(height: 4),
                    Row(children: [
                      const Icon(Icons.location_on_outlined,
                          size: 12, color: AppColors.textMuted),
                      const SizedBox(width: 3),
                      Flexible(
                        child: Text(location.address,
                          style: const TextStyle(
                              fontSize: 11, color: AppColors.textMuted)),
                      ),
                    ]),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: location.statusLightColor,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(location.status,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: location.statusTextColor,
                  )),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // ── Water level stat ──────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.infoLight,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                const Icon(Icons.water_drop_outlined,
                    color: AppColors.infoText, size: 18),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Current Water Level',
                      style: TextStyle(
                          fontSize: 10, color: AppColors.textMuted)),
                    Text(
                      '${location.floodHeight.toInt()} cm',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: AppColors.infoText,
                      ),
                    ),
                  ],
                ),
                const Spacer(),
                Text(
                  'Updated ${location.lastUpdated}',
                  style: const TextStyle(
                      fontSize: 10, color: AppColors.textMuted),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // ── Vehicle passability list ──────────────────────────────────────
          const Text(
            'Vehicle Passability',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 6),

          // Grid of vehicle rows
          ..._vehicleTypes.map((v) =>
            _VehicleRow(vehicle: v, waterLevel: location.floodHeight)),

          const SizedBox(height: 14),

          // ── Single action button: Go to Route ─────────────────────────────
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: onGoToRoute,
              icon: const Icon(Icons.route, size: 16),
              label: const Text(
                'Go to Route',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
                padding: const EdgeInsets.symmetric(vertical: 13),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Vehicle Row ───────────────────────────────────────────────────────────────

class _VehicleRow extends StatelessWidget {
  final VehicleType vehicle;
  final double waterLevel;

  const _VehicleRow({required this.vehicle, required this.waterLevel});

  @override
  Widget build(BuildContext context) {
    final passable = vehicle.canPass(waterLevel);
    final Color bgColor   = passable ? AppColors.normalLight  : AppColors.dangerLight;
    final Color iconColor = passable ? AppColors.normalText   : AppColors.dangerText;
    final Color textColor = passable ? AppColors.normalText   : AppColors.dangerText;
    final String statusLabel = passable ? 'Passable'   : 'Unpassable';
    final IconData statusIcon = passable ? Icons.check_circle_outline
                                         : Icons.cancel_outlined;

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        children: [
          Icon(vehicle.icon, size: 18, color: iconColor),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              vehicle.name,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          // Threshold hint
          Text(
            '≤ ${vehicle.maxPassableHeight.toInt()} cm',
            style: const TextStyle(
                fontSize: 10, color: AppColors.textMuted),
          ),
          const SizedBox(width: 8),
          Row(
            children: [
              Icon(statusIcon, size: 14, color: textColor),
              const SizedBox(width: 3),
              Text(
                statusLabel,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: textColor,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Stat Pill (kept for reference, no longer used in bottom sheet) ─────────────

class _StatPill extends StatelessWidget {
  final String label, value;
  final Color bgColor, textColor;

  const _StatPill({
    required this.label,
    required this.value,
    required this.bgColor,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 8),
      decoration: BoxDecoration(
          color: bgColor, borderRadius: BorderRadius.circular(8)),
      child: Column(children: [
        Text(label,
            style: const TextStyle(
                fontSize: 9, color: AppColors.textMuted)),
        const SizedBox(height: 2),
        Text(value,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: textColor,
            )),
      ]),
    );
  }
}