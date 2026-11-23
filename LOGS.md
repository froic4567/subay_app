Date: 11/23/2026                   Time: (session time not tracked)

Changes Made:
- Fixed the Map tab being permanently stuck on the "Loading flood data…" banner even though the Render backend was live. Root cause: the live `CCTVs / cctv data` collection contains records with no `location` field (e.g. `_id: feed-mastersons`, "Masterson's Avenue"). `map_screen.dart`'s `_convertDocToCctv` did `doc['location']['coordinates'] as List<dynamic>` with no guard, so that single document threw inside `_loadCctvData()` before `setState(() => _hasLoadedOnce = true)` ran; the 5-second status poll then retried and threw forever, so the first-load spinner never cleared.
- `lib/services/cctv_service.dart`: added `CctvService.hasValidLocation(doc)` and made `fetchCctvData()` (and `fetchAlerts()`) drop records without a usable GeoJSON point, logging how many were skipped. `fetchAllNotifications()` opts out with `?includeWithoutLocation=true` so location-less cameras still appear as notifications via `location_name`.
- `lib/screens/map_screen.dart`: `_convertDocToCctv` is now nullable and returns `null` for malformed records; `_loadCctvData()` skips them, always sets `_hasLoadedOnce = true` (even on error) and is guarded by `_isFetchingCctv` so the 5s poll can no longer stack overlapping requests during Render free-tier cold starts. `_loadRoadSegments` now catches lookup failures instead of surfacing an unhandled async error.
- Same crash class removed from the Routing tab and planner: `routing_screen.dart`'s road-segment loop and marker builder skip invalid documents, and `route_planner.dart`'s `_seedNodes` now builds nodes in a loop that skips location-less docs (also tolerates missing `status`/`water_level`).
- `backend/server.js`: `GET /api/cctv` now filters to geolocated documents by default (`location.coordinates.0/1` exist) so the currently installed APK stops breaking as soon as Render redeploys; `GET /api/cctv/:status` applies the same filter. Added `?includeWithoutLocation=true` for the notification path. No endpoint removed; still fully database-driven and still returns `[]` on DB failure.

Failures Flag:
- `flutter` is not installed / not on PATH on this machine, so `flutter analyze` could not be run here. `node --check backend/server.js` passes, and the backend was run locally against the real Atlas cluster to verify `/api/cctv` returns 6 geolocated docs vs 7 with `?includeWithoutLocation=true` and zero malformed records by default.

Verification:
- Queried the live `https://floodsight-api.onrender.com/api/cctv` before editing and confirmed 7 records with `Masterson's Avenue` having no `location` key at all. Reproduced the throw path in `_convertDocToCctv`, then re-read every edited region after the changes.

Date: 08/06/2026                   Time: (session time not tracked)

Changes Made:
- Created mobile-app-specific `SPEC.md`, `RULES.md`, and `LOGS.md` at the repository root, replacing the prior copies that actually described the sibling FloodSight Website Dashboard project.
- `SPEC.md` was rewritten from scratch to describe this Flutter app's real features: Google Sign-In auth, the four-tab home shell (Map / Routing / Notification / Profile), OpenStreetMap-based flood status mapping, the Dijkstra flood-aware routing engine with per-vehicle water-level tolerances, alert notifications, and the Node.js/Express + MongoDB backend it depends on.
- `RULES.md` was rewritten to document this codebase's actual conventions: `lib/screens` + `lib/services` + `lib/theme` + `lib/config` structure, `snake_case.dart` file naming, `PascalCase` classes, the plain `StatefulWidget`/`setState` pattern with singleton services (no Provider/Riverpod/Bloc), the emoji + `[Tag]` `print()` logging convention, and the backend's `/api/health`, `/api/cctv`, `/api/cctv/:status`, `/api/alerts` endpoints.
- `RULES.md` also records known inconsistencies to resolve later rather than fixing them in this pass: leftover "Subay"/"SUBAY" naming across `pubspec.yaml`, `lib/main.dart`'s `SubayApp` class, platform config files, and `backend/`; the mismatched Android package identifiers between `map_screen.dart` and `routing_screen.dart`; and the hardcoded MongoDB connection string in `backend/server.js`.

