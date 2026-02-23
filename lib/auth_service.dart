import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:flutter_facebook_auth/flutter_facebook_auth.dart';

/// Handles Firebase authentication for the Tour Guide app.
/// Supports anonymous sign-in (default), Google, and Facebook.
/// Anonymous accounts can be upgraded via linkWith* methods to preserve history.
class AuthService {
  static final FirebaseAuth _auth = FirebaseAuth.instance;
  static final GoogleSignIn _googleSignIn = GoogleSignIn();

  /// Sign in anonymously. Called on first launch if no user session exists.
  static Future<UserCredential> signInAnonymously() {
    return _auth.signInAnonymously();
  }

  /// Get the current user's Firebase ID token for API calls.
  /// Firebase auto-refreshes tokens every hour.
  static Future<String?> getIdToken() async {
    final user = _auth.currentUser;
    if (user == null) return null;
    try {
      return await user.getIdToken();
    } catch (_) {
      return null;
    }
  }

  /// Upgrade anonymous account by linking a Google credential.
  /// Preserves the same Firebase UID so all tour history is retained.
  static Future<UserCredential> linkWithGoogle() async {
    final googleUser = await _googleSignIn.signIn();
    if (googleUser == null) throw Exception('Google sign-in cancelled');
    final googleAuth = await googleUser.authentication;
    final credential = GoogleAuthProvider.credential(
      accessToken: googleAuth.accessToken,
      idToken: googleAuth.idToken,
    );
    return _auth.currentUser!.linkWithCredential(credential);
  }

  /// Upgrade anonymous account by linking a Facebook credential.
  static Future<UserCredential> linkWithFacebook() async {
    final result = await FacebookAuth.instance.login();
    if (result.status != LoginStatus.success) {
      throw Exception('Facebook sign-in failed: ${result.message}');
    }
    final credential =
        FacebookAuthProvider.credential(result.accessToken!.tokenString);
    return _auth.currentUser!.linkWithCredential(credential);
  }

  /// Sign out (on next launch the user will sign in anonymously again).
  static Future<void> signOut() => _auth.signOut();

  static User? get currentUser => _auth.currentUser;

  static Stream<User?> get authStateChanges => _auth.authStateChanges();
}
