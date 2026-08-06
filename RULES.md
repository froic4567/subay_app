---
title: Codebase Rules
subtitle: FloodSight Mobile Application
---

# FloodSight Mobile Application Codebase Rules

This document records the naming conventions, formatting practices, and implementation patterns used throughout this Flutter repository. New code should follow these rules unless an existing framework or external contract requires otherwise.

## 1. Project Structure and File Naming

- Keep application source code under `lib/` and organize it by responsibility:
  - `lib/screens` for full-page, route-level widgets.
  - `lib/services` for singleton/static service classes that own networking and business logic (auth, backend API access, geocoding, routing, logging).
  - `lib/theme` for shared design tokens such as `AppColors`.
  - `lib/config` for compile-time app configuration and debug flags.
- Use `snake_case.dart` for all Dart file names, such as `map_screen.dart`, `cctv_service.dart`, `route_planner.dart`.
- Name a screen file after the screen it renders (`login_screen.dart`, `home_screen.dart`) and a service file after the domain it serves (`auth_service.dart`, `geocoding_service.dart`) rather than generic names like `helpers.dart`.
- Keep the Node.js/Express backend under `backend/` (`server.js`, `package.json`), separate from Flutter application code.
- Load Firebase and backend secrets from `.env` rather than hardcoding them. The Flutter app should use `flutter_dotenv`; the backend should use `dotenv`.
- Keep documentation files at the repository root: `SPEC.md` for product requirements, `LOGS.md` for chronological engineering notes, and `README.md` for concise reference material.

## 2. Identifiers and Naming

- Use `camelCase` for variables, function parameters, and object properties: `waterLevelM`, `floodStatus`, `connectedIds`.
- Use `PascalCase` for classes, enums, and typedefs: `RoutePlanner`, `RouteNode`, `VehicleType`, `CctvService`.
- Prefix private helper classes and members with `_`: `_MinHeap`, `_Edge`, `_DijkstraResult`.
- Use uppercase string values for flood statuses at the routing layer: `DANGER`, `ALERT`, `SAFE`/`NORMAL`. The backend and raw API responses use lowercase (`danger`, `alert`, `safe`); normalize to uppercase at the point where routing logic consumes them, matching the existing pattern in `route_planner.dart`.
- Keep terminology consistent with the domain model across screens and services: `waterLevel`/`waterLevelM`, `floodStatus`/`status`, `vehicleType`, `roadName`.

## 3. Dart and Flutter Language Use

- Use `.dart` for all application code; there is no JS/TS split in this project (the only other language is the separate Node.js backend under `backend/`).
- Dart SDK constraint is `^3.12.2` (see `pubspec.yaml`); use language features compatible with that constraint.
- Define explicit types for public class fields, method signatures, and constructor parameters — avoid `dynamic` except at genuine JSON-decoding boundaries (`Map<String, dynamic>` from `jsonDecode`).
- Use `const` constructors wherever a widget or object is immutable.
- Prefer named, required constructor parameters (`required this.field`) for domain objects such as `RouteNode`, matching existing style.

## 4. Widgets and State

- Use function-free, class-based `StatefulWidget`/`StatelessWidget` with hooks-free `setState` for local UI state — this project does not use Provider, Riverpod, Bloc, or any other state-management package, and new code should not introduce one without a deliberate, discussed architecture change.
- Keep cross-screen data flow explicit: pass callbacks and data through constructor parameters (as `HomeScreen` does to hand a routing destination from the Map tab to the Routing tab) rather than adding global/ambient state.
- Put reusable business logic and networking in `lib/services` singleton/static classes, not inline in widget build methods.
- Keep `IndexedStack`-based tab state preservation in the home shell; do not replace tabs with a pattern that rebuilds screens from scratch on every switch without a specific reason.

## 5. Routing and Navigation

- Use Flutter's built-in named-route `MaterialApp` navigation (`initialRoute`, `routes: { ... }`) as configured in `lib/main.dart`; do not introduce a routing package unless the app's navigation needs materially outgrow this.
- Keep route names simple and lowercase with a leading slash: `/login`, `/home`.
- Keep tab-level navigation inside the home shell (`IndexedStack` + bottom navigation bar) rather than pushing new routes for each tab.

## 6. Backend and Data Access

- Keep backend logic in `backend/server.js` (Node.js/Express) with MongoDB access via the official `mongodb` driver.
- Preserve the current API surface and behavior:
  - `GET /api/health` — connectivity check.
  - `GET /api/cctv` — all flood/CCTV documents.
  - `GET /api/cctv/:status` — documents filtered by status.
  - `GET /api/alerts` — documents with status `alert` or `danger`, sorted newest first.
- Keep the backend fully database-driven: on MongoDB failure or empty results, endpoints must return an empty array/list, never hardcoded sample flood data.
- On the Flutter side, keep all backend calls behind `lib/services/cctv_service.dart`; do not call `http` directly from screens for CCTV/alert data.
- Preserve the platform-aware base URL selection in `CctvService` (`localhost:3000` on web, `10.0.2.2:3000` on the Android emulator) when modifying networking code.
- Validate and normalize external data (backend JSON, OSRM/Nominatim responses) at the service boundary before it reaches UI widgets.

