import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'dart:ui' as ui;
import '../theme/app_colors.dart';

// ── Data model ───────────────────────────────────────────────────────────────

class CctvLocation {
  final String id;
  final String name;
  final String address;
  final String status; // 'NORMAL' | 'ALERT' | 'DANGER'
  final double floodHeight; // cm
  final String lastUpdated;

  const CctvLocation({
    required this.id,
    required this.name,
    required this.address,
    required this.status,
    required this.floodHeight,
    required this.lastUpdated,
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

// ── Sample data ───────────────────────────────────────────────────────────────

const _locations = [
  CctvLocation(
    id: '1',
    name: 'Gym Lobby',
    address: 'USTP, CM Recto Ave, CDO',
    status: 'NORMAL',
    floodHeight: 18,
    lastUpdated: '2 min ago',
  ),
  CctvLocation(
    id: '2',
    name: 'Lapasan Highway',
    address: 'Lapasan, Cagayan de Oro',
    status: 'DANGER',
    floodHeight: 87,
    lastUpdated: '2 min ago',
  ),
  CctvLocation(
    id: '3',
    name: 'Macabalan Bridge',
    address: 'Macabalan, Cagayan de Oro',
    status: 'ALERT',
    floodHeight: 52,
    lastUpdated: '15 min ago',
  ),
  CctvLocation(
    id: '4',
    name: 'Kauswagan Ave.',
    address: 'Kauswagan, Cagayan de Oro',
    status: 'NORMAL',
    floodHeight: 14,
    lastUpdated: '5 min ago',
  ),
];

// Pin positions (top%, left%) — adjust to match your actual map
const _pinPositions = [
  [0.18, 0.55], // Gym Lobby
  [0.30, 0.25], // Lapasan Highway
  [0.22, 0.72], // Macabalan Bridge
  [0.55, 0.65], // Kauswagan
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

  @override
  void initState() {
    super.initState();
    // Try to center map on user after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _goToCurrentLocation();
    });
  }

  void _onPinTapped(BuildContext context, CctvLocation loc) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _CctvBottomSheet(location: loc),
    );
  }

  // Marker layer omitted — using overlay pins for design preview instead.

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.of(context).padding.top;

    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: LatLng(8.4822, 124.6472), // CDO center
              initialZoom: 14.5,
              minZoom: 10,
              maxZoom: 19,
            ),
            children: [
              TileLayer(
                urlTemplate:
                  'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.subay.app',
              ),
              // MarkerLayer(markers: _buildMarkers()), // removed (using overlay pins)
            ],
          ),
          /*Container(
            color: const Color(0xFFE8E4D9),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: const [
                  Icon(Icons.map, size: 48, color: Color(0xFFBBBBBB)),
                  SizedBox(height: 8),
                  Text(
                    'Replace this with your\nFlutterMap or GoogleMap widget',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Color(0xFF999999), fontSize: 12),
                  ),
                ],
              ),
            ),
          ), */

          // ── CCTV PINS ───────────────────────────────────────────────────────
          // NOTE: In a real map, pins should be placed using the map's marker API.
          // These are screen-relative overlays for design preview only.
          ..._locations.asMap().entries.map((e) {
            final i   = e.key;
            final loc = e.value;
            final pos = _pinPositions[i];
            return Positioned(
              top:  MediaQuery.of(context).size.height * pos[0],
              left: MediaQuery.of(context).size.width  * pos[1],
              child: _CctvPin(
                location: loc,
                onTap: () => _onPinTapped(context, loc),
              ),
            );
          }),

          // ── SEARCH BAR ──────────────────────────────────────────────────────
          Positioned(
            top:   topPad + 8,
            left:  12,
            right: 12,
            child: Material(
              elevation: 3,
              borderRadius: BorderRadius.circular(10),
              child: TextField(
                decoration: const InputDecoration(
                  hintText: 'Search here',
                  hintStyle: TextStyle(color: AppColors.textMuted, fontSize: 14),
                  prefixIcon: Icon(Icons.search, color: AppColors.textMuted, size: 20),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(vertical: 13),
                  fillColor: Colors.white,
                  filled: true,
                ),
              ),
            ),
          ),

          // ── LEGEND ──────────────────────────────────────────────────────────
          Positioned(
            top:   topPad + 64,
            right: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.95),
                borderRadius: BorderRadius.circular(8),
                boxShadow: [
                  BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 4),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  _LegendItem(color: AppColors.danger, label: 'Danger'),
                  SizedBox(height: 4),
                  _LegendItem(color: AppColors.alert,  label: 'Alert'),
                  SizedBox(height: 4),
                  _LegendItem(color: AppColors.normal, label: 'Normal'),
                ],
              ),
            ),
          ),

          // ── FAB ─────────────────────────────────────────────────────────────
          Positioned(
            bottom: 20,
            right:  16,
            child: FloatingActionButton(
              onPressed: _goToCurrentLocation,
              backgroundColor: AppColors.primary,
              child: _isLocating
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                  : const Icon(Icons.my_location, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  Future<Position?> _determinePosition() async {
    final messenger = ScaffoldMessenger.of(context);
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      messenger.showSnackBar(const SnackBar(content: Text('Location services are disabled.')));
      return null;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        messenger.showSnackBar(const SnackBar(content: Text('Location permission denied')));
        return null;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      messenger.showSnackBar(const SnackBar(content: Text('Location permissions are permanently denied. Enable them in settings.')));
      return null;
    }

    try {
      return await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed to get location: $e')));
      return null;
    }
  }

  Future<void> _goToCurrentLocation() async {
    setState(() { _isLocating = true; });
    final pos = await _determinePosition();
    if (pos != null) {
      final latlng = LatLng(pos.latitude, pos.longitude);
      try {
        _mapController.move(latlng, 16);
      } catch (_) {
        // MapController may not be ready; try again after frame
        WidgetsBinding.instance.addPostFrameCallback((_) {
          try { _mapController.move(latlng, 16); } catch (_) {}
        });
      }
    }
    if (!mounted) return;
    setState(() { _isLocating = false; });
  }
}

// ── CCTV Pin ─────────────────────────────────────────────────────────────────

class _CctvPin extends StatelessWidget {
  final CctvLocation location;
  final VoidCallback onTap;

  const _CctvPin({required this.location, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: location.statusColor,
              borderRadius: BorderRadius.circular(8),
              boxShadow: [
                BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 4, offset: const Offset(0, 2)),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.videocam, color: Colors.white, size: 10),
                const SizedBox(width: 3),
                Text(
                  location.status,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 9,
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
      ),
    );
  }
}

