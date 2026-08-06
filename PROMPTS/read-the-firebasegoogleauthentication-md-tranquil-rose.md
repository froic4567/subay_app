# Migrate Sign-In to Firebase Auth (Google), shared with FloodSight Web Dashboard

## Context

The mobile app's current "sign-in" (`lib/services/auth_service.dart` + `lib/screens/login_screen.dart`) uses the standalone `google_sign_in` package with no backend verification and no persistence — the code comment literally says "The user is verified via Google but NOT stored in any database." Worse, if Google Sign-In fails or is cancelled, `login_screen.dart` silently calls `AuthService.instance.setDemoUser()` and still navigates into the app (`lib/screens/login_screen.dart:31-49`), so unauthenticated users get full access today.

The FloodSight Website Dashboard already uses Firebase (project `floodsight-flood-monitoring`) with Google Sign-In as its only auth method. The goal is to point the mobile app at the *same* Firebase project so both surfaces share one user identity/database, and to make the login screen actually gate access.

This is a deliberate architecture change from the project's documented state: `SPEC.md` and `RULES.md` currently say "No Firebase is used anywhere in this app" and list Firebase auth as explicitly out of scope. Per user decision, we proceed with Firebase and **must update `SPEC.md`, `RULES.md`, and `LOGS.md`** as part of this change (per `RULES.md`'s own requirement that architecture changes be reflected in the docs, and its change checklist).

