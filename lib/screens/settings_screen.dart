import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../auth_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const String _backendBase =
      'https://tour-guide-backend-production.up.railway.app';
  static const Color _teal = Color(0xFF0d9488);

  List<Map<String, dynamic>> _guides = [];
  String _preferredGuide = '';
  String _distanceUnit = 'miles';
  String _triviaRevealMode = 'auto'; // 'auto', 'manual', 'instant'
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _preferredGuide = prefs.getString('preferred_guide') ?? '';
    _distanceUnit = prefs.getString('distance_unit') ?? 'miles';
    _triviaRevealMode = prefs.getString('trivia_reveal_mode') ?? 'auto';

    try {
      final response = await http
          .get(Uri.parse('$_backendBase/tour-guides'))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final guides = (data['tour_guides'] as List)
            .map((g) => g as Map<String, dynamic>)
            .toList();
        if (mounted) setState(() => _guides = guides);

        // Auto-select first guide if no preference saved
        if (_preferredGuide.isEmpty && guides.isNotEmpty) {
          final firstName = guides.first['name'] as String? ?? '';
          if (firstName.isNotEmpty) {
            _setPreferredGuide(firstName);
          }
        }
      }
    } catch (e) {
      debugPrint('Settings fetchGuides error: $e');
    }

    if (mounted) setState(() => _loading = false);
  }

  Future<void> _setPreferredGuide(String? name) async {
    setState(() => _preferredGuide = name ?? '');
    final prefs = await SharedPreferences.getInstance();
    if (name == null || name.isEmpty) {
      await prefs.remove('preferred_guide');
    } else {
      await prefs.setString('preferred_guide', name);
    }
  }

  Future<void> _setDistanceUnit(String? unit) async {
    if (unit == null) return;
    setState(() => _distanceUnit = unit);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('distance_unit', unit);
  }

  Future<void> _setTriviaRevealMode(String? mode) async {
    if (mode == null) return;
    setState(() => _triviaRevealMode = mode);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('trivia_reveal_mode', mode);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        backgroundColor: _teal,
        foregroundColor: Colors.white,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                // ── Preferred Tour Guide ──
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 20, 16, 8),
                  child: Text(
                    'Preferred Tour Guide',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: Colors.grey,
                    ),
                  ),
                ),
                RadioGroup<String>(
                  groupValue: _preferredGuide,
                  onChanged: _setPreferredGuide,
                  child: Column(
                    children: [
                      RadioListTile<String>(
                        title: const Text('No preference'),
                        subtitle: const Text('Hear from different guides'),
                        value: '',
                        toggleable: true,
                        activeColor: _teal,
                      ),
                      ..._guides.map((g) => RadioListTile<String>(
                            title: Text(g['name'] as String),
                            subtitle: Text(
                              g['style'] as String? ?? '',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            value: g['name'] as String,
                            activeColor: _teal,
                          )),
                    ],
                  ),
                ),
                const Divider(height: 32),

                // ── Distance Units ──
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    'Distance Units',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: Colors.grey,
                    ),
                  ),
                ),
                RadioGroup<String>(
                  groupValue: _distanceUnit,
                  onChanged: _setDistanceUnit,
                  child: const Column(
                    children: [
                      RadioListTile<String>(
                        title: Text('Miles'),
                        value: 'miles',
                        activeColor: _teal,
                      ),
                      RadioListTile<String>(
                        title: Text('Kilometers'),
                        value: 'km',
                        activeColor: _teal,
                      ),
                    ],
                  ),
                ),
                const Divider(height: 32),

                // ── Trivia Answer Reveal ──
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    'Trivia Answer Reveal',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: Colors.grey,
                    ),
                  ),
                ),
                RadioGroup<String>(
                  groupValue: _triviaRevealMode,
                  onChanged: _setTriviaRevealMode,
                  child: const Column(
                    children: [
                      RadioListTile<String>(
                        title: Text('Auto (countdown)'),
                        subtitle: Text('Answer reveals after a countdown'),
                        value: 'auto',
                        activeColor: _teal,
                      ),
                      RadioListTile<String>(
                        title: Text('Manual (tap to reveal)'),
                        subtitle: Text('Tap a button to see the answer'),
                        value: 'manual',
                        activeColor: _teal,
                      ),
                      RadioListTile<String>(
                        title: Text('Instant (no pause)'),
                        subtitle: Text('Answer plays immediately'),
                        value: 'instant',
                        activeColor: _teal,
                      ),
                    ],
                  ),
                ),
                const Divider(height: 32),

                // ── Log Out ──
                if (AuthService.currentUser != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        await AuthService.signOut();
                        if (context.mounted) {
                          Navigator.of(context).pushNamedAndRemoveUntil(
                            '/login',
                            (_) => false,
                          );
                        }
                      },
                      icon: const Icon(Icons.logout, size: 18),
                      label: const Text('Log Out'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red,
                        side: const BorderSide(color: Colors.red),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
