import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

// ─── TourGuide model ──────────────────────────────────────────────────────────

class TourGuide {
  final String name;
  final String style;
  final String personality;

  const TourGuide({required this.name, required this.style, required this.personality});

  factory TourGuide.fromJson(Map<String, dynamic> json) => TourGuide(
    name:        json['name']        as String? ?? '',
    style:       json['style']       as String? ?? '',
    personality: json['personality'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => {'name': name, 'style': style, 'personality': personality};
}

// ─── Fallback catalogue (used when server list is not yet loaded) ─────────────

const List<String> kAllNarrators = ['Mike', 'John', 'Kaylin', 'Tomas', 'Christina'];

const List<TourGuide> kFallbackGuides = [
  TourGuide(name: 'Mike',      style: 'Warm and conversational', personality: ''),
  TourGuide(name: 'John',      style: 'Deep and authoritative',  personality: ''),
  TourGuide(name: 'Kaylin',    style: 'Clear and energetic',     personality: ''),
  TourGuide(name: 'Tomas',     style: 'Calm storyteller',        personality: ''),
  TourGuide(name: 'Christina', style: 'Bright and welcoming',    personality: ''),
];

// ─── AppSettings model ────────────────────────────────────────────────────────

class AppSettings {
  bool debugMode;
  bool forceNewSession; // transient — not persisted, consumed on return to HomeScreen
  List<String> preferredNarrators;

  AppSettings({
    this.debugMode = false,
    this.forceNewSession = false,
    List<String>? preferredNarrators,
  }) : preferredNarrators = (preferredNarrators != null && preferredNarrators.isNotEmpty)
           ? preferredNarrators
           : List<String>.from(kAllNarrators);

  static Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList('preferredNarrators');
    return AppSettings(
      debugMode: prefs.getBool('debugMode') ?? false,
      preferredNarrators: (stored != null && stored.isNotEmpty) ? stored : null,
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('debugMode', debugMode);
    await prefs.setStringList('preferredNarrators', preferredNarrators);
    // forceNewSession is intentionally not persisted
  }
}

// ─── SettingsContent ──────────────────────────────────────────────────────────
// Embedded settings widget (no Scaffold/AppBar — designed to live inside a PageView).

class SettingsContent extends StatefulWidget {
  final AppSettings settings;
  final void Function(AppSettings) onChanged;
  final List<String> cachedMusicTracks;
  final Future<void> Function() onClearTracks;
  final List<TourGuide> tourGuides;
  final Future<void> Function() onRefreshTourGuides;

  const SettingsContent({
    super.key,
    required this.settings,
    required this.onChanged,
    required this.cachedMusicTracks,
    required this.onClearTracks,
    required this.tourGuides,
    required this.onRefreshTourGuides,
  });

  @override
  State<SettingsContent> createState() => _SettingsContentState();
}

class _SettingsContentState extends State<SettingsContent> {
  static const String _backendBase = 'https://tour-guide-backend-production.up.railway.app';
  static const Color _green = Color(0xFF3DAA74);
  static const Color _cream = Color(0xFFF5EDD8);

  late AppSettings _settings;
  bool _clearingNarrations = false;
  bool _clearingContent = false;
  bool _clearingPings = false;
  bool _clearingTracks = false;
  String? _savingGuide; // name of guide currently being saved

  @override
  void initState() {
    super.initState();
    _settings = AppSettings(
      debugMode: widget.settings.debugMode,
      preferredNarrators: List<String>.from(widget.settings.preferredNarrators),
    );
  }

  void _notify() => widget.onChanged(_settings);

  Future<void> _clearPings() async {
    setState(() => _clearingPings = true);
    try {
      final response = await http.post(Uri.parse('$_backendBase/debug/clear-pings'));
      final data = jsonDecode(response.body);
      if (!mounted) return;
      final count = data['deleted_count'] ?? 0;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Cleared $count ping(s)'),
        backgroundColor: _green,
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Error: $e'),
        backgroundColor: Colors.red.shade400,
      ));
    } finally {
      if (mounted) setState(() => _clearingPings = false);
    }
  }

