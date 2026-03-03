import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../auth_service.dart';

class ExploreSettingsScreen extends StatefulWidget {
  const ExploreSettingsScreen({super.key});

  @override
  State<ExploreSettingsScreen> createState() => _ExploreSettingsScreenState();
}

class _ExploreSettingsScreenState extends State<ExploreSettingsScreen> {
  static const String _backendBase =
      'https://tour-guide-backend-production.up.railway.app';
  static const Color _teal = Color(0xFF0d9488);

  static const List<(int, String)> _cooldownOptions = [
    (0,   '0 Days — Don\'t Remember'),
    (7,   '7 Days'),
    (15,  '15 Days (recommended)'),
    (30,  '30 Days'),
    (60,  '60 Days'),
    (90,  '90 Days'),
    (180, '6 Months'),
    (365, '1 Year'),
  ];

  int _cooldownDays = 15;
  int _minBreatheS = 0;
  bool _clearingHistory = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _cooldownDays = prefs.getInt('explore_cooldown_days') ?? 15;
      _minBreatheS = prefs.getInt('min_breathe_s') ?? 0;
      _loading = false;
    });
  }

  Future<void> _setCooldown(int? days) async {
    if (days == null) return;
    setState(() => _cooldownDays = days);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('explore_cooldown_days', days);
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
      debugPrint('ExploreSettings clearHistory error: $e');
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
        title: const Text('Explore Settings'),
        backgroundColor: _teal,
        foregroundColor: Colors.white,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                // ── Re-hear Content After ──
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 20, 16, 4),
                  child: Text(
                    'Re-hear Content After',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: Colors.grey,
                    ),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Text(
                    'Set to 0 to always hear all available stories and trivia, '
                    'even if you\'ve heard them recently.',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<int>(
                        value: _cooldownDays,
                        isExpanded: true,
                        items: _cooldownOptions
                            .map((o) => DropdownMenuItem(
                                  value: o.$1,
                                  child: Text(o.$2),
                                ))
                            .toList(),
                        onChanged: _setCooldown,
                      ),
                    ),
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
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Clear your play history to hear stories and trivia '
                        'you\'ve already listened to.',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed:
                            _clearingHistory ? null : _clearListenedHistory,
                        icon: _clearingHistory
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.delete_outline, size: 18),
                        label: Text(_clearingHistory
                            ? 'Clearing...'
                            : 'Clear Listened History'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.orange,
                          side: const BorderSide(color: Colors.orange),
                          padding: const EdgeInsets.symmetric(
                              vertical: 12, horizontal: 16),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}