User-confirmed decisions guiding this plan:
- Add Firebase (don't work around it) — update docs afterward.
- Remove the demo-mode fallback entirely; failed/cancelled sign-in keeps the user on the login screen with an error.
- Store mobile user profiles in **Cloud Firestore** under the same `floodsight-flood-monitoring` Firebase project. This is separate from the CCTV MongoDB backend (`backend/server.js`), which continues to serve flood/CCTV data only — do not conflate the two.
- Move secrets (Firebase web config, Mongo URI) into `.env`-based config instead of hardcoding/committing them, and add `.env` to `.gitignore`.

## Known blocker to flag to the user before/while implementing

`PROMPTS/firebaseGoogleAuthentication.md` is tracked in git and contains a **live MongoDB Atlas connection string with a real password** in plaintext. That file should be scrubbed of the raw secret (replace with a placeholder + pointer to `.env`), and the password should be rotated in MongoDB Atlas — Copilot/the editor cannot rotate the Atlas password; flag this to the user as a manual follow-up.

## Prerequisites / setup (outside the code editor, needed before Copilot can wire anything up)

1. In the Firebase console for project `floodsight-flood-monitoring`, register a new Android app (and iOS app if iOS is targeted) — this produces `google-services.json` (Android) / `GoogleService-Info.plist` (iOS).
2. Run `flutterfire configure` (FlutterFire CLI) against this project to generate `lib/firebase_options.dart` and wire platform config automatically. This requires Firebase CLI + FlutterFire CLI installed and login to the Google account that owns the project.
3. Confirm in the Firebase console that Google is enabled as a Sign-In provider under Authentication, and confirm whether the dashboard actually stores user profiles in Firestore (the plan assumes yes per user decision) so the mobile app writes to the same collection/shape the dashboard expects — check the website dashboard repo's Firestore collection name/schema before writing mobile-side Firestore code.

## Implementation steps

### 1. Add dependencies (`pubspec.yaml`)
Add `firebase_core`, `firebase_auth`, `cloud_firestore` (latest stable compatible with Dart SDK `^3.12.2`). Keep `google_sign_in` — it's still needed to obtain a Google `idToken`/`accessToken` on Android/iOS, which is then exchanged for a Firebase credential via `GoogleAuthProvider.credential(...)`.

### 2. Initialize Firebase (`lib/main.dart`)
Make `main()` async, call `WidgetsFlutterBinding.ensureInitialized()` then `Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform)` (from the generated `firebase_options.dart`) before `runApp`.

### 3. Rewrite `lib/services/auth_service.dart`
- Replace the in-memory-only implementation with one backed by `firebase_auth`:
  - `signInWithGoogle()`: get a `GoogleSignInAccount` via `google_sign_in`, obtain its auth tokens, build a `GoogleAuthProvider` credential, call `FirebaseAuth.instance.signInWithCredential(...)`. On success, upsert the user's profile into Firestore (e.g. a `users/{uid}` document with displayName/email/photoUrl/lastLogin) so it matches what the dashboard expects.
  - Remove `setDemoUser()` entirely — no fallback path.
  - Expose `currentUser` derived from `FirebaseAuth.instance.currentUser` (or keep an `AppUser` wrapper mapped from it) and an `authStateChanges()` stream for the app to react to sign-in/sign-out.
  - `signOut()`: sign out of both `FirebaseAuth` and `GoogleSignIn`.
  - Keep the existing `print()` logging convention with `🔐/✅/❌/⚠️` + `[Auth]` tag per `RULES.md`, and never log tokens/credentials.

### 4. Fix `lib/screens/login_screen.dart`
- Remove the `setDemoUser()` fallback block (lines ~31-49) entirely.
- On `signInWithGoogle()` returning null/throwing, stay on the login screen and show an error `SnackBar` — do not navigate anywhere.
- On success, navigate to `/home` via the named route (`Navigator.pushReplacementNamed(context, '/home')`) instead of the current direct `MaterialPageRoute` construction, for consistency with `main.dart`'s route table.

### 5. Add a real auth guard (`lib/main.dart`)
Replace the static `initialRoute: '/login'` with a gate widget (e.g. `AuthGate`) as the `home:` widget, built on a `StreamBuilder<User?>` over `FirebaseAuth.instance.authStateChanges()`, that shows `LoginScreen` when signed out and `HomeScreen` when signed in. Keep the `/login` and `/home` named routes for internal navigation (sign-out, etc.) but make the initial entry point the guard so `/home` can no longer be reached without a real session.

### 6. Update `lib/screens/profile_screen.dart`
Confirm it still reads `AuthService.instance.currentUser` correctly against the new Firebase-backed shape, and that sign-out routes back through the `AuthGate` (or directly to `/login`) correctly.

### 7. Secrets hygiene
- Add a `.env` (git-ignored) holding the Firebase web config values and anything else currently hardcoded; do not commit real values. Add `.env.example` with placeholder keys for onboarding.
- Scrub `PROMPTS/firebaseGoogleAuthentication.md` of the raw MongoDB URI/password — replace with a reference to `.env`.
- `backend/server.js`'s hardcoded MongoDB URI (flagged separately in `RULES.md` §12 as pre-existing debt) — migrate it to read from `process.env` while touching this area, per RULES.md's own instruction to fix this "when the backend is next touched." Use a `.env` file there too (e.g. via `dotenv`), git-ignored.
- Confirm `.gitignore` covers `.env`, `google-services.json`, and `GoogleService-Info.plist` if those are meant to stay local (check with the user if Android/iOS build config secrets should be committed or not — Firebase's `google-services.json` is commonly committed since it's not a true secret, but confirm before assuming).

### 8. Docs updates (required per RULES.md's change checklist)
- `SPEC.md`: update the "Google Sign-In (no Firebase)" language to describe Firebase Auth + Firestore-backed shared user accounts with the dashboard; remove "Firebase-based authentication" from the Out of Scope section.
- `RULES.md`: add Firebase Auth/Firestore conventions (where service code for it lives — presumably still `lib/services/auth_service.dart` — and the `.env` secret-handling convention).
- `LOGS.md`: add a new dated entry describing this change, matching the existing entry's format.

## Files to touch
- `pubspec.yaml`
- `lib/main.dart`
- `lib/services/auth_service.dart`
- `lib/screens/login_screen.dart`
- `lib/screens/profile_screen.dart` (verify only, likely minor/no change)
- `lib/firebase_options.dart` (generated by `flutterfire configure`, not hand-written)
- `.env`, `.env.example`, `.gitignore`
- `PROMPTS/firebaseGoogleAuthentication.md` (scrub secret)
- `backend/server.js` (Mongo URI → env var)
- `SPEC.md`, `RULES.md`, `LOGS.md`

## Verification
1. `flutter pub get` succeeds with new dependencies.
2. `flutter analyze` and `dart format --set-exit-if-changed .` pass clean (RULES.md requires no custom lint suppressions).
3. Run the app (`flutter run`, web or Android emulator): confirm cold start goes to `/login`, "Continue with Google" opens the real Google account picker, successful sign-in lands on `/home` with the correct account name/email/photo on the Profile tab.
4. Cancel the Google picker or force a failure: confirm the app stays on `/login` and shows an error — no demo-mode entry.
5. In the Firebase console, confirm the signed-in user appears under Authentication, and a matching document appears in Firestore.
6. Kill and relaunch the app while signed in: confirm the `AuthGate` sends the user straight to `/home` (session persistence via `firebase_auth`), not back to `/login`.
7. Sign out from the Profile screen: confirm it returns to `/login` and a subsequent relaunch does not auto-sign-in.
8. Confirm CCTV/flood data (MongoDB-backed) still loads normally on `/home` — this change must not touch `cctv_service.dart` or `backend/server.js`'s API surface beyond the env-var migration.
