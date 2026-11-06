import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import '../services/cctv_service.dart';
import '../services/geocoding_service.dart';
import '../services/geo_utils.dart';
import '../services/location_service.dart';
import '../services/route_planner.dart';
import '../services/road_segment_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_radius.dart';
import '../theme/app_shadows.dart';

class RoutingScreen extends StatefulWidget {
  final LatLng? initialDestination;
  final String? initialDestinationName;

  /// Invoked by the header's back button. HomeScreen uses it to return to the
  /// Map tab; falls back to popping the current route when not provided.
  final VoidCallback? onBack;

  const RoutingScreen({
    super.key,
    this.initialDestination,
    this.initialDestinationName,
    this.onBack,
  });

  @override
  State<RoutingScreen> createState() => _RoutingScreenState();
}

class _RoutingScreenState extends State<RoutingScreen>
    with SingleTickerProviderStateMixin {
  final _destController = TextEditingController();
  final _originController = TextEditingController();
  final _mapController = MapController();
  final GlobalKey _mapKey = GlobalKey();
  bool _routeFound = false;
  bool _selectingOrigin = false;
  bool _selectingDestination = false;
  bool _navigationStarted = false;
  bool _isRouting = false;
  LatLng? _originLatLng;
  LatLng? _destLatLng;
  /// True when the origin was explicitly set with "Use current location".
  /// In that case the route follows the live GPS position; otherwise it keeps
  /// the place the user picked, even after navigation starts.
  bool _originIsCurrentLocation = false;
  /// Guards against overlapping "use current location" requests.
  bool _resolvingCurrentLocation = false;
  VehicleType _selectedVehicleType = VehicleType.light;
  RoutePlanResult? _routePlanResult;
  bool _pointerInteractionsEnabled = false;

  // CCTV data fetched from MongoDB via backend API
  List<Map<String, dynamic>> _cctvDocs = [];
  List<Map<String, dynamic>> _lastRoutedCctvSnapshot = [];
  // Cached OSM road segments keyed by CCTV index string (matching _cctvDocs index -> id mapping)
  Map<String, RoadSegmentResult> _roadSegments = {};

  // Search state
  Timer? _originDebounce;
  Timer? _destDebounce;
  // Periodically re-checks flood conditions and reroutes if they change.
  Timer? _rerouteTimer;
  bool _rerouteInFlight = false;
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

  // GPS tracking for navigation and the always-visible location marker
  StreamSubscription<Position>? _positionSub;
  LatLng? _currentPosition;

  // Smoothly interpolates the camera between 1 Hz GPS fixes instead of
  // jumping the map once per second.
  AnimationController? _cameraAnimation;

  /// True while the camera should follow the live position during navigation.
  /// Any manual pan/zoom turns this off so the user can freely inspect the
  /// map; the re-center button turns it back on.
  bool _mapFollowsUser = true;

  // Google-Maps-style progress: while navigating, only the road still ahead
  // of the user is drawn. `_routeProgressSegment` is the last matched segment
  // and only moves forward so passed road never reappears.
  static const double _offRouteThresholdM = 60.0;
  int _routeProgressSegment = 0;
  List<LatLng>? _remainingRoute;

  /// Length of a polyline in kilometres.
  double _lineLengthKm(List<LatLng> line) {
    var meters = 0.0;
    for (var i = 0; i < line.length - 1; i++) {
      meters += GeoUtils.haversineM(line[i], line[i + 1]);
    }
    return meters / 1000.0;
  }

  /// True whenever the drawn route should shrink as the device moves: during
  /// navigation, or while previewing a route that starts at "Current location".
  bool get _shouldTrackProgress =>
      _routePlanResult != null &&
      (_navigationStarted || _originIsCurrentLocation);

  /// Distance shown in the navigation bar: the part still ahead, otherwise the
  /// full planned route.
  double get _displayDistanceKm {
    final result = _routePlanResult;
    if (result == null) return 0;
    if (_shouldTrackProgress && _remainingRoute != null) {
      return _lineLengthKm(_remainingRoute!);
    }
    // Some very short/edge-case OSRM responses report 0 distance even though
    // a polyline was returned; fall back to the geometry length so the UI
    // never shows a misleading 0.0 km for a real drawn route.
    if (result.distanceKm <= 0 && result.polyline.length >= 2) {
      return _lineLengthKm(result.polyline);
    }
    return result.distanceKm;
  }

  /// ETA shown in the navigation bar, recomputed from the remaining distance
  /// so it counts down as the user moves along the route.
  double get _displayDurationMinutes {
    final result = _routePlanResult;
    if (result == null) return 0;
    if (_shouldTrackProgress &&
        _remainingRoute != null &&
        result.distanceKm > 0 &&
        result.durationMinutes > 0) {
      final fraction =
          (_displayDistanceKm / result.distanceKm).clamp(0.0, 1.0);
      return result.durationMinutes * fraction;
    }
    return result.durationMinutes;
  }

  String get _displayEtaText => _routePlanResult == null
      ? '--'
      : RoutePlanResult.formatEta(_displayDurationMinutes);

  // Default location (Cagayan de Oro, Philippines)
  final LatLng _defaultLocation = LatLng(8.4866, 124.6500);

  @override
  void initState() {
    super.initState();
    _originController.addListener(_onOriginChanged);
    _destController.addListener(_onDestChanged);

    // Enable pointer interactions after first frame to avoid early hit-tests
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _pointerInteractionsEnabled = true);
    });

    // Fetch CCTV data from backend API
    _loadCctvData();

    // Keep the "my location" marker live even before navigation starts, so
    // switching from the Map tab to the Routing tab shows the user's position.
    _startLocationTracking();

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
    _positionSub?.cancel();
    _cameraAnimation?.dispose();
    _destController.dispose();
    _originController.dispose();
    _mapController.dispose();
    super.dispose();
  }

  Future<void> _loadCctvData() async {
    final docs = await CctvService.fetchCctvData();
    if (mounted) {
      setState(() => _cctvDocs = docs);
      // Also ensure road geometry is loaded (will be cache HIT for existing coords)
      _loadRoadSegments(docs);
    }
  }

  Future<void> _loadRoadSegments(List<Map<String, dynamic>> docs) async {
    if (docs.isEmpty) return;
    // Build id->LatLng map using stable string ids matching MapScreen convention
    final idToCoord = <String, LatLng>{};
    for (var i = 0; i < docs.length; i++) {
      final doc = docs[i];
      final coords = doc['location']['coordinates'] as List<dynamic>;
      final lon = (coords[0] as num).toDouble();
      final lat = (coords[1] as num).toDouble();
      final id = (i + 1).toString();
      idToCoord[id] = LatLng(lat, lon);
    }

    try {
      final batch = await RoadSegmentService.getSegmentsForCoordinates(idToCoord);
      if (!mounted) return;
      setState(() {
        _roadSegments = {
          for (final e in batch.entries)
            if (e.value != null) e.key: e.value!,
        };
      });
    } catch (e) {
      // Ignore — visualization can proceed without geometry
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
      _originIsCurrentLocation = false;
      _originController.text = result.shortName;
      _originResults = [];
      _showOriginSuggestions = false;
    });
    _suppressOriginSearch = false;
    _safeMapMove(result.latLng, 15);
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
    _safeMapMove(result.latLng, 15);
    if (_originLatLng != null) {
      _buildRoute();
    }
  }

  Future<void> _useCurrentLocation() async {
    if (_resolvingCurrentLocation) return;
    _resolvingCurrentLocation = true;
    try {
      // Leaving pin-selection mode immediately keeps the UI consistent while
      // the GPS fix resolves and stops the confirm banner from lingering.
      if (_selectingOrigin || _selectingDestination) {
        setState(() {
          _selectingOrigin = false;
          _selectingDestination = false;
        });
      }

      final status = await LocationService.ensureAccess();
      if (status != LocationAccessStatus.granted) {
        await _handleLocationAccessFailure(status);
        return;
      }

      // Prefer the latched fix from the continuous stream: it is instant and
      // the marker is already following it, so the button always responds.
      // Only fall back to a one-shot request (with a timeout) when the stream
      // has not produced a position yet.
      final point = _currentPosition ?? await _fetchOneShotPosition();
      if (!mounted) return;
      if (point == null) {
        _showLocationMessage('Unable to fetch your current location right now.');
        return;
      }

      _suppressOriginSearch = true;
      setState(() {
        _originLatLng = point;
        // Keep the latched fix in sync. Without this, route building bails out
        // with "Waiting for your current location" when the one-shot fix was
        // used because the continuous stream had not emitted yet.
        _currentPosition ??= point;
        _originIsCurrentLocation = true;
        _originController.text = 'Current location';
        _selectingOrigin = false;
        _selectingDestination = false;
        _originResults = [];
        _showOriginSuggestions = false;
      });
      _suppressOriginSearch = false;

      // Make sure the live stream is running for future updates.
      _startLocationTracking();

      _safeMapMove(point, 16);

      // A destination may already be set (e.g. the user previewed a route
      // from a custom origin first). Rebuild the preview so it visibly starts
      // from the current location instead of keeping the stale route.
      if (_destLatLng != null) {
        await _buildRoute();
      }

      // Reverse-geocode for a readable address label. Skip if the origin moved
      // on (another selection) while we were waiting.
      final address = await GeocodingService.reverseGeocode(point)
          .timeout(const Duration(seconds: 5), onTimeout: () => 'Current location');
      if (!mounted || !_originIsCurrentLocation) return;
      _suppressOriginSearch = true;
      setState(() {
        _originController.text = address;
      });
      _suppressOriginSearch = false;
    } catch (_) {
      if (!mounted) return;
      _showLocationMessage('Unable to fetch your current location right now.');
    } finally {
      _resolvingCurrentLocation = false;
    }
  }

  /// One-shot high-accuracy fix with a timeout, falling back to the platform's
  /// last known position so a slow GPS lock doesn't make the button dead.
  Future<LatLng?> _fetchOneShotPosition() async {
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      ).timeout(const Duration(seconds: 8));
      return LatLng(position.latitude, position.longitude);
    } catch (_) {
      try {
        final last = await Geolocator.getLastKnownPosition();
        if (last != null) return LatLng(last.latitude, last.longitude);
      } catch (_) {}
      return null;
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

    // Use safe fit that waits for the map to have valid layout.
    _safeFitCamera(validPoints);
  }

  void _safeFitCamera(List<LatLng> validPoints) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = _mapKey.currentContext;
      final ro = ctx?.findRenderObject();
      if (ro is RenderBox && ro.hasSize && ro.size.width > 0 && ro.size.height > 0) {
        try {
          final bounds = LatLngBounds.fromPoints(validPoints);
          _mapController.fitCamera(
            CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(72)),
          );
        } catch (e) {
          final mid = validPoints[validPoints.length ~/ 2];
          try {
            _safeMapMove(mid, 14);
          } catch (_) {}
        }
        return;
      }

      // Retry until the map has layout (max ~1s)
      int attempts = 0;
      Timer.periodic(const Duration(milliseconds: 50), (t) {
        attempts++;
        if (!mounted) {
          t.cancel();
          return;
        }
        final ro2 = _mapKey.currentContext?.findRenderObject();
        if (ro2 is RenderBox && ro2.hasSize && ro2.size.width > 0 && ro2.size.height > 0) {
          try {
            final bounds = LatLngBounds.fromPoints(validPoints);
            _mapController.fitCamera(
              CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(72)),
            );
          } catch (_) {
            final mid = validPoints[validPoints.length ~/ 2];
            try {
              _mapController.move(mid, 14);
            } catch (_) {}
          }
          t.cancel();
          return;
        }
        if (attempts > 20) t.cancel();
      });
    });
  }

  void _safeMapMove(LatLng latlng, double zoom) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ro = _mapKey.currentContext?.findRenderObject();
      if (ro is RenderBox && ro.hasSize && ro.size.width > 0 && ro.size.height > 0) {
        try {
          _mapController.move(latlng, zoom);
        } catch (e) {
          print('[NavigationUI] Safe move failed: $e');
        }
        return;
      }

      int attempts = 0;
      Timer.periodic(const Duration(milliseconds: 50), (t) {
        attempts++;
        if (!mounted) {
          t.cancel();
          return;
        }
        final ro2 = _mapKey.currentContext?.findRenderObject();
        if (ro2 is RenderBox && ro2.hasSize && ro2.size.width > 0 && ro2.size.height > 0) {
          try {
            _mapController.move(latlng, zoom);
          } catch (e) {
            print('[NavigationUI] Safe move failed: $e');
          }
          t.cancel();
          return;
        }
        if (attempts > 20) t.cancel();
      });
    });
  }

  bool _mapHasLayout() {
    final ctx = _mapKey.currentContext;
    if (ctx == null) return false;
    final renderBox = ctx.findRenderObject();
    if (renderBox is RenderBox) {
      return renderBox.hasSize && renderBox.size.width > 0 && renderBox.size.height > 0;
    }
    return false;
  }

  void _showLocationMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  /// Explains why location access failed and offers the right system shortcut:
  /// turn on device location, or open the app's permission settings.
  Future<void> _handleLocationAccessFailure(
    LocationAccessStatus status,
  ) async {
    if (!mounted) return;

    if (status == LocationAccessStatus.serviceDisabled) {
      final open = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Turn on location'),
          content: const Text(
            'Device location (GPS) is turned off. Turn it on to use your '
            'current location and get live navigation updates.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Not now'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Open settings'),
            ),
          ],
        ),
      );
      if (open == true) {
        await Geolocator.openLocationSettings();
      }
      return;
    }

    if (status == LocationAccessStatus.permissionDeniedForever) {
      final open = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Location permission needed'),
          content: const Text(
            'Location permission is blocked. Open app settings and allow '
            'location access for FloodSight.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Open app settings'),
            ),
          ],
        ),
      );
      if (open == true) {
        await Geolocator.openAppSettings();
      }
      return;
    }

    _showLocationMessage(
      'Location permission is required to use your current location.',
    );
  }

  Future<void> _buildRoute() async {
    if (_originIsCurrentLocation &&
        _currentPosition == null &&
        _originLatLng == null) {
      // Try once to hydrate the fix before giving up, instead of leaving the
      // user stuck on a message.
      final point = await _fetchOneShotPosition();
      if (!mounted) return;
      if (point == null) {
        _showLocationMessage(
          'Waiting for your current location before building the route.',
        );
        return;
      }
      _currentPosition = point;
      _originLatLng = point;
    }
    final origin = _effectiveOrigin;
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

    if (result != null) {
      _lastRoutedCctvSnapshot =
          List<Map<String, dynamic>>.from(RoutePlanner.lastCctvSnapshot);
    }

    setState(() {
      _routePlanResult = result;
      _routeFound = result != null;
      _isRouting = false;
      // New geometry — restart progress tracking from its beginning.
      _routeProgressSegment = 0;
      _remainingRoute = null;

      // The route was requested from the position the user had when they
      // tapped "route". If they kept moving while the request was in flight
      // (Overpass/OSRM can take a few seconds), snap the visible start to the
      // live position so the line doesn't begin behind them (and never shows
      // a "passed" chunk as if it were still ahead).
      if (result != null &&
          _originIsCurrentLocation &&
          _currentPosition != null) {
        _remainingRoute = _initialRemainder(
          result.polyline,
          _currentPosition!,
        );
      }
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

  /// Starts the single continuous position stream that feeds `_currentPosition`
  /// (and therefore the "my location" marker). Called once from `initState`
  /// so the marker is visible on the Routing tab without starting navigation,
  /// and reused by `_startGpsTracking` when navigation begins.
  Future<void> _startLocationTracking() async {
    if (_positionSub != null) return;
    try {
      final stream = await LocationService.watchPosition(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0, // every fix — roughly once per second
        intervalDuration: const Duration(seconds: 1),
      );
      if (stream == null || !mounted) return;

      _positionSub = stream.listen(
        _onPositionUpdate,
        onError: (_) {
          _positionSub?.cancel();
          _positionSub = null;
        },
        cancelOnError: true,
      );
    } catch (_) {
      // GPS tracking failed silently
    }
  }

  /// The origin used for routing. Honors an explicitly chosen start point;
  /// only falls back to the live GPS fix when the user asked for "Current
  /// location" (or hasn't picked an origin at all).
  LatLng get _effectiveOrigin {
    if (_originIsCurrentLocation) {
      return _currentPosition ?? _originLatLng ?? _defaultLocation;
    }
    return _originLatLng ?? _currentPosition ?? _defaultLocation;
  }

  /// Point that the blue user marker represents.
  ///
  /// Normally this is the live GPS fix. During navigation from a pinned start,
  /// if the device is far off the planned route (or GPS is unavailable), the
  /// marker stays on the chosen start so it is always visible on screen
  /// instead of disappearing outside the viewport.
  LatLng? get _navigationUserPoint {
    final live = _currentPosition;
    if (!_navigationStarted) return live;
    if (live == null) return _originLatLng;
    if (_originIsCurrentLocation) return live;

    final route = _routePlanResult?.polyline;
    if (route == null || route.length < 2) return live;

    final nearest = GeoUtils.nearestPointOnPolyline(live, route);
    if (nearest == null || nearest.distanceM > _offRouteThresholdM) {
      return _originLatLng ?? live;
    }
    return live;
  }

  /// Eases the camera from its current center to [target] over ~0.85s. Called
  /// once per GPS fix so movement looks continuous instead of jumping a whole
  /// block at a time.
  void _animateCameraTo(LatLng target) {
    if (!mounted || !_mapHasLayout()) {
      _safeMapMove(target, _mapController.camera.zoom);
      return;
    }

    final LatLng start;
    final double zoom;
    try {
      start = _mapController.camera.center;
      zoom = _mapController.camera.zoom;
    } catch (_) {
      _safeMapMove(target, 16);
      return;
    }

    if (start.latitude == target.latitude &&
        start.longitude == target.longitude) {
      return;
    }

    _cameraAnimation?.dispose();
    final controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 850),
    );
    _cameraAnimation = controller;
    controller.addListener(() {
      if (!mounted) return;
      final t = controller.value;
      _mapController.move(
        LatLng(
          start.latitude + (target.latitude - start.latitude) * t,
          start.longitude + (target.longitude - start.longitude) * t,
        ),
        zoom,
      );
    });
    controller.forward();
  }

  void _onPositionUpdate(Position position) {
    if (!mounted) return;
    final newLatLng = LatLng(position.latitude, position.longitude);
    final isFirstFix = _currentPosition == null;
    setState(() {
      _currentPosition = newLatLng;
      // Keep the origin marker glued to the user only while "Current
      // location" is the chosen start and no route preview is pinned to an
      // origin yet (after a preview, the route's start should stay put).
      if (_originIsCurrentLocation && !_navigationStarted && _routePlanResult == null) {
        _originLatLng = newLatLng;
      }
      // Chop the passed part of the route away as the user moves, both in
      // navigation and in a current-location preview.
      if (_shouldTrackProgress) {
        _remainingRoute = _trimRoute(_routePlanResult!.polyline, newLatLng);
      }
    });

    if (_navigationStarted) {
      // Keep the marker on screen only when it represents the live position;
      // when it falls back to a pinned start (GPS far off-route) the camera
      // must stay on the route instead of chasing the device. If the user has
      // manually panned/zoomed, leave the camera alone until re-center is
      // tapped.
      if (_mapFollowsUser && _navigationUserPoint == newLatLng) {
        _animateCameraTo(newLatLng);
      }
    } else if (isFirstFix && _originLatLng == null && _destLatLng == null) {
      // First fix on an untouched routing map: center on the user so the
      // marker is actually on screen instead of the hard-coded default.
      _safeMapMove(newLatLng, 15);
    }
  }

  /// Projects [position] onto a freshly-built [route] and returns the portion
  /// still ahead of the user.
  ///
  /// Used once right after a route is built from "Current location": planning
  /// can take several seconds, so by the time it returns the stored origin may
  /// already be behind the moving user. Snapping the visible start to the
  /// nearest point on the line keeps the drawn route clear and ahead-only.
  /// Returns null when the user is too far from the line to trust the
  /// projection (then the full route is kept).
  List<LatLng>? _initialRemainder(List<LatLng> route, LatLng position) {
    if (route.length < 2) return null;

    var bestDistance = double.infinity;
    var bestPoint = route.first;
    var bestSegment = 0;

    for (var i = 0; i < route.length - 1; i++) {
      final nearest =
          GeoUtils.nearestPointOnSegment(position, route[i], route[i + 1]);
      if (nearest.distanceM < bestDistance) {
        bestDistance = nearest.distanceM;
        bestPoint = nearest.point;
        bestSegment = i;
      }
    }

    // Generous initial tolerance: the planner's origin may be a little
    // off-road, but don't snap to a route that is on the other side of town.
    if (bestDistance > _offRouteThresholdM * 3) return null;

    // Already at the very start — nothing to trim.
    if (bestSegment == 0 &&
        GeoUtils.haversineM(bestPoint, route.first) < 5) {
      return null;
    }

    _routeProgressSegment = bestSegment;
    return <LatLng>[bestPoint, ...route.skip(bestSegment + 1)];
  }

  /// Trims [route] to the portion the user has not driven yet, starting at
  /// their projected position on the line.
  ///
  /// Progress is monotonic: the search starts slightly behind the last
  /// matched segment (so GPS jitter can't re-draw passed road) but only moves
  /// forward. When the user is far off the line, the full route is returned so
  /// the line never gets chopped at a meaningless spot from GPS drift.
  List<LatLng> _trimRoute(List<LatLng> route, LatLng position) {
    if (route.length < 2) return route;

    final lastSegment = route.length - 2;
    // Search slightly behind the last matched segment to absorb GPS jitter,
    // but never let the visible route grow backwards again.
    final firstSegment = (_routeProgressSegment - 1).clamp(0, lastSegment);

    var bestDistance = double.infinity;
    var bestPoint = route[firstSegment];
    var bestSegment = firstSegment;

    for (var i = firstSegment; i <= lastSegment; i++) {
      final nearest =
          GeoUtils.nearestPointOnSegment(position, route[i], route[i + 1]);
      if (nearest.distanceM < bestDistance) {
        bestDistance = nearest.distanceM;
        bestPoint = nearest.point;
        bestSegment = i;
      }
    }

    if (bestDistance > _offRouteThresholdM) {
      // Off the line (GPS drift or a detour). Keep the existing remainder so
      // road that was already walked past never reappears; only fall back to
      // the full route when no progress has been made yet.
      return _remainingRoute ?? route;
    }

    if (bestSegment < _routeProgressSegment) {
      bestSegment = _routeProgressSegment;
      bestPoint = route[bestSegment];
    }
    _routeProgressSegment = bestSegment;

    // The projection point becomes the new visible start; everything before it
    // (already walked) is dropped.
    final trimmed = <LatLng>[bestPoint, ...route.skip(bestSegment + 1)];
    final previous = _remainingRoute;
    if (previous != null && trimmed.length > previous.length) {
      return previous;
    }
    return trimmed;
  }

  /// Navigation needs the live position stream that already powers the marker
  /// (see `_startLocationTracking`); this only guarantees it is running.
  void _startGpsTracking() {
    _startLocationTracking();
  }

  /// Stops camera-following when navigation ends. The position subscription is
  /// intentionally kept alive so the "my location" marker stays visible.
  void _stopGpsTracking() {
    // No-op: marker tracking continues outside navigation.
  }

  Future<void> _checkForReroute() async {
    if (_rerouteInFlight) return;
    if (_routePlanResult == null) return;

    if (_originIsCurrentLocation &&
        _currentPosition == null &&
        _originLatLng == null) {
      return;
    }
    final origin = _effectiveOrigin;
    final destination = _destLatLng ?? _defaultLocation;
    if (origin.latitude == destination.latitude &&
        origin.longitude == destination.longitude) {
      return;
    }

    _rerouteInFlight = true;
    try {
      // Detect flood-status change before recomputing the route.
      final floodChangeDetectedAt = DateTime.now();
      final currentCctv = await CctvService.fetchCctvData();
      if (!mounted) return;
      // An empty payload means the backend/network failed, NOT that every
      // flood cleared. Ignoring it prevents the route from being rebuilt
      // against "no hazards" and keeps the last known good snapshot.
      if (currentCctv.isEmpty) return;

      final floodChanged =
          _cctvDataChanged(_lastRoutedCctvSnapshot, currentCctv);
      if (!floodChanged) return;

      final previousSnapshot =
          List<Map<String, dynamic>>.from(_lastRoutedCctvSnapshot);

      final newResult = await RoutePlanner.planRoute(
        origin: origin,
        destination: destination,
        vehicleType: _selectedVehicleType,
        context: RouteRequestContext(
          isReroute: true,
          floodChangeDetectedAt: floodChangeDetectedAt,
          previousCctvDocs: previousSnapshot,
        ),
      );
      if (!mounted) return;

      // Keep the CCTV map markers in sync even if the route itself did not
      // need to change.
      final routedSnapshot =
          List<Map<String, dynamic>>.from(RoutePlanner.lastCctvSnapshot);
      if (routedSnapshot.isEmpty) return;
      _lastRoutedCctvSnapshot = routedSnapshot;
      setState(() => _cctvDocs = routedSnapshot);
      _loadRoadSegments(routedSnapshot);

      if (newResult == null) return;

      final previous = _routePlanResult;
      if (!_routeChanged(previous, newResult)) return;

      setState(() {
        _routePlanResult = newResult;
        _routeFound = true;
        // Recompute progress against the new geometry, then immediately snap
        // it to the live position so the rerouted line doesn't show road the
        // user has already covered.
        _routeProgressSegment = 0;
        _remainingRoute = _originIsCurrentLocation && _currentPosition != null
            ? _initialRemainder(newResult.polyline, _currentPosition!)
            : null;
      });
      _showRerouteSnackbar();
    } catch (_) {
      // A failed poll must never break navigation; the next tick retries.
    } finally {
      _rerouteInFlight = false;
    }
  }

  /// Stable identity for a CCTV document: its coordinate pair (IDs are not
  /// guaranteed to be present or ordered consistently between responses).
  String _cctvKey(Map<String, dynamic> doc) {
    try {
      final coords = (doc['location'] as Map<String, dynamic>)['coordinates']
          as List<dynamic>;
      final lon = (coords[0] as num).toDouble();
      final lat = (coords[1] as num).toDouble();
      return '${lat.toStringAsFixed(5)},${lon.toStringAsFixed(5)}';
    } catch (_) {
      return doc['_id']?.toString() ?? doc.hashCode.toString();
    }
  }

  /// Comparable state for one CCTV document: status + water level.
  String _cctvFingerprint(Map<String, dynamic> doc) {
    final status = (doc['status']?.toString() ?? '').toUpperCase();
    final level = (doc['water_level'] as num?)?.toDouble();
    return '$status|${level?.toStringAsFixed(3) ?? '-'}';
  }

  /// Returns true when any CCTV point's status or water level changed.
  ///
  /// Keyed by coordinate instead of list index because the backend does not
  /// guarantee a stable document order between polls — an index-based compare
  /// could miss a real change when documents are re-ordered.
  bool _cctvDataChanged(
    List<Map<String, dynamic>> previous,
    List<Map<String, dynamic>> current,
  ) {
    if (current.isEmpty) return false;
    if (previous.isEmpty) return true;

    final previousState = <String, String>{
      for (final doc in previous) _cctvKey(doc): _cctvFingerprint(doc),
    };
    final currentState = <String, String>{
      for (final doc in current) _cctvKey(doc): _cctvFingerprint(doc),
    };

    if (previousState.length != currentState.length) return true;
    for (final entry in currentState.entries) {
      if (previousState[entry.key] != entry.value) return true;
    }
    return false;
  }

  /// True when a recomputed route differs meaningfully from the old one.
  ///
  /// Comparing only `polyline.length` was unreliable: a detour can have the
  /// same vertex count but a different shape, or differ only by distance /
  /// safety warning. Sample every few vertices to catch shape changes without
  /// a full O(n) deep comparison on long routes.
  bool _routeChanged(RoutePlanResult? previous, RoutePlanResult next) {
    if (previous == null) return true;
    if (previous.isFullySafe != next.isFullySafe) return true;
    if (previous.warningMessage != next.warningMessage) return true;
    if ((previous.distanceKm - next.distanceKm).abs() > 0.05) return true;

    final a = previous.polyline;
    final b = next.polyline;
    if (a.length != b.length) return true;
    if (a.length < 2) return false;

    final step = (a.length ~/ 8).clamp(1, 1000);
    for (var i = 0; i < a.length; i += step) {
      if (GeoUtils.haversineM(a[i], b[i]) > 1.0) return true;
    }
    return false;
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
    final isDark = Theme.of(context).brightness == Brightness.dark;

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
    // The origin marker is hidden during navigation — the start has been
    // passed and the live position marker takes over.
    if (_originLatLng != null && !_navigationStarted) {
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
    // User position marker. During navigation it falls back to the chosen
    // start when GPS is unavailable or far off the route (e.g. navigating
    // from a pinned location), so the marker never disappears off-screen.
    final userPoint = _navigationUserPoint;
    if (userPoint != null) {
      markers.add(
        Marker(
          point: userPoint,
          width: 40,
          height: 40,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: Colors.blue.withValues(alpha: 0.2),
                  shape: BoxShape.circle,
                ),
              ),
              Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  color: Colors.blue,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 3),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.blue.withValues(alpha: 0.5),
                      blurRadius: 8,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    final fullRoutePolyline = _routePlanResult?.polyline ?? const <LatLng>[];
    // While navigating, show only the remaining road ahead of the user.
    final routePolyline = _navigationStarted
        ? (_remainingRoute ?? fullRoutePolyline)
        : fullRoutePolyline;

    return IgnorePointer(
      ignoring: !_pointerInteractionsEnabled,
      child: Scaffold(
        body: Stack(
        children: [
          // ── FLUTTER MAP ──────────────────────────────────────────────────────
          Positioned.fill(
            child: LayoutBuilder(
              builder: (buildCtx, constraints) {
                final hasLayout = constraints.maxWidth > 0 && constraints.maxHeight > 0;
                return IgnorePointer(
                  ignoring: !hasLayout,
                  child: FlutterMap(
                    key: _mapKey,
                    mapController: _mapController,
                    options: MapOptions(
                      initialCenter: _defaultLocation,
                      initialZoom: 15,
                      // Drag and zoom must always work, including while a
                      // route is shown or navigation is active. Rotation is
                      // left off so accidental two-finger twists don't tilt
                      // the map.
                      interactionOptions: const InteractionOptions(
                        flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                      ),
                      // A manual gesture suspends camera-following until the
                      // user taps the re-center button.
                      onPositionChanged: (camera, hasGesture) {
                        if (!hasGesture) return;
                        _cameraAnimation?.stop();
                        _mapFollowsUser = false;
                      },
                    ),
                    children: [
                      // Tile layer
                      TileLayer(
                        urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                        userAgentPackageName: 'com.example.subay',
                      ),
                      // Markers layer
                      MarkerLayer(markers: markers),
                      // Road segment outlines (from cached OSM geometry)
                      if (_roadSegments.isNotEmpty) ...[
                        PolylineLayer(
                          polylines: [
                            for (final cctv in _cctvDocs)
                              if (_roadSegments.containsKey(( _cctvDocs.indexOf(cctv)+1 ).toString()))
                                Polyline(
                                  points: _roadSegments[( _cctvDocs.indexOf(cctv)+1 ).toString()]!.points,
                                  strokeWidth: 8.0,
                                  color: AppColors.segmentOutline.withValues(alpha: 0.35),
                                ),
                          ],
                        ),
                        PolylineLayer(
                          polylines: [
                            for (final cctv in _cctvDocs)
                              if (_roadSegments.containsKey(( _cctvDocs.indexOf(cctv)+1 ).toString()))
                                Polyline(
                                  points: _roadSegments[( _cctvDocs.indexOf(cctv)+1 ).toString()]!.points,
                                  strokeWidth: 5.0,
                                  color: (() {
                                    final status = (cctv['status'] as String).toLowerCase();
                                    if (status == 'danger') return AppColors.danger;
                                    if (status == 'alert') return AppColors.alert;
                                    return AppColors.normal;
                                  })(),
                                ),
                          ],
                        ),
                      ],
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
                );
              },
            ),
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
                      _originIsCurrentLocation = false;
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
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
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
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                  boxShadow: AppShadows.base,
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
                decoration: BoxDecoration(
                  color: isDark ? AppColors.darkSurface : Colors.white,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xxl)),
                  boxShadow: AppShadows.lg,
                ),
                child: Row(
                  children: [
                    // ETA - large
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _displayEtaText,
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w800,
                            color:
                                isDark ? AppColors.darkTextPrimary : AppColors.textPrimary,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _routePlanResult != null
                              ? '${_displayDistanceKm.toStringAsFixed(1)} km'
                              : '',
                          style: TextStyle(
                            fontSize: 12,
                            color: isDark
                                ? AppColors.darkTextMuted
                                : AppColors.textMuted,
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
                        color: isDark
                            ? AppColors.darkSurfaceMuted
                            : AppColors.backgroundSecondary,
                        borderRadius: BorderRadius.circular(AppRadius.md),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _selectedVehicleType.icon,
                            size: 16,
                            color: isDark
                                ? AppColors.darkAccent
                                : AppColors.primary,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _selectedVehicleType.label,
                            style: TextStyle(
                              fontSize: 11,
                              color: isDark
                                  ? AppColors.darkTextSecondary
                                  : AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // End Navigation button (constrained to avoid infinite width in Stack)
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 160),
                          child: ElevatedButton.icon(
                      onPressed: () {
                        setState(() {
                          _navigationStarted = false;
                          _routeFound = true;
                          // Show the complete route again in preview mode.
                          _routeProgressSegment = 0;
                          _remainingRoute = null;
                        });
                        // Stop GPS tracking
                        _stopGpsTracking();
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
                          borderRadius: BorderRadius.circular(AppRadius.md),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                      ),
                          ),
                        ),
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
                  // Re-enable following and jump back to the live position.
                  _mapFollowsUser = true;
                  final focusPoint =
                      _currentPosition ?? _originLatLng ?? _defaultLocation;
                  _safeMapMove(focusPoint, 17);
                },
                backgroundColor: Colors.white,
                elevation: 3,
                child: const Icon(Icons.my_location, color: AppColors.primary, size: 20),
              ),
            ),
          ],

          // ── HEADER + SEARCH PANEL (hidden during navigation) ──────────────
          if (!_navigationStarted)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _RoutingHeader(topPad: topPad, onBack: widget.onBack),
                  GestureDetector(
                    onTap: () {
                      // Hide the bottom sheet when interacting with search panel
                      if (_routeFound) {
                        setState(() => _routeFound = false);
                      }
                    },
                    child: Container(
                      decoration: BoxDecoration(
                        color: isDark
                            ? AppColors.darkSurface
                            : Colors.white,
                        boxShadow: AppShadows.base,
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
                                  // Exit navigation mode if active to allow pin editing
                                  if (_navigationStarted) {
                                    _navigationStarted = false;
                                  }
                                  // Hide the bottom sheet when selecting pins
                                  _routeFound = false;
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
                        // Vehicle classification - pick one of three
                        Padding(
                          padding: const EdgeInsets.only(top: 10, bottom: 4),
                          child: _VehicleTypeSelector(
                            selected: _selectedVehicleType,
                            onChanged: (value) {
                              setState(() => _selectedVehicleType = value);
                              if (_routePlanResult != null && _destLatLng != null) {
                                _buildRoute();
                              }
                            },
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
                                  color: isDark
                                      ? AppColors.darkBorder
                                      : AppColors.backgroundSecondary,
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
                                    // Exit navigation mode if active to allow pin editing
                                    if (_navigationStarted) {
                                      _navigationStarted = false;
                                    }
                                    // Hide the bottom sheet when selecting pins
                                    _routeFound = false;
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
                                    borderRadius: BorderRadius.circular(AppRadius.lg),
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
                ],
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
                    print('[NavigationUI] Entering navigation mode');

                    // Defer toggling navigation UI until after the next frame
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!mounted) return;
                      // Now enable navigation UI and hide route sheet
                      setState(() {
                        _navigationStarted = true;
                        _routeFound = false;
                        _mapFollowsUser = true;
                        // Start trimming the route from the beginning.
                        _routeProgressSegment = 0;
                        _remainingRoute = null;
                      });
                      print('[NavigationUI] Layout ready');

                      // Small deferred delay to ensure the map has been laid out
                      Future.delayed(const Duration(milliseconds: 50), () {
                        if (!mounted) return;
                        print('[NavigationUI] Starting camera/GPS');
                        final focusPoint = _effectiveOrigin;
                        _safeMapMove(focusPoint, 17);
                        _startGpsTracking();
                      });
                    });
                  },
                routeResult: _routePlanResult,
              ),
            ),
        ],
      ),
    ),
  );
  }
}

