import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─── AppSettings model ────────────────────────────────────────────────────────

class AppSettings {
  bool debugMode;
  bool forceNewSession; // transient — not persisted, consumed on return to HomeScreen

  AppSettings({
    this.debugMode = false,
    this.forceNewSession = false,
  });

  static Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return AppSettings(
      debugMode: prefs.getBool('debugMode') ?? false,
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('debugMode', debugMode);
    // forceNewSession is intentionally not persisted
  }
}

// ─── SettingsScreen ───────────────────────────────────────────────────────────

class SettingsScreen extends StatefulWidget {
  final AppSettings settings;

  const SettingsScreen({super.key, required this.settings});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late AppSettings _settings;

  @override
  void initState() {
    super.initState();
    _settings = AppSettings(
      debugMode: widget.settings.debugMode,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text(
          'Settings',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        iconTheme: const IconThemeData(color: Colors.white),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context, _settings),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          _buildSectionHeader('Developer'),
          _buildToggleSetting(
            label: 'Debug Mode',
            description: 'Show debug information at the bottom of the screen',
            value: _settings.debugMode,
            onChanged: (val) => setState(() => _settings.debugMode = val),
          ),

          _buildSectionHeader('Session'),
          _buildActionSetting(
            label: 'Start New Session',
            description: 'End the current tour session and begin a fresh one on your next location update',
            onTap: () {
              setState(() => _settings.forceNewSession = true);
              Navigator.pop(context, _settings);
            },
          ),

          // ── Add new settings sections here ──
          // _buildSectionHeader('Narration'),
          // _buildToggleSetting(...),
          // _buildSectionHeader('Display'),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 24, bottom: 8),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          color: Colors.white.withValues(alpha:0.4),
          fontSize: 11,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.5,
        ),
      ),
    );
  }

  Widget _buildToggleSetting({
    required String label,
    required String description,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha:0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha:0.1)),
      ),
      child: SwitchListTile(
        title: Text(label, style: const TextStyle(color: Colors.white, fontSize: 16)),
        subtitle: Text(
          description,
          style: TextStyle(color: Colors.white.withValues(alpha:0.5), fontSize: 12),
        ),
        value: value,
        onChanged: onChanged,
        activeThumbColor: Colors.green,
        inactiveTrackColor: Colors.white.withValues(alpha:0.15),
      ),
    );
  }

  Widget _buildActionSetting({
    required String label,
    required String description,
    required VoidCallback onTap,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha:0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha:0.1)),
      ),
      child: ListTile(
        title: Text(label, style: const TextStyle(color: Colors.white, fontSize: 16)),
        subtitle: Text(
          description,
          style: TextStyle(color: Colors.white.withValues(alpha:0.5), fontSize: 12),
        ),
        trailing: Icon(Icons.refresh, color: Colors.white.withValues(alpha:0.6)),
        onTap: onTap,
      ),
    );
  }
}
