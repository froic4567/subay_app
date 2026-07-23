import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import '../services/cctv_service.dart';
import '../services/geocoding_service.dart';
import '../services/route_planner.dart';
import '../theme/app_colors.dart';

class RoutingScreen extends StatefulWidget {
  final LatLng? initialDestination;
  final String? initialDestinationName;

  const RoutingScreen({
    super.key,
    this.initialDestination,
    this.initialDestinationName,
  });

  @override
  State<RoutingScreen> createState() => _RoutingScreenState();
}

class _RoutingScreenState extends State<RoutingScreen> {
  final _destController = TextEditingController();
  final _originController = TextEditingController();
  final _mapController = MapController();
  bool _routeFound = false;
  bool _selectingOrigin = false;
  bool _selectingDestination = false;
  bool _navigationStarted = false;
  bool _isRouting = false;
  LatLng? _originLatLng;
  LatLng? _destLatLng;
  VehicleType _selectedVehicleType = VehicleType.sedan;
  RoutePlanResult? _routePlanResult;

  // CCTV data fetched from MongoDB via backend API
  List<Map<String, dynamic>> _cctvDocs = [];

  // Search state
  Timer? _originDebounce;
  Timer? _destDebounce;
  // Periodically re-checks flood conditions and reroutes if they change.
  Timer? _rerouteTimer;
  List<GeoSearchResult> _originResults = [];
  List<GeoSearchResult> _destResults = [];
  bool _originSearching = false;
  bool _destSearching = false;
  // Which field's suggestion overlay is visible
  bool _showOriginSuggestions = false;
  bool _showDestSuggestions = false;
  // Suppresses search when we programmatically set text (e.g. reverse geocoding)
  bool _suppressOriginSearch = false;
  bool _suppressDestSearch = false;

  // Default location (Cagayan de Oro, Philippines)
  final LatLng _defaultLocation = LatLng(8.4866, 124.6500);

