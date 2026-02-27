import 'package:flutter/material.dart';
import '../auth_service.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _isSignUp = false;
  bool _loading = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    // If already signed in, skip to map.
    if (AuthService.currentUser != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pushReplacementNamed(context, '/map');
      });
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _handleGoogle() async {
    setState(() { _loading = true; _errorMessage = null; });
    try {
      await AuthService.signInWithGoogle();
      if (mounted) Navigator.pushReplacementNamed(context, '/map');
    } catch (e) {
      if (mounted) setState(() { _errorMessage = e.toString(); _loading = false; });
    }
  }

  Future<void> _handleEmailAuth() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    if (email.isEmpty || password.isEmpty) {
      setState(() => _errorMessage = 'Enter email and password.');
      return;
    }
    setState(() { _loading = true; _errorMessage = null; });
    try {
      if (_isSignUp) {
        await AuthService.signUp(email, password);
      } else {
        await AuthService.signInWithEmail(email, password);
      }
      if (mounted) Navigator.pushReplacementNamed(context, '/map');
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString().replaceAll(RegExp(r'\[.*?\]\s*'), '');
          _loading = false;
        });
      }
    }
  }

  void _skip() => Navigator.pushReplacementNamed(context, '/map');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Tour Guides',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  _isSignUp ? 'Create an account' : 'Sign in to continue',
                  style: const TextStyle(color: Colors.grey),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),

                // Google
                OutlinedButton.icon(
                  onPressed: _loading ? null : _handleGoogle,
                  icon: const Icon(Icons.login),
                  label: const Text('Continue with Google'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    side: const BorderSide(color: Colors.black26),
                  ),
                ),
                const SizedBox(height: 24),

                const Row(children: [
                  Expanded(child: Divider()),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12),
                    child: Text('or', style: TextStyle(color: Colors.grey)),
                  ),
                  Expanded(child: Divider()),
                ]),
                const SizedBox(height: 24),

                // Email
                TextField(
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _passwordController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Password',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _handleEmailAuth(),
                ),
                const SizedBox(height: 16),

                if (_errorMessage != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      _errorMessage!,
                      style: const TextStyle(color: Colors.red, fontSize: 13),
                      textAlign: TextAlign.center,
                    ),
                  ),

                ElevatedButton(
                  onPressed: _loading ? null : _handleEmailAuth,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.black,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: _loading
                      ? const SizedBox(
                          height: 18, width: 18,
                          child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2,
                          ),
                        )
                      : Text(_isSignUp ? 'Create Account' : 'Sign In'),
                ),
                const SizedBox(height: 8),

                TextButton(
                  onPressed: _loading
                      ? null
                      : () => setState(() {
                            _isSignUp = !_isSignUp;
                            _errorMessage = null;
                          }),
                  child: Text(
                    _isSignUp
                        ? 'Already have an account? Sign in'
                        : "Don't have an account? Sign up",
                    style: const TextStyle(color: Colors.black54),
                  ),
                ),
                const SizedBox(height: 16),

                TextButton(
                  onPressed: _loading ? null : _skip,
                  child: const Text(
                    'Continue without account',
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