Date: 08/23/2026                   Time: (session time not tracked, second session)

Changes Made:
- Continuous GPS location tracking: added `lib/services/location_service.dart` (`LocationService`), consolidating the location-services-enabled → permission-check → permission-request flow that was duplicated across `map_screen.dart` and `routing_screen.dart`, plus thin wrappers for a one-shot fetch and a continuous position stream. `map_screen.dart` now subscribes to a continuous stream in `initState()` (via a new `_startLocationTracking()`) so the "my location" marker stays live across tab switches and regardless of navigation state (the Map tab's `IndexedStack`-preserved state keeps the subscription alive); the stream deliberately never moves the map camera, so it doesn't fight the user's own panning/zooming. The "Current Location" button (`_goToCurrentLocation`) now recenters instantly using the latest tracked fix when available, falling back to a fresh one-shot fetch only if tracking hasn't produced one yet — its permission-denied SnackBar messages are unchanged.
- Fixed a pre-existing bug found while touching this code: `routing_screen.dart`'s `_stopGpsTracking()`/`dispose()` only nulled the `Stream<Position>?` reference from `_startGpsTracking()`'s `Geolocator.getPositionStream(...)`, never storing or cancelling the actual `StreamSubscription` returned by `.listen(...)` — so the position listener kept running (and calling `setState`) after "End Navigation" or screen disposal. Now stored in a `StreamSubscription<Position>? _positionSub` field and properly cancelled in both places. `routing_screen.dart`'s existing navigation-gated tracking behavior (10m distance filter, high accuracy, auto-recentering camera-follow, start/stop tied to Start/End Navigation) is otherwise unchanged — it now goes through `LocationService` for the permission check only.
- Routing quality — unnecessary turns: `RoutePlanner._addCrossLinks()` (`lib/services/route_planner.dart`) previously linked any two points from different OSRM candidate routes whenever they were within 35m of each other, anywhere on the map, regardless of proximity to a flood. Since OSRM's alternate routes frequently run near-parallel, this let Dijkstra hop between candidates for a trivial geometric shortcut with no safety benefit, producing unnecessary turns/detours. Added a one-line guard so a cross-link is only created when at least one endpoint is within a hazard's propagated zone (`nodeHazard[i] != null || nodeHazard[j] != null`) — elsewhere each OSRM candidate stays a single coherent, real road. Escape/rejoin links near an actual flood are unaffected, since `_computeVertexHazards` already flags every vertex within the existing ~200m hazard-propagation window before this check runs.
- No changes to `_computeVertexHazards`/`_hazardPropagationM` (already fixed the "flood on a long straight road" case in the prior session), `_dijkstra`, `_fetchDetourRoutes`/`_dangersNearCandidates`, or `RoutingTestLogger`.

Failures Flag:
- None — `flutter analyze` passes with only the pre-existing `avoid_print` info-level hints; `flutter test` shows the same pre-existing unrelated `FirebaseException` failure in `AuthGate` noted in the prior session's entry, not touched by this work.

Verification:
- Confirmed all edited line ranges (`map_screen.dart`'s `initState`/`_goToCurrentLocation`/`dispose`; `routing_screen.dart`'s `_useCurrentLocation`/`_startGpsTracking`/`_stopGpsTracking`/`dispose`; `route_planner.dart`'s `_addCrossLinks`) directly against source before editing. Ran `flutter analyze lib/` and reviewed diffs after implementation to confirm no unrelated formatting drift.

Date: 08/23/2026                   Time: (session time not tracked)

Changes Made:
- Backend connectivity: added an optional `BACKEND_URL` override (read via `flutter_dotenv`) to `CctvService._baseUrl` (`lib/services/cctv_service.dart`), so a physical device can reach the backend over LAN instead of `localhost`/`10.0.2.2`. The existing web/emulator auto-detection is unchanged when `BACKEND_URL` is unset. Documented the new key in `.env.example` and added a "Physical Device Testing" section to `README.md`. Confirmed `backend/server.js` needed no changes — it already binds to all interfaces with open CORS.
- Map tab: added `lib/services/road_segment_service.dart`, which queries the free Overpass API (OpenStreetMap) to resolve the real road geometry nearest each camera's stored coordinate, clipped to ~200m each direction along the matched road, cached in-memory per camera. `lib/screens/map_screen.dart` now renders these as colored `PolylineLayer`s (reusing `routing_screen.dart`'s dark-outline-then-color double-stroke pattern and `CctvLocation.statusColor`) under the existing camera markers, and polls CCTV status every 5 seconds (mirroring `routing_screen.dart`'s reroute-polling cadence) so segment color follows status changes without re-fetching geometry.
- Routing tab: extended `lib/services/route_planner.dart`'s graph construction so a hazard's effect propagates along a contiguous ~200m arc-length window of the route polyline (`_computeVertexHazards`, `_edgeWeightFromVertexHazards`), instead of only blocking the one OSRM edge that happens to graze the camera's exact coordinate within the old 80m point-radius check (`_segmentWeight`, still used unchanged for origin/destination stub edges and the benchmark-only `_measureMultiFeedOverhead`). OSRM candidate polylines are densified to ~20m spacing (`GeoUtils.densify`) beforehand so long, sparsely-vertexed straight roads get the fix's benefit. `_addCrossLinks` was updated to share the same per-vertex hazard assignment instead of re-deriving it from a raw radius check, so a hazard is treated consistently whether an edge is within one OSRM candidate or crosses between two.
- Added `lib/services/geo_utils.dart` with shared point-projection/densify/arc-length-clip primitives used by both `RoadSegmentService` and `RoutePlanner`.
- No CCTV database schema changes; no removal of existing markers, Dijkstra structure, cross-linking, OSRM fetch/detour logic, or the 4 backend API endpoints.

Failures Flag:
- None — `flutter analyze` passes with only the pre-existing `avoid_print` info-level convention hints (no new warnings/errors); `flutter test` was already failing before this session on an unrelated `FirebaseException` in `AuthGate` (confirmed via `git stash` against the pre-change baseline), not touched by this work.

Verification:
- Confirmed `_baseUrl`, `_buildGraph`, `_segmentWeight`, and `_addCrossLinks` line numbers/contents directly against source before editing. Ran `flutter analyze lib/` and `dart format` on all changed/new files after implementation.

Date: 08/06/2026                   Time: (session time not tracked)

Changes Made:
- Migrated Flutter auth from standalone `google_sign_in` to Firebase Authentication with Google sign-in.
- Added Firestore profile persistence for users under `users/{uid}`.
- Replaced the login fallback/demo user path with a strict auth gate and on-screen error handling.
- Added root `.env` support for Firebase config and backend `backend/.env` support for MongoDB connection via `dotenv`.
- Scrubbed `PROMPTS/firebaseGoogleAuthentication.md` of live service keys and moved configuration into env variable placeholders.
- Updated `SPEC.md`, `RULES.md`, and this log entry to reflect Firebase Auth, Firestore, and `.env` secret handling.

Failures Flag:
- None — code and docs updates completed together.

Verification:
- Confirmed the technical details written into `SPEC.md` and `RULES.md` against the actual source: `pubspec.yaml` (dependency versions, Dart SDK constraint), `lib/main.dart` (routing, theming), `lib/services/route_planner.dart` (vehicle types, water-level thresholds, Dijkstra/graph approach), `lib/services/cctv_service.dart` (backend base URL selection, logging convention), and `backend/server.js` (API endpoints, database-driven behavior, hardcoded connection string).
