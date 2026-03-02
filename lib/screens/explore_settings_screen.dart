import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ExploreSettingsScreen extends StatefulWidget {
  const ExploreSettingsScreen({super.key});

  @override
  State<ExploreSettingsScreen> createState() => _ExploreSettingsScreenState();
}

class _ExploreSettingsScreenState extends State<ExploreSettingsScreen> {
  static const Color _teal = Color(0xFF0d9488);

  // Cooldown options: (days, label)
  static const List<(int, String)> _cooldownOptions = [
    (0,   "Don't Remember What I've Heard Across Sessions"),
    (7,   '7 Days'),
    (15,  '15 Days (recommended)'),
    (30,  '30 Days'),
    (60,  '60 Days'),
    (90,  '90 Days'),
    (180, '6 Months'),
    (365, '1 Year'),
  ];

  int _cooldownDays = 15;
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
      _loading = false;
    });
  }

  Future<void> _setCooldown(int days) async {
    setState(() => _cooldownDays = days);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('explore_cooldown_days', days);
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
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 20, 16, 8),
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
                    'How long before you hear the same story or trivia again. '
                    'Set to 0 to get fresh content every time you start exploring.',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
                RadioGroup<int>(
                  groupValue: _cooldownDays,
                  onChanged: (v) => _setCooldown(v!),
                  child: Column(
                    children: _cooldownOptions.map((option) {
                      final (days, label) = option;
                      return RadioListTile<int>(
                        title: Text(label),
                        value: days,
                        activeColor: _teal,
                      );
                    }).toList(),
                  ),
                ),
                const SizedBox(height: 32),
              ],
            ),
    );
  }
}