class _TrianglePainter extends CustomPainter {
  final Color color;
  const _TrianglePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final path = ui.Path()
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
          width: 8, height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Text(label, style: const TextStyle(fontSize: 10, color: AppColors.textSecondary)),
      ],
    );
  }
}

// ── Bottom Sheet (pin tapped) ─────────────────────────────────────────────────

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
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // drag handle
          Center(
            child: Container(
              width: 32, height: 3,
              decoration: BoxDecoration(
                color: const Color(0xFFDDDDDD),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Header
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 8, height: 8,
                          decoration: BoxDecoration(
                            color: location.statusColor,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          location.name,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        const Icon(Icons.location_on_outlined, size: 12, color: AppColors.textMuted),
                        const SizedBox(width: 3),
                        Text(location.address,
                          style: const TextStyle(fontSize: 11, color: AppColors.textMuted)),
                      ],
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: location.statusLightColor,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  location.status,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: location.statusTextColor,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // CCTV snapshot placeholder
          Container(
            height: 100,
            width: double.infinity,
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A2E),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Stack(
              children: [
                Center(
                  child: Icon(Icons.videocam,
                    color: Colors.white.withOpacity(0.25), size: 36),
                ),
                Positioned(
                  top: 6, left: 6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.red.withOpacity(0.9),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 5, height: 5,
                          decoration: const BoxDecoration(
                            color: Colors.white, shape: BoxShape.circle),
                        ),
                        const SizedBox(width: 3),
                        const Text('LIVE',
                          style: TextStyle(color: Colors.white, fontSize: 8,
                            fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
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
          const SizedBox(height: 10),

          // Action buttons
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () {},
                  icon: const Icon(Icons.route, size: 14),
                  label: const Text('Get Route',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {},
                  icon: const Icon(Icons.videocam_outlined, size: 14),
                  label: const Text('View CCTV',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.primary,
                    side: const BorderSide(color: AppColors.primary, width: 1.5),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                    padding: const EdgeInsets.symmetric(vertical: 10),
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
  final String label;
  final String value;
  final Color bgColor;
  final Color textColor;

  const _StatPill({
    required this.label,
    required this.value,
    required this.bgColor,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
      decoration: BoxDecoration(
        color: bgColor, borderRadius: BorderRadius.circular(8)),
      child: Column(
        children: [
          Text(label,
            style: const TextStyle(fontSize: 9, color: AppColors.textMuted)),
          const SizedBox(height: 2),
          Text(value,
            style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w700, color: textColor)),
        ],
      ),
    );
  }
}