  @override
  void initState() {
    super.initState();
    _originController.addListener(_onOriginChanged);
    _destController.addListener(_onDestChanged);

    // Fetch CCTV data from backend API
    _loadCctvData();

    // Pre-fill destination when coming from MapScreen
    if (widget.initialDestination != null) {
      _destLatLng = widget.initialDestination;
      _destController.text = widget.initialDestinationName ?? 'Destination';
      // Auto-route after the first frame if origin is available
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_originLatLng != null && _destLatLng != null) {
          _buildRoute();
        }
      });
    }
  }

  @override
  void dispose() {
    _originDebounce?.cancel();
    _destDebounce?.cancel();
    _rerouteTimer?.cancel();
    _destController.dispose();
    _originController.dispose();
    _mapController.dispose();
    super.dispose();
  }

  Future<void> _loadCctvData() async {
    final docs = await CctvService.fetchCctvData();
    if (mounted) {
      setState(() => _cctvDocs = docs);
    }
  }

  // ── Debounced search handlers ────────────────────────────────────────────

  void _onOriginChanged() {
    if (_selectingOrigin || _suppressOriginSearch) return; // skip while pin-selecting or programmatic
    final query = _originController.text.trim();
    if (query.isEmpty || query == 'Current location' || query == 'Pinned Location') {
      setState(() {
        _originResults = [];
        _showOriginSuggestions = false;
        _originSearching = false;
      });
      return;
    }
    _originDebounce?.cancel();
    _originDebounce = Timer(const Duration(milliseconds: 500), () {
      _searchOrigin(query);
    });
  }

  void _onDestChanged() {
    if (_selectingDestination || _suppressDestSearch) return;
    final query = _destController.text.trim();
    if (query.isEmpty || query == 'Pinned Location') {
      setState(() {
        _destResults = [];
        _showDestSuggestions = false;
        _destSearching = false;
      });
      return;
    }
    _destDebounce?.cancel();
    _destDebounce = Timer(const Duration(milliseconds: 500), () {
      _searchDest(query);
    });
  }

  Future<void> _searchOrigin(String query) async {
    setState(() {
      _originSearching = true;
      _showOriginSuggestions = true;
    });
    final results = await GeocodingService.searchPlace(query);
    if (mounted) {
      setState(() {
        _originResults = results;
        _originSearching = false;
      });
    }
  }

  Future<void> _searchDest(String query) async {
    setState(() {
      _destSearching = true;
      _showDestSuggestions = true;
    });
    final results = await GeocodingService.searchPlace(query);
    if (mounted) {
      setState(() {
        _destResults = results;
        _destSearching = false;
      });
    }
  }

  void _selectOriginResult(GeoSearchResult result) {
    _suppressOriginSearch = true;
    setState(() {
      _originLatLng = result.latLng;
      _originController.text = result.shortName;
      _originResults = [];
      _showOriginSuggestions = false;
    });
    _suppressOriginSearch = false;
    _mapController.move(result.latLng, 15);
    if (_destLatLng != null) {
      _buildRoute();
    }
  }

  void _selectDestResult(GeoSearchResult result) {
    _suppressDestSearch = true;
    setState(() {
      _destLatLng = result.latLng;
      _destController.text = result.shortName;
      _destResults = [];
      _showDestSuggestions = false;
    });
    _suppressDestSearch = false;
    _mapController.move(result.latLng, 15);
    if (_originLatLng != null) {
      _buildRoute();
    }
  }

  Future<void> _useCurrentLocation() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        _showLocationMessage('Please enable location services to use your current location.');
        return;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        _showLocationMessage('Location permission is required to use your current location.');
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );

      if (!mounted) return;

      final latlng = LatLng(position.latitude, position.longitude);
      _suppressOriginSearch = true;
      setState(() {
        _originLatLng = latlng;
        _originController.text = 'Current location';
        _selectingOrigin = false;
        _selectingDestination = false;
      });
      _suppressOriginSearch = false;
      _mapController.move(latlng, 16);

      // Reverse-geocode for a readable address label
      final address = await GeocodingService.reverseGeocode(latlng)
          .timeout(const Duration(seconds: 5), onTimeout: () => 'Current location');
      if (!mounted) return;
      _suppressOriginSearch = true;
      setState(() {
        _originController.text = address;
      });
      _suppressOriginSearch = false;
    } catch (_) {
      if (!mounted) return;
      _showLocationMessage('Unable to fetch your current location right now.');
    }
  }

  void _fitRouteToMap(List<LatLng> points) {
    if (points.length < 2) {
      return;
    }

    // Filter out any invalid coordinates just in case
    final validPoints = points.where((p) =>
        p.latitude.abs() <= 90 && p.longitude.abs() <= 180).toList();
    if (validPoints.length < 2) {
      return;
    }

    try {
      final bounds = LatLngBounds.fromPoints(validPoints);
      _mapController.fitCamera(
        CameraFit.bounds(
          bounds: bounds,
          padding: const EdgeInsets.all(72),
        ),
      );
    } catch (_) {
      // If bounds calculation fails, just center on the midpoint
      final mid = validPoints[validPoints.length ~/ 2];
      _mapController.move(mid, 14);
    }
  }

  void _showLocationMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _buildRoute() async {
    final origin = _originLatLng ?? _defaultLocation;
    final destination = _destLatLng ?? _defaultLocation;

    if (origin.latitude == destination.latitude && origin.longitude == destination.longitude) {
      _showLocationMessage('Choose a different destination before routing.');
      return;
    }

    // Collapse suggestions while routing
    setState(() {
      _isRouting = true;
      _showOriginSuggestions = false;
      _showDestSuggestions = false;
      _routeFound = false;
    });

    final result = await RoutePlanner.planRoute(
      origin: origin,
      destination: destination,
      vehicleType: _selectedVehicleType,
    );

    if (!mounted) return;

    setState(() {
      _routePlanResult = result;
      _routeFound = result != null;
      _isRouting = false;
    });

    if (result != null) {
      _fitRouteToMap(result.polyline);
      _startFloodPolling();
      if (!result.isFullySafe && result.warningMessage != null) {
        _showLocationMessage(result.warningMessage!);
      }
    } else {
      _stopFloodPolling();
      _showLocationMessage('No safe route was found for this vehicle type.');
    }
  }

  /// Begins polling flood conditions so the route updates itself when a CCTV
  /// point changes status while the user is viewing/navigating a route.
  void _startFloodPolling() {
    _rerouteTimer?.cancel();
    _rerouteTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _checkForReroute(),
    );
  }

  void _stopFloodPolling() {
    _rerouteTimer?.cancel();
    _rerouteTimer = null;
  }

  Future<void> _checkForReroute() async {
    if (_routePlanResult == null) return;

    final origin = _originLatLng ?? _defaultLocation;
    final destination = _destLatLng ?? _defaultLocation;
    if (origin.latitude == destination.latitude &&
        origin.longitude == destination.longitude) {
      return;
    }

    final newResult = await RoutePlanner.planRoute(
      origin: origin,
      destination: destination,
      vehicleType: _selectedVehicleType,
    );
    if (!mounted || newResult == null) return;

    final previous = _routePlanResult;
    // Only surface an update when the safety picture meaningfully changed.
    final changed = previous == null ||
        newResult.isFullySafe != previous.isFullySafe ||
        newResult.warningMessage != previous.warningMessage ||
        newResult.polyline.length != previous.polyline.length;
    if (!changed) return;

    setState(() {
      _routePlanResult = newResult;
      _routeFound = true;
    });
    _showRerouteSnackbar();
  }

  void _showRerouteSnackbar() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Route updated due to new flood conditions.'),
        backgroundColor: Colors.orange,
        duration: Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.of(context).padding.top;

    // Build markers list from CCTV data (fetched from MongoDB)
    final markers = <Marker>[];
    for (final cctv in _cctvDocs) {
      final coordinates = cctv['location']['coordinates'] as List<dynamic>;
      final longitude = coordinates[0] as num;
      final latitude = coordinates[1] as num;
      final status = (cctv['status'] as String).toLowerCase();
      final color = status == 'danger'
          ? AppColors.danger
          : (status == 'alert' ? AppColors.alert : AppColors.normal);

      markers.add(
        Marker(
          point: LatLng(latitude.toDouble(), longitude.toDouble()),
          width: 30,
          height: 30,
          child: Icon(Icons.videocam_rounded, color: color, size: 24),
        ),
      );
    }
    if (_originLatLng != null) {
      markers.add(
        Marker(
          point: _originLatLng!,
          width: 40,
          height: 40,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: AppColors.routeBlue.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
              ),
              Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  color: AppColors.routeBlue,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 3),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.routeBlue.withValues(alpha: 0.4),
                      blurRadius: 6,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }
    if (_destLatLng != null) {
      markers.add(
        Marker(
          point: _destLatLng!,
          width: 40,
          height: 40,
          child: Icon(
            Icons.location_on,
            color: AppColors.danger,
            size: 36,
          ),
        ),
      );
    }

    final routePolyline = _routePlanResult?.polyline ?? const <LatLng>[];

    return Scaffold(
      body: Stack(
        children: [
          // ── FLUTTER MAP ──────────────────────────────────────────────────────
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _defaultLocation,
              initialZoom: 15,
            ),
            children: [
              // Tile layer
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.subay',
              ),
              // Markers layer
              MarkerLayer(markers: markers),
              if (routePolyline.length > 1) ...[
                // Dark outline behind the blue line (Google Maps style)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: routePolyline,
                      strokeWidth: 8.0,
                      color: AppColors.routeBlueDark,
                    ),
                  ],
                ),
                // Blue route line on top
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: routePolyline,
                      strokeWidth: 5.0,
                      color: AppColors.routeBlue,
                    ),
                  ],
                ),
              ],
            ],
          ),

          if (_selectingOrigin || _selectingDestination)
            // Center crosshair / pin marker shown while selecting
            Positioned.fill(
              child: IgnorePointer(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.push_pin,
                        size: 40,
                        color: _selectingOrigin ? AppColors.primary : AppColors.danger,
                        shadows: [
                          Shadow(
                            color: Colors.black.withValues(alpha: 0.4),
                            blurRadius: 4,
                          ),
                        ],
                      ),
                      Container(
                        width: 4,
                        height: 4,
                        decoration: BoxDecoration(
                          color: _selectingOrigin ? AppColors.primary : AppColors.danger,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          if (_selectingOrigin || _selectingDestination)
            Positioned(
              bottom: 24,
              left: 20,
              right: 20,
              child: ElevatedButton(
                onPressed: () async {
                  final center = _mapController.camera.center;
                  final wasSelectingOrigin = _selectingOrigin;

                  // Immediately set coordinates and exit selecting mode
                  if (wasSelectingOrigin) {
                    _suppressOriginSearch = true;
                  } else {
                    _suppressDestSearch = true;
                  }
                  setState(() {
                    if (wasSelectingOrigin) {
                      _originLatLng = center;
                      _originController.text = 'Pinned Location';
                      _selectingOrigin = false;
                    } else {
                      _destLatLng = center;
                      _destController.text = 'Pinned Location';
                      _selectingDestination = false;
                    }
                  });

                  // Try to reverse-geocode for a readable address (with timeout)
                  try {
                    final address = await GeocodingService.reverseGeocode(center)
                        .timeout(const Duration(seconds: 5), onTimeout: () => 'Pinned Location');
                    if (!mounted) return;
                    setState(() {
                      if (wasSelectingOrigin) {
                        _originController.text = address;
                      } else {
                        _destController.text = address;
                      }
                    });
                  } catch (_) {
                    // keep 'Pinned Location' as fallback
                  }
                  if (wasSelectingOrigin) {
                    _suppressOriginSearch = false;
                  } else {
                    _suppressDestSearch = false;
                  }

                  if (_originLatLng != null && _destLatLng != null) {
                    _buildRoute();
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: _selectingOrigin ? AppColors.primary : AppColors.danger,
                  padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 16),
                  elevation: 8,
                  shadowColor: (_selectingOrigin ? AppColors.primary : AppColors.danger).withValues(alpha: 0.4),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text(
                  'Confirm Location',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ),

          // ── ROUTING LOADING OVERLAY ──────────────────────────────────────
          if (_isRouting)
            Positioned.fill(
              child: Container(
                color: Colors.black.withValues(alpha: 0.3),
                child: const Center(
                  child: CircularProgressIndicator(
                    color: Colors.white,
                    strokeWidth: 3,
                  ),
                ),
              ),
            ),

          if (_navigationStarted) ...[
            // ── TOP: compact destination bar ──────────────────────────────────
            Positioned(
              top: topPad + 8,
              left: 12,
              right: 12,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.95),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.2),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    const Icon(Icons.navigation_rounded, color: Colors.white, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text(
                            'Navigating to',
                            style: TextStyle(color: Colors.white70, fontSize: 10),
                          ),
                          Text(
                            _destController.text.isNotEmpty
                                ? _destController.text
                                : 'Destination',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // ── BOTTOM: navigation info bar ────────────────────────────────────
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
                  boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 14)],
                ),
                child: Row(
                  children: [
                    // ETA - large
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _routePlanResult?.etaText ?? '--',
                          style: const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w800,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _routePlanResult != null
                              ? '${_routePlanResult!.distanceKm.toStringAsFixed(1)} km'
                              : '',
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.textMuted,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(width: 16),
                    // Vehicle type indicator
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: AppColors.backgroundSecondary,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(_selectedVehicleType.icon, size: 16, color: AppColors.primary),
                          const SizedBox(width: 4),
                          Text(
                            _selectedVehicleType.label,
                            style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                          ),
                        ],
                      ),
                    ),
                    const Spacer(),
                    // End Navigation button
                    ElevatedButton.icon(
                      onPressed: () {
                        setState(() {
                          _navigationStarted = false;
                          _routeFound = true;
                        });
                      },
                      icon: const Icon(Icons.stop_rounded, size: 18),
                      label: const Text(
                        'End',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.danger,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // ── RE-CENTER BUTTON ────────────────────────────────────────────────
            Positioned(
              bottom: 100,
              right: 14,
              child: FloatingActionButton.small(
                heroTag: 'recenter',
                onPressed: () {
                  final focusPoint = _originLatLng ?? _defaultLocation;
                  _mapController.move(focusPoint, 17);
                },
                backgroundColor: Colors.white,
                elevation: 3,
                child: const Icon(Icons.my_location, color: AppColors.primary, size: 20),
              ),
            ),
          ],

          // ── CAMERA BUTTON (top-right) — hidden during navigation ──────────
          if (!_navigationStarted)
          Positioned(
            top: topPad + 60,
            right: 16,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.15),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Camera feature opening...'),
                        duration: Duration(milliseconds: 1500),
                      ),
                    );
                  },
                  customBorder: const CircleBorder(),
                  splashColor: AppColors.primary.withValues(alpha: 0.2),
                  child: const Padding(
                    padding: EdgeInsets.all(14),
                    child: Icon(
                      Icons.camera_alt_rounded,
                      color: AppColors.primary,
                      size: 26,
                    ),
                  ),
                ),
              ),
            ),
          ),

          // ── SEARCH PANEL (top) — hidden during navigation ──────────────────
          if (!_navigationStarted)
          Positioned(
            top: topPad,
            left: 0,
            right: 0,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Origin with compact side actions
                  Row(
                    children: [
                      Expanded(
                        child: _SearchField(
                          hint: 'Starting location',
                          controller: _originController,
                          prefixChild: Container(
                            margin: const EdgeInsets.all(12),
                            width: 12,
                            height: 12,
                            decoration: const BoxDecoration(
                              color: AppColors.normal,
                              shape: BoxShape.circle,
                            ),
                          ),
                          suffixWidget: _originSearching
                              ? const Padding(
                                  padding: EdgeInsets.all(12),
                                  child: SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: AppColors.primary,
                                    ),
                                  ),
                                )
                              : null,
                        ),
                      ),
                      const SizedBox(width: 6),
                      _CompactActionButton(
                        icon: Icons.my_location_rounded,
                        color: AppColors.primary,
                        onTap: _useCurrentLocation,
                      ),
                      const SizedBox(width: 6),
                      _CompactActionButton(
                        icon: Icons.location_on_outlined,
                        color: _selectingOrigin ? Colors.white : AppColors.normal,
                        backgroundColor: _selectingOrigin
                            ? AppColors.primary
                            : AppColors.backgroundSecondary,
                        borderColor: _selectingOrigin
                            ? null
                            : AppColors.normal.withValues(alpha: 0.2),
                        onTap: () {
                          setState(() {
                            _selectingOrigin = !_selectingOrigin;
                            _selectingDestination = false;
                            _showOriginSuggestions = false;
                            _showDestSuggestions = false;
                          });
                        },
                      ),
                    ],
                  ),
                  // Origin suggestions dropdown
                  if (_showOriginSuggestions && (_originResults.isNotEmpty || _originSearching))
                    _SuggestionList(
                      results: _originResults,
                      searching: _originSearching,
                      onTap: _selectOriginResult,
                    ),
                  Padding(
                    padding: const EdgeInsets.only(top: 6, bottom: 4),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: AppColors.backgroundSecondary,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          Icon(_selectedVehicleType.icon, size: 18, color: AppColors.primary),
                          const SizedBox(width: 8),
                          const Text(
                            'Vehicle',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textSecondary,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<VehicleType>(
                                value: _selectedVehicleType,
                                isExpanded: true,
                                items: VehicleType.values.map((vehicleType) {
                                  return DropdownMenuItem(
                                    value: vehicleType,
                                    child: Row(
                                      children: [
                                        Icon(vehicleType.icon, size: 16, color: AppColors.textSecondary),
                                        const SizedBox(width: 8),
                                        Text(
                                          vehicleType.label,
                                          style: const TextStyle(fontSize: 12),
                                        ),
                                      ],
                                    ),
                                  );
                                }).toList(),
                                onChanged: (value) {
                                  if (value != null) {
                                    setState(() => _selectedVehicleType = value);
                                  }
                                },
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // Dotted connector
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 21),
                    child: Column(
                      children: List.generate(
                        4,
                        (_) => Container(
                          width: 2,
                          height: 4,
                          margin: const EdgeInsets.symmetric(vertical: 1.5),
                          decoration: BoxDecoration(
                            color: AppColors.backgroundSecondary,
                            borderRadius: BorderRadius.circular(1),
                          ),
                        ),
                      ),
                    ),
                  ),
                  // Destination with pin button
                  Row(
                    children: [
                      Expanded(
                        child: _SearchField(
                          hint: 'Where to?',
                          controller: _destController,
                          prefixIcon: Icons.location_on,
                          prefixIconColor: AppColors.danger,
                          onSubmitted: (_) {
                            if (_destResults.isNotEmpty) {
                              _selectDestResult(_destResults.first);
                            } else {
                              _buildRoute();
                            }
                          },
                          suffixIcon:
                              _routeFound ? Icons.keyboard_arrow_down : null,
                          suffixWidget: _destSearching
                              ? const Padding(
                                  padding: EdgeInsets.all(12),
                                  child: SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: AppColors.danger,
                                    ),
                                  ),
                                )
                              : null,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: () {
                            setState(() {
                              _selectingDestination = !_selectingDestination;
                              _selectingOrigin = false;
                              _showOriginSuggestions = false;
                              _showDestSuggestions = false;
                            });
                          },
                          borderRadius: BorderRadius.circular(10),
                          splashColor: AppColors.danger.withValues(alpha: 0.1),
                          child: Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: _selectingDestination
                                  ? AppColors.danger
                                  : AppColors.backgroundSecondary,
                              borderRadius: BorderRadius.circular(10),
                              border: _selectingDestination
                                  ? null
                                  : Border.all(
                                      color: AppColors.danger.withValues(alpha: 0.2),
                                      width: 1,
                                    ),
                            ),
                            child: Icon(
                              Icons.location_on_outlined,
                              color: _selectingDestination
                                  ? Colors.white
                                  : AppColors.danger,
                              size: 20,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  // Destination suggestions dropdown
                  if (_showDestSuggestions && (_destResults.isNotEmpty || _destSearching))
                    _SuggestionList(
                      results: _destResults,
                      searching: _destSearching,
                      onTap: _selectDestResult,
                    ),
                ],
              ),
            ),
          ),

          // ── ROUTE RESULT BOTTOM SHEET ────────────────────────────────────────
          if (_routeFound && !_navigationStarted)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: _RouteBottomSheet(
                onStartNavigation: () {
                  setState(() {
                    _navigationStarted = true;
                    _routeFound = false;
                  });
                  // Focus on user's origin area like Google Maps navigation mode
                  final focusPoint = _originLatLng ?? _defaultLocation;
                  _mapController.move(focusPoint, 17);
                },
                routeResult: _routePlanResult,
              ),
            ),
        ],
      ),
    );
  }
}

