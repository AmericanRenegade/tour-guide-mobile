import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../auth_service.dart';
import 'explore_settings_screen.dart';
import 'trivia_settings_screen.dart';
import 'tour_guides_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const String _backendBase =
      'https://tour-guide-backend-production.up.railway.app';
  static const Color _teal = Color(0xFF0d9488);

  String _distanceUnit = 'miles';
  int _minBreatheS = 0; // 0 = use server default
  bool _clearingHistory = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _distanceUnit = prefs.getString('distance_unit') ?? 'miles';
    _minBreatheS = prefs.getInt('min_breathe_s') ?? 0;
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _setDistanceUnit(String? unit) async {
    if (unit == null) return;
    setState(() => _distanceUnit = unit);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('distance_unit', unit);
  }

  Future<void> _setMinBreatheS(int seconds) async {
    setState(() => _minBreatheS = seconds);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('min_breathe_s', seconds);
  }

  Future<void> _clearListenedHistory() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear Listened History'),
        content: const Text(
          'This will reset your play history so you can hear stories and trivia again. Continue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    setState(() => _clearingHistory = true);
    try {
      final token = await AuthService.getIdToken();
      if (token == null) return;
      final response = await http.delete(
        Uri.parse('$_backendBase/user/play-history'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 10));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(response.statusCode == 200
              ? 'Listened history cleared'
              : 'Failed to clear history'),
        ));
      }
    } catch (e) {
      debugPrint('Settings clearHistory error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to clear history')),
        );
      }
    } finally {
      if (mounted) setState(() => _clearingHistory = false);
    }
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
                // ── Tour Guides ──
                ListTile(
                  leading: const Icon(Icons.people, color: _teal),
                  title: const Text('Tour Guides'),
                  subtitle: const Text('Lead narrator & guide preferences'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const TourGuidesScreen(),
                    ),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.explore, color: _teal),
                  title: const Text('Explore'),
                  subtitle: const Text('Re-hear cooldown & explore preferences'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const ExploreSettingsScreen(),
                    ),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.quiz_outlined, color: _teal),
                  title: const Text('Trivia'),
                  subtitle: const Text('Answer reveal & trivia preferences'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const TriviaSettingsScreen(),
                    ),
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

                // ── Min Time Between Stories ──
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    'Min Time Between Stories',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: Colors.grey,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                  child: Text(
                    _minBreatheS == 0
                        ? 'Using server default'
                        : '${_minBreatheS ~/ 60} min ${_minBreatheS % 60} sec',
                    style: TextStyle(
                      fontSize: 16,
                      color: _minBreatheS == 0 ? Colors.grey : _teal,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                  child: Slider(
                    value: _minBreatheS.toDouble(),
                    min: 0,
                    max: 600,
                    divisions: 20,
                    activeColor: _teal,
                    label: _minBreatheS == 0
                        ? 'Default'
                        : '${_minBreatheS ~/ 60}m ${_minBreatheS % 60}s',
                    onChanged: (v) => _setMinBreatheS(v.toInt()),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    'Minimum wait between story narrations. '
                    'Set to 0 to use the server default.',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
                const Divider(height: 32),

                // ── Clear Listened History ──
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Listened History',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: Colors.grey,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Clear your play history to hear stories and trivia you\'ve already listened to.',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: _clearingHistory ? null : _clearListenedHistory,
                        icon: _clearingHistory
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.delete_outline, size: 18),
                        label: Text(_clearingHistory ? 'Clearing...' : 'Clear Listened History'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.orange,
                          side: const BorderSide(color: Colors.orange),
                          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                        ),
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