## 7. State and Persistence

- There is no local persistence layer (no `shared_preferences`, no database) in the Flutter app; authenticated user state lives in-memory in `AuthService` for the session.
- Keep the Dijkstra routing graph and its intermediate state scoped to a single `RoutePlanner.planRoute()` call; do not cache route graphs across requests without a deliberate caching strategy.

## 8. Styling and UI

- Define shared colors in `lib/theme/app_colors.dart` as `static const` values; do not hardcode color literals in screen widgets.
- Use Material 3 theming (`useMaterial3: true`) seeded from `AppColors.primary`, as configured in `lib/main.dart`.
- Keep flood-status color coding (DANGER/ALERT/NORMAL) visually consistent across the map, routing, and notification screens.
- Use `flutter_svg` for vector logos/icons and Material `Icons` (via `lucide`-style semantic choices where applicable) for interface actions.

## 9. Formatting and Linting

- Follow standard `dart format` formatting for all Dart code.
- Run `flutter analyze` (backed by `flutter_lints` via `analysis_options.yaml`) before submitting changes; there are currently no custom rule overrides, so keep new code compliant with the stock `flutter_lints` rule set rather than adding suppressions.
- Keep imports organized and remove imports that are no longer used.

## 10. Error Handling and Logging

- Use `try`/`catch` around all network calls (backend, OSRM, Nominatim, Google Sign-In) and fail to a safe, empty/fallback state rather than letting exceptions reach the UI unhandled — this matches the existing pattern in `CctvService` and `RoutePlanner`.
- Use `print()` debug logging with an emoji status marker and a bracketed feature tag, matching the existing convention: `🔌`/`📡`/`✅`/`❌`/`⚠️` prefixes with tags like `[CCTV]`, `[Alerts]`, `[Notifications]`, `[Auth]`. Keep this convention rather than introducing a separate logging package.
- Route planning must record structured metrics via `RoutingTestLogger` (`lib/services/routing_test_logger.dart`) rather than ad hoc print statements, since these logs are used for empirical evaluation.
- Never log credentials or the MongoDB connection string.

## 11. Comments and Documentation

- Use `///` doc comments on classes and public methods to explain non-obvious rationale (e.g., why the routing graph merges multiple OSRM candidates, why ALERT edges are penalized rather than blocked) — this is the established style in `route_planner.dart` and `cctv_service.dart`.
- Use numbered-step `//` comments for multi-stage algorithms (e.g., "1. Fetch...", "2. Fetch OSRM...") when a method has several sequential phases, matching existing style.
- Keep comments sparse elsewhere; do not restate what a line obviously does.
- Update `SPEC.md` and this document when routes, API endpoints, data shapes, or architectural patterns change.
- Document prototype/limitation behavior honestly (e.g., that flood data returns empty rather than falling back to samples when the database is down).

## 12. Existing Inconsistencies to Resolve Gradually

The following patterns exist in the current repository but should not be expanded in new code:

- Legacy "Subay"/"SUBAY" naming remains in several places even though the product is branded FloodSight: `pubspec.yaml` (`name: subay`), the `SubayApp` class in `lib/main.dart`, `README.md`, `lib/services/auth_service.dart` and `lib/services/geocoding_service.dart` (fallback strings/User-Agent), `lib/screens/login_screen.dart` and `lib/screens/profile_screen.dart` (fallback display text), Android (`android/app/build.gradle.kts`, `AndroidManifest.xml`), iOS (`ios/Runner/Info.plist`), `web/manifest.json`, `backend/package.json`, `backend/server.js`, and `test/widget_test.dart`. Rename only as a deliberate, coordinated rebrand — not incidentally while touching nearby code.
- The Android application/package identifiers are inconsistent between `lib/screens/map_screen.dart` (`com.subay.app` tile-layer user agent) and `lib/screens/routing_screen.dart` (`com.example.subay`); reconcile these together with the broader rebrand rather than picking one ad hoc.
- The MongoDB Atlas connection string is hardcoded in `backend/server.js` instead of read from an environment variable; do not copy this pattern into new backend code, and migrate it to `.env`/`process.env` when the backend is next touched. This change should also use `process.env.MONGODB_DB` and `process.env.MONGODB_COLLECTION` when available.
- There is no `.env`/config abstraction for the Flutter app's backend base URL on physical devices (only web and Android-emulator cases are auto-detected); document this limitation rather than silently breaking on-device testing.

## 13. Change Checklist

- [ ] File and symbol names follow the conventions in this document.
- [ ] New service logic lives in `lib/services`, not inline in widgets.
- [ ] Shared colors/tokens come from `lib/theme/app_colors.dart`.
- [ ] No new state-management package was introduced without a deliberate architecture discussion.
- [ ] Backend endpoints remain database-driven (no hardcoded fallback flood data).
- [ ] Network calls are wrapped in error handling that degrades gracefully.
- [ ] `flutter analyze` and `dart format` pass for the changed code.
- [ ] Relevant documentation (`SPEC.md`, `LOGS.md`) is updated.
