import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:google_sign_in/google_sign_in.dart';

/// Holds the signed-in user's details for display across the app.
class AppUser {
  final String displayName;
  final String email;
  final String? photoUrl;
  final String id;

  const AppUser({
    required this.displayName,
    required this.email,
    required this.id,
    this.photoUrl,
  });
}

/// Singleton service that manages Firebase-backed Google authentication.
class AuthService {
  AuthService._internal();
  static final AuthService instance = AuthService._internal();

  // Web OAuth client from google-services.json. Passed explicitly because the
  // generated `default_web_client_id` resource is stripped from release APKs
  // by resource shrinking; without it Google returns no ID token on Android.
  static const String _fallbackServerClientId =
      '110929104093-so4fhjr6iusqb9hr9h6r6qgt2en77tma.apps.googleusercontent.com';

  final _googleSignIn = GoogleSignIn(
    scopes: ['email', 'profile'],
    serverClientId:
        dotenv.env['GOOGLE_SERVER_CLIENT_ID'] ?? _fallbackServerClientId,
  );

  /// Human-readable reason for the last failed sign-in attempt.
  /// Shown on the login screen so failures are not silent on mobile.
  String? lastError;

  AppUser? get currentUser => _userFromFirebase(FirebaseAuth.instance.currentUser);

  Stream<User?> authStateChanges() => FirebaseAuth.instance.authStateChanges();

  AppUser? _userFromFirebase(User? user) {
    if (user == null) return null;

    return AppUser(
      id: user.uid,
      displayName: user.displayName ?? 'FloodSight User',
      email: user.email ?? '',
      photoUrl: user.photoURL,
    );
  }

  /// Attempts Google Sign-In and returns the authenticated [AppUser].
  /// Returns null if the user cancels or authentication fails.
  Future<AppUser?> signInWithGoogle() async {
    print('🔐 [Auth] Initiating Google Sign-In...');
    lastError = null;
    try {
      final UserCredential userCredential;

      if (kIsWeb) {
        // On web, Firebase Auth's own popup flow is project-scoped and
        // doesn't need the google_sign_in package's separate OAuth client ID.
        final provider = GoogleAuthProvider()
          ..addScope('email')
          ..addScope('profile');
        userCredential = await FirebaseAuth.instance.signInWithPopup(provider);
      } else {
        final googleUser = await _googleSignIn.signIn();
        if (googleUser == null) {
          lastError = 'Sign-in was cancelled.';
          print('⚠️ [Auth] User cancelled sign-in');
          return null;
        }

        final googleAuth = await googleUser.authentication;
        if (googleAuth.idToken == null || googleAuth.accessToken == null) {
          lastError =
              'Google did not return an ID token. Make sure this app\'s '
              'SHA-1 fingerprint is registered in Firebase and that '
              'google-services.json is up to date.';
          print('❌ [Auth] Google authentication tokens are unavailable');
          return null;
        }

        final credential = GoogleAuthProvider.credential(
          idToken: googleAuth.idToken,
          accessToken: googleAuth.accessToken,
        );

        userCredential =
            await FirebaseAuth.instance.signInWithCredential(credential);
      }

      final firebaseUser = userCredential.user;
      if (firebaseUser == null) {
        print('❌ [Auth] Firebase returned no authenticated user');
        return null;
      }

      print('✅ [Auth] Sign-in successful!');
      print('   UID: ${firebaseUser.uid}');
      print('   Email: ${firebaseUser.email ?? 'unknown'}');
      print('   Name: ${firebaseUser.displayName ?? 'unknown'}');

      await _upsertUserProfile(firebaseUser);
      return currentUser;
    } catch (error) {
      lastError = _describeError(error);
      print('❌ [Auth] Sign-in failed: $error');
      return null;
    }
  }

  String _describeError(Object error) {
    final text = error.toString();
    if (text.contains('ApiException: 10') ||
        text.contains('DEVELOPER_ERROR')) {
      return 'DEVELOPER_ERROR: this build\'s SHA-1 fingerprint is not '
          'registered in Firebase for package com.example.subay.';
    }
    if (text.contains('ApiException: 12500')) {
      return 'Google could not complete sign-in (12500). Check the OAuth '
          'consent screen and that your Google account is allowed to test.';
    }
    if (text.contains('ApiException: 12501')) {
      return 'Sign-in was cancelled.';
    }
    if (text.contains('ApiException: 7') ||
        text.contains('network_error')) {
      return 'Network error. Check the phone\'s internet connection.';
    }
    return text;
  }

  Future<void> _upsertUserProfile(User user) async {
    try {
      final doc = FirebaseFirestore.instance.collection('users').doc(user.uid);
      await doc.set(
        {
          'displayName': user.displayName ?? 'FloodSight User',
          'email': user.email ?? '',
          'photoUrl': user.photoURL,
          'lastLogin': DateTime.now().toUtc().toIso8601String(),
        },
        SetOptions(merge: true),
      );
      print('✅ [Auth] User profile stored in Firestore for UID ${user.uid}');
    } catch (error) {
      print('⚠️ [Auth] Failed to update Firestore user profile: $error');
    }
  }

  /// Signs out the current user from Firebase Auth and Google Sign-In.
  Future<void> signOut() async {
    try {
      await FirebaseAuth.instance.signOut();
      print('🔐 [Auth] Firebase sign-out successful');
    } catch (error) {
      print('⚠️ [Auth] Firebase sign-out failed: $error');
    }

    try {
      await _googleSignIn.signOut();
      print('🔐 [Auth] Google sign-out successful');
    } catch (error) {
      print('⚠️ [Auth] Google sign-out failed: $error');
    }
  }

  bool get isSignedIn => FirebaseAuth.instance.currentUser != null;
}
