---
title: Product Specification
subtitle: FloodSight Mobile Application
---

# FloodSight Mobile Application

## 1. Product Overview

FloodSight is a Flutter-based mobile application for Cagayan de Oro City that helps everyday commuters see current flood conditions and get routed around flooded roads in real time. It is the mobile counterpart to the FloodSight Website Dashboard: both products read flood status from the same MongoDB-backed CCTV monitoring data, but this app is built for end users navigating the city, not for administrators managing cameras or accounts.

The current implementation is a functional prototype: it talks to a live Node.js/Express + MongoDB backend for flood data, but uses public OpenStreetMap services (OSRM, Nominatim) for map, geocoding, and base routing, and Google Sign-In via Firebase Authentication for authentication. User profiles are backed in Cloud Firestore so the mobile app can share accounts with the FloodSight Website Dashboard.

## 2. Project Goal

Build a mobile app that allows users to:

- view an interactive map of the city with live flood status markers,
- see their current GPS location relative to flood-prone points,
- request a route between two points that automatically avoids dangerous flooded roads and, where necessary, safely detours around passable-but-risky ones,
- choose a vehicle type so routing respects that vehicle's safe water-level tolerance,
- receive a running list of flood alerts and status changes,
- sign in with a Google account and view their profile.

## 3. Primary Users

- General public / commuters: sign in, view flood conditions, and get flood-aware directions.

This app has no admin role, user-management screen, or camera-configuration screen — those responsibilities belong to the FloodSight Website Dashboard, not this app.

## 4. Core Functional Requirements

### 4.1 Authentication

- The app must support Google Sign-In via Firebase Authentication and maintain user profiles in Cloud Firestore.
- Unauthenticated users land on the login screen (`/login`); after sign-in they are routed to the home shell (`/home`).
- A profile screen must show the signed-in Google account's name, email, and photo, and allow sign-out.

### 4.2 Home Shell and Navigation

- The home screen must present four tabs — Map, Routing, Notification, Profile — switched via an `IndexedStack` so tab state is preserved between switches.
- Selecting "Get Directions" from a map marker must hand the destination off to the Routing tab and switch to it.

### 4.3 Map and Flood Status

- The map must render OpenStreetMap tiles (via `flutter_map`) and support place search.
- Each monitored flood point must be shown as a color-coded marker for its status: DANGER, ALERT, or NORMAL/SAFE.
- In addition to the marker, the map must display the real road segment each camera monitors, colored to match its status. `lib/services/road_segment_service.dart` resolves this via the free Overpass API (OpenStreetMap): it finds the vehicle-usable road nearest the camera's stored coordinate and clips it to ~200 m each direction along that road's own geometry (`RoadSegmentService.clipDistanceM`). Results are cached in-memory per camera coordinate for the app session. If no road is found within the snap radius, no segment is drawn for that camera — the point marker still shows (no fabricated segment).
- The user's position must be tracked continuously (not just on demand) via `LocationService`/`geolocator`, so the "my location" marker stays live regardless of whether the user is navigating or on another tab; the "Current Location" button remains available as a manual recenter action.

### 4.4 Flood-Aware Routing

- The user must be able to choose a vehicle type — bicycle, motorcycle, sedan/car, SUV/van, or truck/bus — each with a fixed maximum safe water depth (0.15 m, 0.25 m, 0.40 m, 0.65 m, and 0.90 m respectively).
- Given an origin and destination, the app must compute a route using Dijkstra's algorithm over a graph built from multiple OSRM candidate routes plus generated detour waypoints around flood points, with live flood nodes from the database merged in as graph constraints.
- A flood hazard's effect on the graph is not limited to the single OSRM vertex nearest the camera's coordinate: candidate polylines are densified to ~20 m spacing and a hazard's block/penalty propagates up to ~200 m of arc length in both directions from its nearest point on the road (`RoutePlanner._computeVertexHazards`), so long, sparsely-vertexed straight roads are treated as affected along their whole flooded stretch rather than only at the exact camera point.
- Merging different OSRM candidate routes into one graph only cross-links two candidates' points when at least one is within a hazard's affected zone (`RoutePlanner._addCrossLinks`); this keeps a candidate a single coherent road elsewhere, avoiding unnecessary turns/detours that a distance-only cross-link (regardless of hazard proximity) would otherwise allow.
- DANGER points must always be treated as impassable; ALERT points must be passable only when the selected vehicle's water-level tolerance covers the reported depth, and are penalized in path weight even when passable.
- If no safe path exists, the app must fall back to the primary OSRM route and warn the user rather than failing silently.
- Routing must record performance and correctness metrics (path latency, database/OSRM fetch time, Dijkstra compute time, reroute behavior) for evaluation purposes.

### 4.5 Notifications / Alerts

- The notification screen must poll the backend for current flood status (`/api/alerts` and `/api/cctv`) and list flood points, newest first, color-coded to match their status.

### 4.6 Profile

- The profile screen must display the signed-in user's Google account details and provide a sign-out action.

