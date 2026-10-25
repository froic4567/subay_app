# SUBAY

Flood Monitoring and Routing Mobile Application

## Overview

SUBAY is a Flutter-based mobile application designed to help users monitor flood-prone areas and identify safer routes during flood events.

Current Features:
- Interactive map using OpenStreetMap
- Flood status markers
  - Danger
  - Alert
  - Normal
- GPS location support
- Routing module (in development)
- Notification system (in development)
- User profile management

---

## Developers

- Froilan Areca
- [Add Team Members Here]

---

## Technologies Used

- Flutter
- Dart
- flutter_map
- OpenStreetMap
- geolocator
- Git
- GitHub

---

## Requirements

Before running the project, install:

### Flutter SDK

Download:

https://flutter.dev/docs/get-started/install

Verify installation:

```bash
flutter doctor
```

### Android Studio

Install Android Studio and ensure:

- Android SDK is installed
- Android Emulator is installed
- Flutter plugin installed
- Dart plugin installed

### Git

Download:

https://git-scm.com/downloads

Verify:

```bash
git --version
```

---

## Getting Started

### 1. Clone the Repository

```bash
git clone https://github.com/froic4567/subay_app.git
```

Move into project folder:

```bash
cd subay_app
```

---

### 2. Install Dependencies

```bash
flutter pub get
```

---

### 3. Check Flutter Setup

```bash
flutter doctor
```

Resolve any issues before proceeding.

---

### 4. Run the Application

For Windows:

```bash
flutter run -d windows
```

For Android Emulator:

```bash
flutter run
```

For Chrome:

```bash
flutter run -d chrome
```

---

### 5. Physical Device Testing

The app auto-detects a backend URL for web (`localhost:3000`) and the Android emulator (`10.0.2.2:3000`), but a real phone cannot reach either of those — `localhost` on a phone means the phone itself.

To run on a physical device on the same Wi-Fi network as your dev machine:

1. Start the backend (`cd backend && npm run dev`) — it already listens on all network interfaces, so no backend changes are needed.
2. Find your dev machine's LAN IP:
   ```bash
   ipconfig
   ```
   Look for the `IPv4 Address` under your active Wi-Fi adapter (e.g. `192.168.1.23`).
3. In the root `.env` file, set:
   ```
   BACKEND_URL=http://192.168.1.23:3000
   ```
4. Connect your phone via USB with debugging enabled, then run:
   ```bash
   flutter run
   ```
   and select the physical device.

If the app can't reach the backend, check that Windows Firewall allows inbound connections on TCP port 3000.

---

## Database Test Scenarios

The database test loader applies one selected scenario per run. It displays each
sensor location, status, and water level, then waits for the exact confirmation
`UPLOAD` before writing. To run it from PowerShell:

```powershell
cd backend
py -m pip install -r requirements-test-data.txt
py load_test_scenarios.py
```

Review and manually edit the `CAMERAS` coordinates in
`backend/load_test_scenarios.py` before running if your sensor locations change.
The default menu lets you select Set 1, Set 2, or Set 3. To preselect a set while
still requiring upload confirmation, use `py load_test_scenarios.py --scenario 2`.
Press Enter at the menu or enter anything other than `UPLOAD` at confirmation
to cancel without changing MongoDB.

Set 1 marks the existing camera and CCTV 3 ALERT; Set 2 marks those two DANGER,
CCTV 2 and 4 ALERT, and CCTV 5 SAFE; Set 3 marks CCTV 1 through 4 DANGER and
CCTV 5 SAFE.

The loader reads `MONGODB_URI`, `MONGODB_DB`, and `MONGODB_COLLECTION` from
`backend/.env` (or the process environment). Each run updates matching sensor
records or inserts missing ones; it does not delete records or replace existing
camera configuration.

It uses 0.05 m for SAFE, 0.20 m for ALERT, and 0.50 m for DANGER, in accordance
with the app's green, orange, and red status colors. GeoJSON coordinates are
stored as `[longitude, latitude]`.

## Project Structure

```text
lib/
│
├── main.dart
│
├── screens/
│   ├── home_screen.dart
│   ├── login_screen.dart
│   ├── map_screen.dart
│   ├── routing_screen.dart
│   ├── notification_screen.dart
│   └── profile_screen.dart
│
└── theme/
    └── app_colors.dart
```

---

## Git Workflow

### Create a Feature Branch

Never work directly on main.

Example:

```bash
git switch -c map-feature
```

or

```bash
git switch -c gps-feature
```

---

### Commit Changes

```bash
git add .
git commit -m "Added GPS functionality"
```

---

### Push Branch

```bash
git push -u origin gps-feature
```

---

### Merge to Main

After testing:

```bash
git switch main
git merge gps-feature
git push origin main
```

---

## Common Commands

Get dependencies:

```bash
flutter pub get
```

Run app:

```bash
flutter run
```

Clean build:

```bash
flutter clean
```

Reinstall packages:

```bash
flutter pub get
```

Check Flutter:

```bash
flutter doctor
```

---

## Current Development Status

### Completed

- Login UI
- Home Screen
- Basic Navigation
- OpenStreetMap Integration
- Flood Markers

### In Progress

- GPS Tracking
- Route Planning
- Flood Data Integration

### Planned

- Real-time Flood Monitoring
- Emergency Notifications
- Route Optimization
- User Authentication

---

## Repository

GitHub:

https://github.com/froic4567/subay_app

---

## License

For academic and educational purposes only.