// ── Compact Action Button ─────────────────────────────────────────────────

class _CompactActionButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final Color? backgroundColor;
  final Color? borderColor;
  final VoidCallback onTap;

  const _CompactActionButton({
    required this.icon,
    required this.color,
    required this.onTap,
    this.backgroundColor,
    this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        splashColor: AppColors.primary.withValues(alpha: 0.1),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: backgroundColor ?? AppColors.backgroundSecondary,
            borderRadius: BorderRadius.circular(10),
            border: borderColor == null
                ? null
                : Border.all(color: borderColor!, width: 1),
          ),
          child: Icon(icon, color: color, size: 20),
        ),
      ),
    );
  }
}

// ── Search Field ──────────────────────────────────────────────────────────────

class _SearchField extends StatelessWidget {
  final String hint;
  final bool readOnly;
  final TextEditingController? controller;
  final IconData? prefixIcon;
  final Color? prefixIconColor;
  final Widget? prefixChild;
  final IconData? suffixIcon;
  final Widget? suffixWidget;
  final ValueChanged<String>? onSubmitted;

  const _SearchField({
    required this.hint,
    this.controller,
    this.prefixIcon,
    this.prefixIconColor,
    this.prefixChild,
    this.suffixIcon,
    this.suffixWidget,
    this.onSubmitted,
  }) : readOnly = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.backgroundSecondary,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppColors.normal.withValues(alpha: 0.1),
          width: 0.5,
        ),
      ),
      child: TextField(
        controller: controller,
        readOnly: readOnly,
        onSubmitted: onSubmitted,
        style: const TextStyle(
          fontSize: 14,
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w500,
        ),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(
            color: AppColors.textMuted,
            fontSize: 14,
            fontWeight: FontWeight.w400,
          ),
          prefixIcon: prefixChild ?? (prefixIcon != null
                  ? Icon(prefixIcon, color: prefixIconColor, size: 20)
                  : null),
          prefixIconConstraints: const BoxConstraints(minWidth: 44),
          suffixIcon: suffixWidget ??
              (suffixIcon != null
                  ? Icon(suffixIcon!, color: AppColors.textMuted, size: 20)
                  : null),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        ),
      ),
    );
  }
}