  Future<void> _clearContent() async {
    setState(() => _clearingContent = true);
    try {
      final response = await http.post(Uri.parse('$_backendBase/debug/clear-content'));
      final data = jsonDecode(response.body);
      if (!mounted) return;
      final count = data['deleted_count'] ?? 0;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Cleared $count cached narration(s)'),
        backgroundColor: _green,
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Error: $e'),
        backgroundColor: Colors.red.shade400,
      ));
    } finally {
      if (mounted) setState(() => _clearingContent = false);
    }
  }

  Future<void> _clearNarrations() async {
    setState(() => _clearingNarrations = true);
    try {
      final response = await http.post(Uri.parse('$_backendBase/debug/clear-narrations'));
      final data = jsonDecode(response.body);
      if (!mounted) return;
      final count = data['deleted_count'] ?? 0;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Cleared $count narration(s)'),
        backgroundColor: _green,
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Error: $e'),
        backgroundColor: Colors.red.shade400,
      ));
    } finally {
      if (mounted) setState(() => _clearingNarrations = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: _cream,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 80),
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 20, 0, 0),
            child: Row(
              children: const [
                Icon(Icons.directions_bus_rounded, color: _green, size: 22),
                SizedBox(width: 8),
                Text(
                  'Tour Guide',
                  style: TextStyle(color: _green, fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 14, bottom: 2),
            child: Text(
              'SETTINGS',
              style: TextStyle(
                color: Colors.black54,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.5,
              ),
            ),
          ),
          const Text(
            'Preferences & Tools',
            style: TextStyle(color: Colors.black, fontSize: 28, fontWeight: FontWeight.bold, height: 1.1),
          ),
          const SizedBox(height: 20),

          _buildSectionHeader('Developer'),
          _buildToggleSetting(
            label: 'Debug Mode',
            description: 'Show debug information at the bottom of the screen',
            value: _settings.debugMode,
            onChanged: (val) {
              setState(() => _settings.debugMode = val);
              _notify();
            },
          ),
          if (_settings.debugMode) ...[
            _buildActionSetting(
              label: 'Clear Content Cache',
              description: 'Delete all generated narration content so everything is regenerated fresh',
              icon: _clearingContent
                  ? const SizedBox(width: 20, height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black38))
                  : Icon(Icons.auto_delete_rounded, color: Colors.red.shade400),
              onTap: _clearingContent ? null : _clearContent,
            ),
            _buildActionSetting(
              label: 'Clear Narrations',
              description: 'Delete all narration queue records from the database (pending and played)',
              icon: _clearingNarrations
                  ? const SizedBox(width: 20, height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black38))
                  : Icon(Icons.delete_sweep_rounded, color: Colors.red.shade400),
              onTap: _clearingNarrations ? null : _clearNarrations,
            ),
            _buildActionSetting(
              label: 'Clear Ping History',
              description: 'Delete all location ping records from the database',
              icon: _clearingPings
                  ? const SizedBox(width: 20, height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black38))
                  : Icon(Icons.location_off_rounded, color: Colors.red.shade400),
              onTap: _clearingPings ? null : _clearPings,
            ),
            _buildActionSetting(
              label: 'Clear Cached Tracks',
              description: 'Delete locally cached music files so they re-download on next start',
              icon: _clearingTracks
                  ? const SizedBox(width: 20, height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black38))
                  : Icon(Icons.music_off_rounded, color: Colors.red.shade400),
              onTap: _clearingTracks ? null : () async {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Clear Cached Tracks?'),
                    content: const Text(
                      'This will delete all locally cached music files. '
                      'They will re-download automatically the next time you start a tour.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: Text('Clear', style: TextStyle(color: Colors.red.shade400)),
                      ),
                    ],
                  ),
                );
                if (confirmed != true) return;
                setState(() => _clearingTracks = true);
                await widget.onClearTracks();
                if (mounted) setState(() => _clearingTracks = false);
              },
            ),
          ],

          _buildSectionHeader('Session'),
          _buildActionSetting(
            label: 'Start New Session',
            description: 'End the current tour session and begin a fresh one on your next location update',
            icon: const Icon(Icons.refresh_rounded, color: _green),
            onTap: () {
              setState(() => _settings.forceNewSession = true);
              _notify();
            },
          ),

          _buildSectionHeader('Tour Guides'),
          _buildNarratorSelector(),

          _buildSectionHeader('Music'),
          _buildMusicStatus(),
        ],
      ),
    );
  }

  Widget _buildNarratorSelector() {
    final preferred = _settings.preferredNarrators;
    final guides = widget.tourGuides.isNotEmpty ? widget.tourGuides : kFallbackGuides;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 8, offset: const Offset(0, 2)),
        ],
      ),
      child: Column(
        children: guides.asMap().entries.map((entry) {
          final idx    = entry.key;
          final guide  = entry.value;
          final name   = guide.name;
          final style  = guide.style;
          final selected = preferred.contains(name);
          final isLast   = idx == guides.length - 1;
          final isSaving = _savingGuide == name;
          return Column(
            children: [
              SwitchListTile(
                title: Text(name,
                    style: const TextStyle(color: Colors.black87, fontSize: 16)),
                subtitle: Text(style,
                    style: const TextStyle(color: Colors.black45, fontSize: 12)),
                value: selected,
                activeThumbColor: _green,
                inactiveTrackColor: Colors.black12,
                secondary: _settings.debugMode
                    ? isSaving
                        ? const SizedBox(width: 20, height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black38))
                        : IconButton(
                            icon: Icon(Icons.edit_rounded, size: 18, color: Colors.black38),
                            tooltip: 'Edit personality',
                            onPressed: () => _editTourGuide(guide),
                          )
                    : null,
                onChanged: (val) {
                  if (!val && preferred.length == 1) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('At least one tour guide must be selected'),
                      backgroundColor: Colors.black87,
                    ));
                    return;
                  }
                  setState(() {
                    if (val) {
                      _settings.preferredNarrators = [...preferred, name];
                    } else {
                      _settings.preferredNarrators = preferred.where((n) => n != name).toList();
                    }
                  });
                  _notify();
                },
              ),
              if (!isLast)
                const Divider(height: 1, indent: 16, endIndent: 16, color: Colors.black12),
            ],
          );
        }).toList(),
      ),
    );
  }

  Future<void> _editTourGuide(TourGuide guide) async {
    final personalityCtrl = TextEditingController(text: guide.personality);
    final styleCtrl       = TextEditingController(text: guide.style);
    final save = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Edit ${guide.name}'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Style (shown in app)',
                  style: TextStyle(fontSize: 12, color: Colors.black54)),
              const SizedBox(height: 4),
              TextField(
                controller: styleCtrl,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(), isDense: true,
                  contentPadding: EdgeInsets.all(10),
                ),
              ),
              const SizedBox(height: 14),
              const Text('Personality (used in LLM narration prompts)',
                  style: TextStyle(fontSize: 12, color: Colors.black54)),
              const SizedBox(height: 4),
              TextField(
                controller: personalityCtrl,
                maxLines: 5,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.all(10),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Save', style: TextStyle(color: _green, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (save != true || !mounted) return;

    setState(() => _savingGuide = guide.name);
    try {
      final response = await http.patch(
        Uri.parse('$_backendBase/tour-guides/${guide.name}'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'personality': personalityCtrl.text.trim(),
          'style': styleCtrl.text.trim(),
        }),
      );
      if (!mounted) return;
      if (response.statusCode == 200) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${guide.name} updated'),
          backgroundColor: _green,
        ));
        await widget.onRefreshTourGuides();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Error: ${response.statusCode}'),
          backgroundColor: Colors.red.shade400,
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Error: $e'),
          backgroundColor: Colors.red.shade400,
        ));
      }
    } finally {
      if (mounted) setState(() => _savingGuide = null);
    }
  }

  Widget _buildMusicStatus() {
    final tracks = widget.cachedMusicTracks;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 8, offset: const Offset(0, 2)),
        ],
      ),
      child: tracks.isEmpty
          ? ListTile(
              leading: Icon(Icons.music_off_rounded, color: Colors.black26),
              title: const Text('No tracks cached yet',
                  style: TextStyle(color: Colors.black54, fontSize: 14)),
              subtitle: const Text('Start the app — tracks will download automatically',
                  style: TextStyle(color: Colors.black38, fontSize: 12)),
            )
          : Column(
              children: tracks.asMap().entries.map((entry) {
                final filename = entry.value.split('/').last.split('\\').last;
                final isLast = entry.key == tracks.length - 1;
                return Column(
                  children: [
                    ListTile(
                      leading: Container(
                        width: 36, height: 36,
                        decoration: BoxDecoration(
                          color: _green.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(Icons.music_note_rounded, color: _green, size: 18),
                      ),
                      title: Text(filename,
                          style: const TextStyle(color: Colors.black87, fontSize: 14)),
                      trailing: Icon(Icons.check_circle_rounded,
                          color: _green.withValues(alpha: 0.7), size: 18),
                    ),
                    if (!isLast)
                      const Divider(height: 1, indent: 16, endIndent: 16, color: Colors.black12),
                  ],
                );
              }).toList(),
            ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 8),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(
          color: Colors.black45,
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
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 8, offset: const Offset(0, 2)),
        ],
      ),
      child: SwitchListTile(
        title: Text(label, style: const TextStyle(color: Colors.black87, fontSize: 16)),
        subtitle: Text(description,
            style: const TextStyle(color: Colors.black45, fontSize: 12)),
        value: value,
        onChanged: onChanged,
        activeThumbColor: _green,
        inactiveTrackColor: Colors.black12,
      ),
    );
  }

  Widget _buildActionSetting({
    required String label,
    required String description,
    required Widget icon,
    required VoidCallback? onTap,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 8, offset: const Offset(0, 2)),
        ],
      ),
      child: ListTile(
        title: Text(label, style: const TextStyle(color: Colors.black87, fontSize: 16)),
        subtitle: Text(description,
            style: const TextStyle(color: Colors.black45, fontSize: 12)),
        trailing: icon,
        onTap: onTap,
      ),
    );
  }
}
