import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:geolocator/geolocator.dart';
import '../services/cctv_service.dart';
import '../services/geocoding_service.dart';
import '../services/location_service.dart';
import '../services/road_segment_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_radius.dart';
import '../theme/app_shadows.dart';
import '../widgets/status_badge.dart';

// ── Vehicle passability model ─────────────────────────────────────────────────

class VehicleType {
  final String name;
  final IconData icon;
  final double maxPassableHeight; // meters — above this = unpassable

  const VehicleType({
    required this.name,
    required this.icon,
    required this.maxPassableHeight,
  });

  bool canPass(double waterLevel) => waterLevel <= maxPassableHeight;
}

// Thresholds based on typical vehicle ground clearance + safety margin
const _vehicleTypes = [
  VehicleType(name: 'Bicycle',    icon: Icons.pedal_bike,        maxPassableHeight: 0.15),
  VehicleType(name: 'Motorcycle', icon: Icons.two_wheeler,       maxPassableHeight: 0.25),
  VehicleType(name: 'Sedan / Car',icon: Icons.directions_car,    maxPassableHeight: 0.40),
  VehicleType(name: 'SUV / Van',  icon: Icons.airport_shuttle,   maxPassableHeight: 0.65),
  VehicleType(name: 'Truck / Bus',icon: Icons.local_shipping,    maxPassableHeight: 0.90),
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

// ── Screen ────────────────────────────────────────────────────────────────────

class MapScreen extends StatefulWidget {
  // Callback so the "Get Directions" button can pass the searched destination
  // to the RoutingScreen and switch bottom nav tabs.
  final void Function({LatLng? dest, String? destName})? onGoToRouteWithDestination;

  const MapScreen({super.key, this.onGoToRouteWithDestination});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final MapController _mapController = MapController();
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();
  bool _isLocating = false;
  LatLng? _currentLocation;
  StreamSubscription<Position>? _positionSub;

  // CCTV locations fetched from MongoDB via backend API
  List<CctvLocation> _cctvLocations = [];
  bool _hasLoadedOnce = false;

  // Road segments covered by each camera, keyed by CctvLocation.id.
  // Populated asynchronously via RoadSegmentService and cached there, so
  // repeated polls only refresh status/color, not geometry.
  Map<String, RoadSegmentResult> _roadSegments = {};
  Timer? _statusPollTimer;

  // Search state
  Timer? _searchDebounce;
  List<GeoSearchResult> _searchResults = [];
  bool _isSearching = false;
  bool _showSuggestions = false;

  // Searched destination pin
  LatLng? _searchedLocation;
  String? _searchedName;

  static const LatLng _cdoCenter = LatLng(8.4822, 124.6472);

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    _loadCctvData();
    // Keeps flood status (and therefore segment color) fresh without a
    // manual refresh, mirroring routing_screen.dart's reroute-polling
    // cadence. Road geometry itself is cached in RoadSegmentService, so
    // this only re-fetches status/color on each tick, not geometry.
    _statusPollTimer =
        Timer.periodic(const Duration(seconds: 5), (_) => _loadCctvData());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _goToCurrentLocation();
      _startLocationTracking();
    });
  }

  // ── Load CCTV data from backend API (MongoDB) ─────────────────────────────

  Future<void> _loadCctvData() async {
    print('🗺️ [Map] Loading CCTV data...');
    final docs = await CctvService.fetchCctvData();
    print('🗺️ [Map] Total records to display: ${docs.length}');

    if (mounted) {
      final locations = docs.asMap().entries.map((entry) {
        final cctv = _convertDocToCctv(entry.key, entry.value);
        print('📍 [Map] CCTV #${entry.key + 1}: status=${cctv.status}, '
            'waterLevel=${cctv.floodHeight}m, '
            'position=${cctv.position.latitude},${cctv.position.longitude}');
        return cctv;
      }).toList();
      setState(() {
        _cctvLocations = locations;
        _hasLoadedOnce = true;
      });
      print('✅ [Map] Displaying ${_cctvLocations.length} CCTV markers on map');
      _loadRoadSegments(locations);
    }
  }

  /// Resolves the road segment each camera monitors (via RoadSegmentService,
  /// which caches by coordinate) and updates the map once all lookups
  /// settle. Markers already show from _loadCctvData; this only adds the
  /// road-coloring layer on top a moment later.
  Future<void> _loadRoadSegments(List<CctvLocation> locations) async {
    final entries = await Future.wait(locations.map((loc) async {
      final segment = await RoadSegmentService.getSegmentForCamera(loc.position);
      return MapEntry(loc.id, segment);
    }));
    if (!mounted) return;
    setState(() {
      _roadSegments = {
        for (final entry in entries)
          if (entry.value != null) entry.key: entry.value!,
      };
    });
  }

  /// Converts a MongoDB CCTV document to a CctvLocation.
  CctvLocation _convertDocToCctv(int index, Map<String, dynamic> doc) {
    // Expected document structure:
    // {
    //   "status": "danger|alert|safe",
    //   "water_level": 1.345,          (meters)
    //   "location": {
    //     "type": "Point",
    //     "coordinates": [lng, lat]    (GeoJSON format: longitude first)
    //   },
    //   "timestamp": "2026-07-15T07:30:00Z"
    // }

    final coordinates = doc['location']['coordinates'] as List<dynamic>;
    final longitude = (coordinates[0] as num).toDouble();
    final latitude = (coordinates[1] as num).toDouble();
    final rawStatus = (doc['status'] as String? ?? 'safe').toLowerCase();
    final status = rawStatus == 'danger'
        ? 'DANGER'
        : (rawStatus == 'alert' ? 'ALERT' : 'NORMAL');
    // water_level from database is in meters
    final floodHeight = (doc['water_level'] as num?)?.toDouble() ?? 0;
    final timestamp = doc['timestamp'] as String?;
    final lastUpdated = _formatTimestamp(timestamp);

    print('🔄 [Convert] Doc #$index: raw_status=$rawStatus → $status, '
        'water_level=${floodHeight}m, '
        'coords=[$longitude,$latitude]');

    return CctvLocation(
      id: (index + 1).toString(),
      name: 'CCTV-${(index + 1).toString().padLeft(2, '0')}',
      address: 'Cagayan de Oro',
      status: status,
      floodHeight: floodHeight,
      lastUpdated: lastUpdated,
      position: LatLng(latitude, longitude),
    );
  }

  /// Converts an ISO timestamp to a relative time string.
  String _formatTimestamp(String? timestamp) {
    if (timestamp == null || timestamp.isEmpty) return 'unknown';
    try {
      final dt = DateTime.parse(timestamp);
      final diff = DateTime.now().difference(dt);
      if (diff.inMinutes < 1) return 'just now';
      if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
      if (diff.inHours < 24) return '${diff.inHours} hr ago';
      return '${diff.inDays} day${diff.inDays > 1 ? 's' : ''} ago';
    } catch (_) {
      return 'unknown';
    }
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _statusPollTimer?.cancel();
    _positionSub?.cancel();
    _searchController.dispose();
    _searchFocus.dispose();
    _mapController.dispose();
    super.dispose();
  }

  // ── Debounced search ────────────────────────────────────────────────────────

  void _onSearchChanged() {
    final query = _searchController.text.trim();
    if (query.isEmpty) {
      setState(() {
        _searchResults = [];
        _showSuggestions = false;
        _isSearching = false;
      });
      return;
    }
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 500), () {
      _performSearch(query);
    });
  }

  Future<void> _performSearch(String query) async {
    setState(() {
      _isSearching = true;
      _showSuggestions = true;
    });
    final results = await GeocodingService.searchPlace(query);
    if (mounted) {
      setState(() {
        _searchResults = results;
        _isSearching = false;
      });
    }
  }

  void _selectSearchResult(GeoSearchResult result) {
    setState(() {
      _searchedLocation = result.latLng;
      _searchedName = result.shortName;
      _searchController.text = result.shortName;
      _showSuggestions = false;
      _searchFocus.unfocus();
    });
    _mapController.move(result.latLng, 16);
  }

  void _showSearchedLocationSheet() {
    if (_searchedLocation == null) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xxl)),
        ),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
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
            Row(
              children: [
                Container(
                  width: 9,
                  height: 9,
                  decoration: const BoxDecoration(
                    color: AppColors.routeBlue,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 7),
                Flexible(
                  child: Text(
                    _searchedName ?? 'Searched Location',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Lat: ${_searchedLocation!.latitude.toStringAsFixed(5)}, '
              'Lng: ${_searchedLocation!.longitude.toStringAsFixed(5)}',
              style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () {
                  Navigator.pop(context);
                  widget.onGoToRouteWithDestination?.call(
                    dest: _searchedLocation,
                    destName: _searchedName,
                  );
                },
                icon: const Icon(Icons.route, size: 16),
                label: const Text(
                  'Get Directions',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        ),
      ),
    );
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
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Failed to get location: $e')));
      return null;
    }
  }

  /// Subscribes to a continuous GPS stream so `_currentLocation` (and thus
  /// the "my location" marker) stays live without requiring the location
  /// button to be pressed, regardless of navigation state or which tab is
  /// active — `IndexedStack` in home_screen.dart keeps this screen's state
  /// (and this subscription) alive across tab switches.
  ///
  /// Deliberately never moves the map camera — only `_goToCurrentLocation`
  /// (the button, and the initial center-on-open) does that, so continuous
  /// updates don't fight the user's own panning/zooming.
  Future<void> _startLocationTracking() async {
    final stream = await LocationService.watchPosition(
      accuracy: LocationAccuracy.high,
    );
    if (stream == null || !mounted) return;
    _positionSub = stream.listen((pos) {
      if (!mounted) return;
      setState(() => _currentLocation = LatLng(pos.latitude, pos.longitude));
    });
  }

  Future<void> _goToCurrentLocation() async {
    setState(() => _isLocating = true);

    LatLng? latlng = _currentLocation;
    if (latlng == null) {
      final pos = await _determinePosition();
      if (pos != null) {
        latlng = LatLng(pos.latitude, pos.longitude);
        if (mounted) setState(() => _currentLocation = latlng);
      }
    }

    if (latlng != null && mounted) {
      try {
        _mapController.move(latlng, 16);
      } catch (_) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          try {
            _mapController.move(latlng!, 16);
          } catch (_) {}
        });
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
          // Route to the CCTV location from the map
          widget.onGoToRouteWithDestination?.call(
            dest: loc.position,
            destName: loc.name,
          );
        },
      ),
    );
  }

  // ── Road segments ────────────────────────────────────────────────────────

  List<Polyline> _buildSegmentOutlinePolylines() => [
        for (final loc in _cctvLocations)
          if (_roadSegments[loc.id] != null)
            Polyline(
              points: _roadSegments[loc.id]!.points,
              strokeWidth: 7.0,
              color: AppColors.segmentOutline.withValues(alpha: 0.35),
            ),
      ];

  List<Polyline> _buildSegmentColorPolylines() => [
        for (final loc in _cctvLocations)
          if (_roadSegments[loc.id] != null)
            Polyline(
              points: _roadSegments[loc.id]!.points,
              strokeWidth: 4.0,
              color: loc.statusColor,
            ),
      ];

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

    // Searched destination pin
    if (_searchedLocation != null) {
      markers.add(Marker(
        point: _searchedLocation!,
        width: 44,
        height: 50,
        child: GestureDetector(
          onTap: () => _showSearchedLocationSheet(),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.routeBlue,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.routeBlue.withValues(alpha: 0.35),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.place, color: Colors.white, size: 14),
                    const SizedBox(width: 3),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 100),
                      child: Text(
                        _searchedName ?? 'Location',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              CustomPaint(
                painter: _TrianglePainter(color: AppColors.routeBlue),
                size: const Size(10, 6),
              ),
            ],
          ),
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
              if (_roadSegments.isNotEmpty) ...[
                PolylineLayer(polylines: _buildSegmentOutlinePolylines()),
                PolylineLayer(polylines: _buildSegmentColorPolylines()),
              ],
              MarkerLayer(markers: _buildMarkers()),
            ],
          ),

          // ── SEARCH BAR ────────────────────────────────────────────────────
          Positioned(
            top: topPad + 8,
            left: 12,
            right: 12,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(AppRadius.lg),
                    boxShadow: AppShadows.base,
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: TextField(
                    controller: _searchController,
                    focusNode: _searchFocus,
                    onTap: () {
                      if (_searchController.text.isNotEmpty) {
                        setState(() => _showSuggestions = true);
                      }
                    },
                    decoration: InputDecoration(
                      hintText: 'Search a place',
                      hintStyle:
                          const TextStyle(color: AppColors.textMuted, fontSize: 14),
                      prefixIcon: const Icon(Icons.search,
                          color: AppColors.textMuted, size: 20),
                      suffixIcon: _isSearching
                          ? const Padding(
                              padding: EdgeInsets.all(12),
                              child: SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: AppColors.primary,
                                ),
                              ),
                            )
                          : (_searchController.text.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.close,
                                      color: AppColors.textMuted, size: 18),
                                  onPressed: () {
                                    _searchController.clear();
                                    setState(() {
                                      _searchedLocation = null;
                                      _searchedName = null;
                                      _showSuggestions = false;
                                    });
                                  },
                                )
                              : null),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(vertical: 13),
                      fillColor: Colors.white,
                      filled: true,
                    ),
                  ),
                ),
                // First-load affordance — makes the initial "no markers yet"
                // moment read as loading rather than empty.
                if (!_hasLoadedOnce)
                  Container(
                    margin: const EdgeInsets.only(top: 6),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(AppRadius.lg),
                      boxShadow: AppShadows.sm,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppColors.primary,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Loading flood data…',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: AppColors.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                // Search suggestions dropdown
                if (_showSuggestions && (_searchResults.isNotEmpty || _isSearching))
                  Container(
                    margin: const EdgeInsets.only(top: 4),
                    constraints: const BoxConstraints(maxHeight: 250),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(AppRadius.lg),
                      boxShadow: AppShadows.lg,
                    ),
                    child: _isSearching && _searchResults.isEmpty
                        ? const Padding(
                            padding: EdgeInsets.all(16),
                            child: Center(
                              child: SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: AppColors.primary,
                                ),
                              ),
                            ),
                          )
                        : ListView.separated(
                            shrinkWrap: true,
                            padding: EdgeInsets.zero,
                            itemCount: _searchResults.length,
                            separatorBuilder: (_, _) => const Divider(
                              height: 1,
                              color: AppColors.border,
                              indent: 44,
                            ),
                            itemBuilder: (context, index) {
                              final result = _searchResults[index];
                              return InkWell(
                                onTap: () => _selectSearchResult(result),
                                borderRadius: BorderRadius.circular(10),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 10,
                                  ),
                                  child: Row(
                                    children: [
                                      const Icon(
                                        Icons.location_on_outlined,
                                        size: 18,
                                        color: AppColors.textMuted,
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(
                                              result.shortName,
                                              style: const TextStyle(
                                                fontSize: 13,
                                                fontWeight: FontWeight.w600,
                                                color: AppColors.textPrimary,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            if (result.displayName !=
                                                result.shortName)
                                              Padding(
                                                padding:
                                                    const EdgeInsets.only(top: 2),
                                                child: Text(
                                                  result.displayName,
                                                  style: const TextStyle(
                                                    fontSize: 11,
                                                    color: AppColors.textMuted,
                                                  ),
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
              ],
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
                borderRadius: BorderRadius.circular(AppRadius.md),
                boxShadow: AppShadows.sm,
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
              onPressed: () => widget.onGoToRouteWithDestination?.call(),
              child: const Icon(Icons.route),
            ),
          ),

        ],
      ),
    );
  }
} // ← closes _MapScreenState

// ── CCTV Pin ──────────────────────────────────────────────────────────────────

class _CctvPin extends StatefulWidget {
  final CctvLocation location;
  const _CctvPin({required this.location});

  @override
  State<_CctvPin> createState() => _CctvPinState();
}

class _CctvPinState extends State<_CctvPin> with SingleTickerProviderStateMixin {
  AnimationController? _controller;

  bool get _isDanger => widget.location.status == 'DANGER';

  @override
  void initState() {
    super.initState();
    if (_isDanger) _startPulse();
  }

  void _startPulse() {
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final location = widget.location;
    final pill = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: location.statusColor,
        borderRadius: BorderRadius.circular(AppRadius.md),
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
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _controller == null
            ? pill
            : FadeTransition(
                opacity: Tween(begin: 1.0, end: 0.5).animate(
                  CurvedAnimation(parent: _controller!, curve: Curves.easeInOut),
                ),
                child: pill,
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
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xxl)),
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
              StatusBadge(status: location.status, pulse: true),
            ],
          ),
          const SizedBox(height: 12),

          // ── Water level stat ──────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.infoLight,
              borderRadius: BorderRadius.circular(AppRadius.lg),
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
                      '${location.floodHeight.toStringAsFixed(2)} m',
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
        borderRadius: BorderRadius.circular(AppRadius.md),
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
            '≤ ${vehicle.maxPassableHeight.toStringAsFixed(2)} m',
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