// ── Suggestion List ─────────────────────────────────────────────────────────

class _SuggestionList extends StatelessWidget {
  final List<GeoSearchResult> results;
  final bool searching;
  final ValueChanged<GeoSearchResult> onTap;

  const _SuggestionList({
    required this.results,
    required this.searching,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 4),
      constraints: const BoxConstraints(maxHeight: 220),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: searching && results.isEmpty
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
              itemCount: results.length,
              separatorBuilder: (_, _) => const Divider(
                height: 1,
                color: AppColors.border,
                indent: 44,
              ),
              itemBuilder: (context, index) {
                final result = results[index];
                return InkWell(
                  onTap: () => onTap(result),
                  borderRadius: BorderRadius.circular(10),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.location_on_outlined,
                          size: 18,
                          color: AppColors.textMuted,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
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
                              if (result.displayName != result.shortName)
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
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
    );
  }
}

// ── Route Bottom Sheet ────────────────────────────────────────────────────────

class _RouteBottomSheet extends StatefulWidget {
  final VoidCallback onStartNavigation;
  final RoutePlanResult? routeResult;
  const _RouteBottomSheet({required this.onStartNavigation, this.routeResult});

  @override
  State<_RouteBottomSheet> createState() => _RouteBottomSheetState();
}

class _RouteBottomSheetState extends State<_RouteBottomSheet> {
  bool _showAvoidedAreas = false;

