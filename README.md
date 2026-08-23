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