## 5. Data Model Notes

The app is fully database-driven for flood data: if the backend or MongoDB is unavailable, endpoints return an empty list rather than falling back to hardcoded flood hazards, so the app never displays or routes around phantom danger points.

### CCTV / flood document (as returned by the backend)

- `status`: `"danger"` | `"alert"` | `"safe"` (lowercase from the API; the routing layer normalizes to uppercase `DANGER` / `ALERT` / `SAFE`/`NORMAL`)
- `water_level`: number, meters
- `location`: `{ type: "Point", coordinates: [lng, lat] }` (GeoJSON)
- `timestamp`: ISO date string

### Compatibility Note

- **Backend compatibility:** The backend now converts MongoDB `_id` values to string when returning API responses so the mobile app can reliably consume document identifiers. The mobile client is compatible with the expanded document structure (additional fields like `hsv_thresholds`, `roi_config`, `stream_config`, and `last_evaluation` are ignored by the app and do not affect routing or map rendering).

### RouteNode (internal routing graph node, `lib/services/route_planner.dart`)

- `id`, `name`, `roadName`: string
- `location`: `LatLng`
- `status`: string, one of `DANGER` / `ALERT` / `SAFE` / `NORMAL`
- `waterLevelM`: number, meters, taken directly from the database
- `connectedIds`: list of neighboring node IDs in the merged route graph

### VehicleType (`lib/services/route_planner.dart`)

- `bicycle`, `motorcycle`, `sedan`, `suv`, `truck`, each with a `maxWaterLevelM` tolerance used to decide whether an ALERT node is passable.

## 6. Visual and Interaction Requirements

- The interface uses Flutter's Material 3 theming, seeded from `AppColors.primary` (`lib/theme/app_colors.dart`).
- Navigation uses a persistent bottom navigation bar with four tabs (Map, Routing, Notification, Profile).
- Flood status indicators (DANGER / ALERT / NORMAL) must use consistent, distinct colors across the map, routing, and notification screens.
- UI states should provide clear feedback for loading, connection failure to the backend, and successful route computation.

## 7. Technical Stack

- Flutter with Dart SDK `^3.12.2`
- `flutter_map` (`^7.0.2`) for OpenStreetMap-based map rendering
- `latlong2` (`^0.9.1`) for coordinate types shared across map and routing code
- `geolocator` (`^13.0.2`) for GPS location
- `http` (`^1.5.2`) for backend, OSRM, and Nominatim requests
- `google_sign_in` (`^6.2.1`) for authentication (no Firebase)
- `flutter_svg` (`^2.0.9`) for vector logos/icons
- `cupertino_icons` (`^1.0.8`)
- `flutter_lints` (`^6.0.0`, dev dependency) for static analysis
- OSRM (`router.project-osrm.org`) for base route candidates
- Nominatim (OpenStreetMap) for geocoding and place search
- Overpass API (`overpass-api.de`, OpenStreetMap) for resolving the real road geometry a camera monitors, for Map tab road-segment visualization
- Backend: Node.js + Express (`backend/server.js`) with the `mongodb` driver, connecting to a MongoDB Atlas cluster (database `CCTVs`, collection `cctv data`)

## 8. Constraints and Implementation Guidelines

- No Firebase is used anywhere in this app; authentication is Google Sign-In only.
- No state-management package (Provider, Riverpod, Bloc, etc.) is used — shared state stays in `StatefulWidget`/`setState` and singleton service classes under `lib/services/`.
- The backend must remain database-driven: it must never substitute hardcoded/sample flood data when MongoDB is unreachable or empty.
- Keep the app usable when the backend is temporarily unreachable — CCTV/alert fetches must degrade to an empty list rather than crashing the UI.
- Preserve the existing platform-aware backend base URL selection (`localhost:3000` for web, `10.0.2.2:3000` for the Android emulator) when touching `CctvService`. An optional `BACKEND_URL` value in `.env` overrides this for physical-device testing over LAN.

## 9. Acceptance Criteria

- [ ] Users can sign in with Google and reach the home shell.
- [ ] Unauthenticated users land on the login screen.
- [ ] The map shows flood status markers color-coded by DANGER/ALERT/NORMAL, sourced from the live backend.
- [ ] Users can locate themselves on the map via GPS.
- [ ] Users can select a vehicle type and request a route between two points.
- [ ] Computed routes avoid DANGER points entirely and only cross ALERT points within the selected vehicle's water-level tolerance.
- [ ] When no safe path exists, the app falls back to the primary route and communicates the risk to the user.
- [ ] The notification screen lists current alerts, newest first, matching backend data.
- [ ] The profile screen shows the signed-in user's information and supports sign-out.

## 10. Out of Scope for This Version

- Admin or authority roles, and any user-role management (owned by the FloodSight Website Dashboard)
- Camera configuration, ROI, or HSV threshold management (owned by the FloodSight Website Dashboard)
- Push notifications
- Offline map or offline routing support
- Multi-language support
