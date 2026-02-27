import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

/// Handles Firebase authentication for the Tour Guide app.
/// Supports Google and email/password sign-in. Login is optional — users
/// may skip to use the app without an account.
class AuthService {
  static final FirebaseAuth _auth = FirebaseAuth.instance;
  static final GoogleSignIn _googleSignIn = GoogleSignIn();

  /// Sign in with Google.
  static Future<UserCredential> signInWithGoogle() async {
    final googleUser = await _googleSignIn.signIn();
    if (googleUser == null) throw Exception('Google sign-in cancelled');
    final googleAuth = await googleUser.authentication;
    final credential = GoogleAuthProvider.credential(
      accessToken: googleAuth.accessToken,
      idToken: googleAuth.idToken,
    );
    return _auth.signInWithCredential(credential);
  }

  /// Sign in with email and password.
  static Future<UserCredential> signInWithEmail(String email, String password) {
    return _auth.signInWithEmailAndPassword(email: email, password: password);
  }

  /// Create a new account with email and password.
  static Future<UserCredential> signUp(String email, String password) {
    return _auth.createUserWithEmailAndPassword(email: email, password: password);
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

  /// Sign out.
  static Future<void> signOut() => _auth.signOut();

  static User? get currentUser => _auth.currentUser;

  static Stream<User?> get authStateChanges => _auth.authStateChanges();
}
