Date: 08/06/2026                   Time: (session time not tracked)

Changes Made:
- Created mobile-app-specific `SPEC.md`, `RULES.md`, and `LOGS.md` at the repository root, replacing the prior copies that actually described the sibling FloodSight Website Dashboard project.
- `SPEC.md` was rewritten from scratch to describe this Flutter app's real features: Google Sign-In auth, the four-tab home shell (Map / Routing / Notification / Profile), OpenStreetMap-based flood status mapping, the Dijkstra flood-aware routing engine with per-vehicle water-level tolerances, alert notifications, and the Node.js/Express + MongoDB backend it depends on.
- `RULES.md` was rewritten to document this codebase's actual conventions: `lib/screens` + `lib/services` + `lib/theme` + `lib/config` structure, `snake_case.dart` file naming, `PascalCase` classes, the plain `StatefulWidget`/`setState` pattern with singleton services (no Provider/Riverpod/Bloc), the emoji + `[Tag]` `print()` logging convention, and the backend's `/api/health`, `/api/cctv`, `/api/cctv/:status`, `/api/alerts` endpoints.
- `RULES.md` also records known inconsistencies to resolve later rather than fixing them in this pass: leftover "Subay"/"SUBAY" naming across `pubspec.yaml`, `lib/main.dart`'s `SubayApp` class, platform config files, and `backend/`; the mismatched Android package identifiers between `map_screen.dart` and `routing_screen.dart`; and the hardcoded MongoDB connection string in `backend/server.js`.

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