  @override
  Widget build(BuildContext context) {
    final result = widget.routeResult;
    final distance = result?.distanceKm;
    final eta = result?.etaText;
    final avoidedNodes = result?.avoidedNodes ?? [];

    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 14)],
      ),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
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
          const SizedBox(height: 12),

          // Distance + ETA side by side
          Row(
            children: [
              // Distance
              Expanded(
                child: Row(
                  children: [
                    const Icon(Icons.route_rounded, size: 20, color: AppColors.primary),
                    const SizedBox(width: 8),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'Distance',
                          style: TextStyle(fontSize: 10, color: AppColors.textMuted),
                        ),
                        Text(
                          distance != null
                              ? '${distance.toStringAsFixed(1)} km'
                              : '-- km',
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              // Divider
              Container(width: 1, height: 36, color: AppColors.border),
              const SizedBox(width: 12),
              // ETA
              Expanded(
                child: Row(
                  children: [
                    const Icon(Icons.access_time_rounded, size: 20, color: AppColors.primary),
                    const SizedBox(width: 8),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'Avg. Time',
                          style: TextStyle(fontSize: 10, color: AppColors.textMuted),
                        ),
                        Text(
                          eta ?? '-- min',
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // Flood avoidance info (if there are avoided areas)
          if (avoidedNodes.isNotEmpty) ...[
            InkWell(
              onTap: () {
                setState(() {
                  _showAvoidedAreas = !_showAvoidedAreas;
                });
              },
              borderRadius: BorderRadius.circular(10),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.danger.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: AppColors.danger.withValues(alpha: 0.2),
                    width: 1,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.flood_rounded,
                      color: AppColors.danger,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '${avoidedNodes.length} flood zone${avoidedNodes.length > 1 ? 's' : ''} avoided',
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: AppColors.textPrimary,
                            ),
                          ),
                          Text(
                            _showAvoidedAreas ? 'Tap to hide details' : 'Tap to see details',
                            style: const TextStyle(
                              fontSize: 11,
                              color: AppColors.textMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      _showAvoidedAreas ? Icons.expand_less : Icons.expand_more,
                      color: AppColors.danger,
                      size: 20,
                    ),
                  ],
                ),
              ),
            ),
            if (_showAvoidedAreas) ...[
              const SizedBox(height: 8),
              Container(
                constraints: const BoxConstraints(maxHeight: 150),
                decoration: BoxDecoration(
                  color: AppColors.backgroundSecondary,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.all(8),
                  itemCount: avoidedNodes.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final node = avoidedNodes[index];
                    final statusColor = node.status == 'DANGER'
                        ? AppColors.danger
                        : AppColors.alert;
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                      child: Row(
                        children: [
                          Icon(
                            Icons.warning_rounded,
                            color: statusColor,
                            size: 16,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  node.name,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  '${node.status} · ${node.waterLevelM.toStringAsFixed(2)}m water',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: statusColor,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
            const SizedBox(height: 12),
          ],

          // Start Navigation button
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: widget.onStartNavigation,
              icon: const Icon(Icons.navigation_rounded, size: 20),
              label: const Text(
                'Start Navigation',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                padding: const EdgeInsets.symmetric(vertical: 14),
                elevation: 2,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

