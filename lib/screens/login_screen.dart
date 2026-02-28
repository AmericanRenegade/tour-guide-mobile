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

  // Circle layout — large circles, close together
  static const double _circleSize = 150.0;
  static const double _vSpacing = 170.0;

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
                  ? w * 0.25 - _circleSize / 2
                  : w * 0.75 - _circleSize / 2;

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
            color: Colors.black.withValues(alpha: 0.10),
            blurRadius: 10,
            offset: const Offset(0, 3),
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
                fontSize: 48,
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

          // Foreground: compact, semi-transparent login panel
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 20, vertical: 24),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.75),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.08),
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
                            fontSize: 26, fontWeight: FontWeight.bold),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _isSignUp
                            ? 'Create an account'
                            : 'Sign in to continue',
                        style: const TextStyle(
                            color: Colors.grey, fontSize: 13),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 20),

                      // Google
                      OutlinedButton.icon(
                        onPressed: _loading ? null : _handleGoogle,
                        icon: const Icon(Icons.login, size: 18),
                        label: const Text('Continue with Google',
                            style: TextStyle(fontSize: 13)),
                        style: OutlinedButton.styleFrom(
                          padding:
                              const EdgeInsets.symmetric(vertical: 10),
                          side:
                              const BorderSide(color: Colors.black26),
                        ),
                      ),
                      const SizedBox(height: 16),

                      const Row(children: [
                        Expanded(child: Divider()),
                        Padding(
                          padding:
                              EdgeInsets.symmetric(horizontal: 10),
                          child: Text('or',
                              style: TextStyle(
                                  color: Colors.grey, fontSize: 12)),
                        ),
                        Expanded(child: Divider()),
                      ]),
                      const SizedBox(height: 16),

                      // Email
                      SizedBox(
                        height: 44,
                        child: TextField(
                          controller: _emailController,
                          keyboardType: TextInputType.emailAddress,
                          style: const TextStyle(fontSize: 14),
                          decoration: const InputDecoration(
                            labelText: 'Email',
                            labelStyle: TextStyle(fontSize: 13),
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(
                                horizontal: 12, vertical: 10),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        height: 44,
                        child: TextField(
                          controller: _passwordController,
                          obscureText: true,
                          style: const TextStyle(fontSize: 14),
                          decoration: const InputDecoration(
                            labelText: 'Password',
                            labelStyle: TextStyle(fontSize: 13),
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(
                                horizontal: 12, vertical: 10),
                          ),
                          onSubmitted: (_) => _handleEmailAuth(),
                        ),
                      ),
                      const SizedBox(height: 12),

                      if (_errorMessage != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(
                            _errorMessage!,
                            style: const TextStyle(
                                color: Colors.red, fontSize: 12),
                            textAlign: TextAlign.center,
                          ),
                        ),

                      SizedBox(
                        height: 40,
                        child: ElevatedButton(
                          onPressed:
                              _loading ? null : _handleEmailAuth,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.black,
                            foregroundColor: Colors.white,
                          ),
                          child: _loading
                              ? const SizedBox(
                                  height: 16,
                                  width: 16,
                                  child: CircularProgressIndicator(
                                    color: Colors.white,
                                    strokeWidth: 2,
                                  ),
                                )
                              : Text(
                                  _isSignUp
                                      ? 'Create Account'
                                      : 'Sign In',
                                  style: const TextStyle(fontSize: 13)),
                        ),
                      ),
                      const SizedBox(height: 4),

                      TextButton(
                        onPressed: _loading
                            ? null
                            : () => setState(() {
                                  _isSignUp = !_isSignUp;
                                  _errorMessage = null;
                                }),
                        style: TextButton.styleFrom(
                          minimumSize: Size.zero,
                          padding: const EdgeInsets.symmetric(
                              vertical: 4),
                          tapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: Text(
                          _isSignUp
                              ? 'Already have an account? Sign in'
                              : "Don't have an account? Sign up",
                          style: const TextStyle(
                              color: Colors.black54, fontSize: 12),
                        ),
                      ),
                      const SizedBox(height: 8),

                      TextButton(
                        onPressed: _loading ? null : _skip,
                        style: TextButton.styleFrom(
                          minimumSize: Size.zero,
                          padding: const EdgeInsets.symmetric(
                              vertical: 4),
                          tapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: const Text(
                          'Continue without account',
                          style: TextStyle(
                              color: Colors.grey, fontSize: 12),
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
