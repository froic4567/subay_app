import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    // Validate that required env vars are present (allow VITE_ prefix as a
    // common alternate). Throwing here makes missing config visible early
    // with a clear message instead of failing silently with an invalid
    // API key at runtime.
    _validateRequiredVars();

    if (kIsWeb) return web;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      case TargetPlatform.macOS:
      case TargetPlatform.linux:
      case TargetPlatform.windows:
      case TargetPlatform.fuchsia:
        return web;
    }
  }

  static FirebaseOptions get web => FirebaseOptions(
        apiKey: _env('FIREBASE_API_KEY'),
        appId: _env('FIREBASE_APP_ID'),
        messagingSenderId: _env('FIREBASE_MESSAGING_SENDER_ID'),
        projectId: _env('FIREBASE_PROJECT_ID'),
        authDomain: _env('FIREBASE_AUTH_DOMAIN'),
        storageBucket: _env('FIREBASE_STORAGE_BUCKET'),
      );

  static FirebaseOptions get android => FirebaseOptions(
        apiKey: _env('FIREBASE_API_KEY'),
        appId: _env('FIREBASE_APP_ID'),
        messagingSenderId: _env('FIREBASE_MESSAGING_SENDER_ID'),
        projectId: _env('FIREBASE_PROJECT_ID'),
        storageBucket: _env('FIREBASE_STORAGE_BUCKET'),
      );

  static FirebaseOptions get ios => FirebaseOptions(
        apiKey: _env('FIREBASE_API_KEY'),
        appId: _env('FIREBASE_APP_ID'),
        messagingSenderId: _env('FIREBASE_MESSAGING_SENDER_ID'),
        projectId: _env('FIREBASE_PROJECT_ID'),
        storageBucket: _env('FIREBASE_STORAGE_BUCKET'),
      );

  static String _env(String key) {
    // Accept either the exact key or the VITE-prefixed variant used for
    // some local/dev workflows.
    return dotenv.env[key] ?? dotenv.env['VITE_$key'] ?? '';
  }

  static void _validateRequiredVars() {
    final required = [
      'FIREBASE_API_KEY',
      'FIREBASE_APP_ID',
      'FIREBASE_MESSAGING_SENDER_ID',
      'FIREBASE_PROJECT_ID',
    ];
    final missing = <String>[];
    for (final k in required) {
      if (_env(k).isEmpty) missing.add(k);
    }
    if (missing.isNotEmpty) {
      throw Exception(
          'Missing Firebase config environment variables: ${missing.join(', ')}.\n'
          'Set them in .env as either the names above or with VITE_ prefix (e.g. VITE_FIREBASE_API_KEY).');
    }
  }
}
