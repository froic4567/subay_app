import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:geolocator/geolocator.dart';
import '../theme/app_colors.dart';

// ── Data model ────────────────────────────────────────────────────────────────

class CctvLocation {
  final String id;
  final String name;
  final String address;
  final String status; // 'NORMAL' | 'ALERT' | 'DANGER'
  final double floodHeight; // cm
  final String lastUpdated;
  final LatLng position; // real map coordinates

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

// ── Sample CCTV data with real CDO coordinates ────────────────────────────────

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
  const MapScreen({super.key});

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
      messenger.showSnackBar(
        const SnackBar(content: Text('Enable location permissions in settings.')));
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
            try { _mapController.move(latlng, 16); } catch (_) {}
          });
        }
      }
    }

    if (mounted) setState(() => _isLocating = false);
  }

  // ── Tap a pin → open bottom sheet ────────────────────────────────────────

  void _onPinTapped(CctvLocation loc) {
    _mapController.move(
      LatLng(loc.position.latitude - 0.003, loc.position.longitude),
      15.5,
    );
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _CctvBottomSheet(location: loc),
    );
  }

  // ── Build all markers ─────────────────────────────────────────────────────

  List<Marker> _buildMarkers() {
    final markers = <Marker>[];

    // CCTV pins — anchored to real LatLng so they follow the map
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

    // Blue user location dot
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

          // ── FLUTTER MAP ──────────────────────────────────────────────────
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
              // Pins are now inside the map — they follow pan & zoom
              MarkerLayer(markers: _buildMarkers()),
            ],
          ),

          // ── SEARCH BAR ───────────────────────────────────────────────────
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
                  hintStyle: TextStyle(
                      color: AppColors.textMuted, fontSize: 14),
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

          // ── MY LOCATION + ROUTE FABS ─────────────────────────────────────
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
              onPressed: () {},
              backgroundColor: AppColors.primary,
              child: const Icon(Icons.route, color: Colors.white),
            ),
          ),

        ],
      ),
    );
  }
} // ← closes _MapScreenState  ✅

// ── CCTV Pin widget ───────────────────────────────────────────────────────────
// These are now outside _MapScreenState — this was the main bug

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
    // Using Flutter's built-in Path (latlong2's Path is hidden via 'hide Path')
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
  const _CctvBottomSheet({required this.location});

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
          // Drag handle
          Center(
            child: Container(
              width: 32,
              height: 3,
              decoration: BoxDecoration(
                color: const Color(0xFFDDDDDD),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 14),

          // Header
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Container(
                        width: 9,
                        height: 9,
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

          // CCTV snapshot placeholder
          Container(
            height: 110,
            width: double.infinity,
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A2E),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Stack(
              children: [
                Center(
                  child: Icon(Icons.videocam,
                    color: Colors.white.withValues(alpha: 0.2), size: 40),
                ),
                Positioned(
                  top: 7, left: 7,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.red.withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Container(
                        width: 5, height: 5,
                        decoration: const BoxDecoration(
                          color: Colors.white, shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 4),
                      const Text('LIVE',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                        )),
                    ]),
                  ),
                ),
                Positioned(
                  bottom: 8, right: 10,
                  child: Text(location.lastUpdated,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.5),
                      fontSize: 10,
                    )),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),

          // Stats row
          Row(
            children: [
              Expanded(child: _StatPill(
                label: 'Water Level',
                value: '${location.floodHeight.toInt()} cm',
                bgColor: AppColors.infoLight,
                textColor: AppColors.infoText,
              )),
              const SizedBox(width: 6),
              Expanded(child: _StatPill(
                label: 'Status',
                value: location.status,
                bgColor: location.statusLightColor,
                textColor: location.statusTextColor,
              )),
              const SizedBox(width: 6),
              Expanded(child: _StatPill(
                label: 'Updated',
                value: location.lastUpdated,
                bgColor: AppColors.backgroundSecondary,
                textColor: AppColors.textSecondary,
              )),
            ],
          ),
          const SizedBox(height: 12),

          // Action buttons
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.route, size: 15),
                  label: const Text('Get Route',
                    style: TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(9)),
                    padding: const EdgeInsets.symmetric(vertical: 11),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {},
                  icon: const Icon(Icons.videocam_outlined, size: 15),
                  label: const Text('View CCTV',
                    style: TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.primary,
                    side: const BorderSide(
                        color: AppColors.primary, width: 1.5),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(9)),
                    padding: const EdgeInsets.symmetric(vertical: 11),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Stat Pill ─────────────────────────────────────────────────────────────────

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