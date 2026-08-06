import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
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

  final _googleSignIn = GoogleSignIn(
    scopes: ['email', 'profile'],
  );

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
          print('⚠️ [Auth] User cancelled sign-in');
          return null;
        }

        final googleAuth = await googleUser.authentication;
        if (googleAuth.idToken == null || googleAuth.accessToken == null) {
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
      print('❌ [Auth] Sign-in failed: $error');
      return null;
    }
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