// ── Routing Header ────────────────────────────────────────────────────────────

class _RoutingHeader extends StatelessWidget {
  final double topPad;
  final VoidCallback? onBack;

  const _RoutingHeader({required this.topPad, this.onBack});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.primary,
      height: topPad + 56,
      padding: EdgeInsets.only(top: topPad),
      child: Stack(
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: IconButton(
              onPressed: onBack ?? () => Navigator.maybePop(context),
              tooltip: 'Back',
              icon: const Icon(Icons.chevron_left_rounded,
                  color: Colors.white, size: 30),
            ),
          ),
          const Center(
            child: Text(
              'Routing',
              style: TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.2,
              ),
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
        borderRadius: BorderRadius.circular(AppRadius.lg),
        splashColor: AppColors.primary.withValues(alpha: 0.1),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: backgroundColor ?? AppColors.backgroundSecondary,
            borderRadius: BorderRadius.circular(AppRadius.lg),
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        // Keep the search fields light in both themes; only the surrounding
        // panel/background switches to dark.
        color: isDark ? Colors.white : AppColors.backgroundSecondary,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(
          color: isDark
              ? Colors.white
              : AppColors.normal.withValues(alpha: 0.1),
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
          filled: false,
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

// ── Vehicle Type Selector ─────────────────────────────────────────────────────

class _VehicleTypeSelector extends StatelessWidget {
  final VehicleType selected;
  final ValueChanged<VehicleType> onChanged;

  const _VehicleTypeSelector({
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final type in VehicleType.values) ...[
          if (type != VehicleType.values.first) const SizedBox(width: 8),
          Expanded(
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => onChanged(type),
                borderRadius: BorderRadius.circular(AppRadius.full),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOut,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 10),
                  decoration: BoxDecoration(
                    color: selected == type
                        ? AppColors.primary
                        : Colors.white,
                    borderRadius: BorderRadius.circular(AppRadius.full),
                    border: Border.all(
                      color: selected == type
                          ? AppColors.primary
                          : AppColors.border,
                      width: 1.2,
                    ),
                    boxShadow: selected == type
                        ? [
                            BoxShadow(
                              color: AppColors.primary.withValues(alpha: 0.25),
                              blurRadius: 8,
                              offset: const Offset(0, 3),
                            ),
                          ]
                        : null,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        type.icon,
                        size: 16,
                        color: selected == type
                            ? Colors.white
                            : AppColors.textSecondary,
                      ),
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          type.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                            color: selected == type
                                ? Colors.white
                                : AppColors.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
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
        borderRadius: BorderRadius.circular(AppRadius.lg),
        boxShadow: AppShadows.lg,
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
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xxl)),
        boxShadow: AppShadows.lg,
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
                            fontFeatures: [FontFeature.tabularFigures()],
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
                            fontFeatures: [FontFeature.tabularFigures()],
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
              borderRadius: BorderRadius.circular(AppRadius.lg),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.danger.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(AppRadius.lg),
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

