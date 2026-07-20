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

/// Singleton service that manages Google Sign-In.
///
/// The user is verified via Google but NOT stored in any database.
/// Their details are kept in memory only for display in the Profile screen.
class AuthService {
  AuthService._internal();
  static final AuthService instance = AuthService._internal();

  final _googleSignIn = GoogleSignIn(
    scopes: ['email', 'profile'],
  );

  AppUser? _currentUser;
  AppUser? get currentUser => _currentUser;

  /// Attempts Google Sign-In. Returns the [AppUser] on success, null on failure.
  Future<AppUser?> signInWithGoogle() async {
    print('🔐 [Auth] Initiating Google Sign-In...');
    try {
      final account = await _googleSignIn.signIn();
      if (account == null) {
        print('⚠️ [Auth] User cancelled sign-in');
        return null; // user cancelled
      }

      print('✅ [Auth] Sign-in successful!');
      print('   User: ${account.displayName}');
      print('   Email: ${account.email}');
      print('   ID: ${account.id}');

      _currentUser = AppUser(
        id: account.id,
        displayName: account.displayName ?? 'SUBAY User',
        email: account.email,
        photoUrl: account.photoUrl,
      );
      return _currentUser;
    } catch (e) {
      print('❌ [Auth] Sign-in failed: $e');
      print('   Make sure Google Cloud OAuth is configured correctly.');
      print('   Check web/index.html has the correct client ID.');
      return null;
    }
  }

  /// Signs out the current user and clears the session.
  Future<void> signOut() async {
    try {
      await _googleSignIn.signOut();
    } catch (_) {
      // ignore errors on sign-out
    }
    _currentUser = null;
  }

  /// Returns true if a user is currently signed in.
  bool get isSignedIn => _currentUser != null;

  /// Creates a demo user for development when Google Sign-In is not configured.
  void setDemoUser() {
    _currentUser = const AppUser(
      id: 'demo-user',
      displayName: 'Demo User',
      email: 'demo@subay.app',
      photoUrl: null,
    );
  }
}
