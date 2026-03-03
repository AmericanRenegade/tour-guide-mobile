import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../auth_service.dart';
import 'explore_settings_screen.dart';
import 'map_settings_screen.dart';
import 'trivia_settings_screen.dart';
import 'tour_guides_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const Color _teal = Color(0xFF0d9488);

  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await SharedPreferences.getInstance();
    if (mounted) setState(() => _loading = false);
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
                ListTile(
                  leading: const Icon(Icons.map_outlined, color: _teal),
                  title: const Text('Map'),
                  subtitle: const Text('Map style & distance units'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const MapSettingsScreen(),
                    ),
                  ),
                ),
                const Divider(height: 32),

                // ── Log Out ──
                if (AuthService.currentUser != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                    child: ElevatedButton.icon(
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
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red.shade700,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
