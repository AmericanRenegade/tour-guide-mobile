import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../auth_service.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with SingleTickerProviderStateMixin {
  static const String _backendBase =
      'https://tour-guide-backend-production.up.railway.app';

  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isSignUp = false;
  bool _loading = false;
  String? _errorMessage;

  late AnimationController _scrollAnim;
  List<Map<String, dynamic>> _guides = [];

  // Circle layout constants
  static const double _circleSize = 80.0;
  static const double _vSpacing = 100.0;

  @override
  void initState() {
    super.initState();
    if (AuthService.currentUser != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pushReplacementNamed(context, '/map');
      });
    }
    _scrollAnim = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 30),
    )..repeat();
    _fetchGuides();
  }

  @override
  void dispose() {
    _scrollAnim.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _fetchGuides() async {
    try {
      final resp = await http
          .get(Uri.parse('$_backendBase/tour-guides'))
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final list = (data['tour_guides'] as List)
            .map((g) => g as Map<String, dynamic>)
            .toList();
        if (mounted) setState(() => _guides = list);
      }
    } catch (_) {}
  }

  // ─── Auth handlers ──────────────────────────────────────────────────────────

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

  // ─── Scrolling guide circles background ─────────────────────────────────────

  Widget _buildScrollingGuides() {
    if (_guides.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(builder: (context, constraints) {
      final h = constraints.maxHeight;
      final w = constraints.maxWidth;
      final n = _guides.length;
      final patternH = n * _vSpacing;
      // Enough repeats to fill the screen plus buffer for seamless loop
      final repeats = (h / patternH).ceil() + 2;

      return AnimatedBuilder(
        animation: _scrollAnim,
        builder: (context, _) {
          final offset = _scrollAnim.value * patternH;
          final circles = <Widget>[];

          for (int r = 0; r < repeats; r++) {
            for (int i = 0; i < n; i++) {
              final guide = _guides[i];
              final y = r * patternH + i * _vSpacing - offset;
              // Stagger: even indices left, odd indices right
              final x = i.isEven
                  ? w * 0.28 - _circleSize / 2
                  : w * 0.72 - _circleSize / 2;

              circles.add(Positioned(
                left: x,
                top: y,
                child: _guideCircle(guide),
              ));
            }
          }

          return Stack(clipBehavior: Clip.hardEdge, children: circles);
        },
      );
    });
  }

  Widget _guideCircle(Map<String, dynamic> guide) {
    final id = guide['id'] as String;
    final name = guide['name'] as String? ?? '';
    return Container(
      width: _circleSize,
      height: _circleSize,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFFe0f2f1),
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ClipOval(
        child: Image.network(
          '$_backendBase/tour-guides/$id/photo',
          width: _circleSize,
          height: _circleSize,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => Center(
            child: Text(
              name.isNotEmpty ? name[0].toUpperCase() : '?',
              style: const TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: Color(0xFF0d9488),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ─── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Stack(
        children: [
          // Background: scrolling guide circles
          Positioned.fill(child: _buildScrollingGuides()),

          // Gradient overlay — more transparent at top/bottom so circles
          // peek through, more opaque in the center for form readability
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.white.withValues(alpha: 0.2),
                    Colors.white.withValues(alpha: 0.85),
                    Colors.white.withValues(alpha: 0.85),
                    Colors.white.withValues(alpha: 0.2),
                  ],
                  stops: const [0.0, 0.25, 0.75, 1.0],
                ),
              ),
            ),
          ),

          // Foreground: login form on a white card
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 24, vertical: 32),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.93),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.06),
                        blurRadius: 24,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'Tour Guides',
                        style: TextStyle(
                            fontSize: 28, fontWeight: FontWeight.bold),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _isSignUp
                            ? 'Create an account'
                            : 'Sign in to continue',
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
                          padding:
                              const EdgeInsets.symmetric(vertical: 14),
                          side:
                              const BorderSide(color: Colors.black26),
                        ),
                      ),
                      const SizedBox(height: 24),

                      const Row(children: [
                        Expanded(child: Divider()),
                        Padding(
                          padding:
                              EdgeInsets.symmetric(horizontal: 12),
                          child: Text('or',
                              style: TextStyle(color: Colors.grey)),
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
                            style: const TextStyle(
                                color: Colors.red, fontSize: 13),
                            textAlign: TextAlign.center,
                          ),
                        ),

                      ElevatedButton(
                        onPressed:
                            _loading ? null : _handleEmailAuth,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.black,
                          foregroundColor: Colors.white,
                          padding:
                              const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: _loading
                            ? const SizedBox(
                                height: 18,
                                width: 18,
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2,
                                ),
                              )
                            : Text(_isSignUp
                                ? 'Create Account'
                                : 'Sign In'),
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
                          style:
                              const TextStyle(color: Colors.black54),
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
          ),
        ],
      ),
    );
  }
}
