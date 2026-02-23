import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'auth_service.dart';

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

// ─── PromptVariant model ──────────────────────────────────────────────────────

class PromptVariant {
  final String id;
  final String topic;
  final String label;
  final String template;
  final bool active;

  const PromptVariant({
    required this.id,
    required this.topic,
    required this.label,
    required this.template,
    required this.active,
  });

  factory PromptVariant.fromJson(Map<String, dynamic> json) => PromptVariant(
    id:       json['id']       as String? ?? '',
    topic:    json['topic']    as String? ?? '',
    label:    json['label']    as String? ?? '',
    template: json['template'] as String? ?? '',
    active:   json['active']   as bool?   ?? true,
  );

  Map<String, dynamic> toJson() => {
    'id': id, 'topic': topic, 'label': label, 'template': template, 'active': active,
  };
}

// ─── Fallback catalogue (used when server list is not yet loaded) ─────────────

const List<String> kAllNarrators = ['Mike', 'John', 'Kaylin', 'Tomas', 'Christina', 'Father Christmas'];

const List<TourGuide> kFallbackGuides = [
  TourGuide(name: 'Mike',             style: 'Warm and conversational', personality: ''),
  TourGuide(name: 'John',             style: 'Deep and authoritative',  personality: ''),
  TourGuide(name: 'Kaylin',           style: 'Clear and energetic',     personality: ''),
  TourGuide(name: 'Tomas',            style: 'Calm storyteller',        personality: ''),
  TourGuide(name: 'Christina',        style: 'Bright and welcoming',    personality: ''),
  TourGuide(name: 'Father Christmas', style: 'Jolly and festive',       personality: ''),
];

// ─── AppSettings model ────────────────────────────────────────────────────────

class AppSettings {
  bool debugMode;
  bool musicEnabled;
  bool forceNewSession; // transient — not persisted, consumed on return to HomeScreen

  AppSettings({
    this.debugMode = false,
    this.musicEnabled = true,
    this.forceNewSession = false,
  });

  static Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return AppSettings(
      debugMode: prefs.getBool('debugMode') ?? false,
      musicEnabled: prefs.getBool('musicEnabled') ?? true,
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('debugMode', debugMode);
    await prefs.setBool('musicEnabled', musicEnabled);
    // forceNewSession is intentionally not persisted
  }
}

// ─── GuideAvatar ─────────────────────────────────────────────────────────────
// Shows a portrait image from assets/guides/{name}.png, with gradient+initial fallback.

class GuideAvatar extends StatelessWidget {
  final TourGuide guide;

  const GuideAvatar({required this.guide, super.key});

  static const List<List<Color>> _palettes = [
    [Color(0xFF3DAA74), Color(0xFF1E6B47)],
    [Color(0xFF2196F3), Color(0xFF0D47A1)],
    [Color(0xFFFF6B35), Color(0xFFE64A19)],
    [Color(0xFF9C27B0), Color(0xFF4A148C)],
    [Color(0xFFFFB300), Color(0xFFE65100)],
    [Color(0xFFE91E63), Color(0xFF880E4F)],
  ];

  @override
  Widget build(BuildContext context) {
    final assetPath =
        'assets/guides/${guide.name.toLowerCase().replaceAll(' ', '_')}.png';
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Image.asset(
        assetPath,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _buildFallback(),
      ),
    );
  }

  Widget _buildFallback() {
    final palette = _palettes[guide.name.hashCode.abs() % _palettes.length];
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: palette,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Center(
        child: Text(
          guide.name[0].toUpperCase(),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 48,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}

// ─── TourGuidesScreen ─────────────────────────────────────────────────────────
// Full-screen guide selector with 3-column grid. Designed for a dark background page.

class TourGuidesScreen extends StatelessWidget {
  final List<TourGuide> guides;
  final Future<void> Function() onRefresh;

  const TourGuidesScreen({
    required this.guides,
    required this.onRefresh,
    super.key,
  });

  static const Color _green = Color(0xFF3DAA74);

  @override
  Widget build(BuildContext context) {
    final displayGuides = guides.isNotEmpty ? guides : kFallbackGuides;
    return Container(
      color: Colors.black,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 8, 0),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: const [
                          Icon(Icons.people_rounded, color: _green, size: 22),
                          SizedBox(width: 8),
                          Text(
                            'Tour Guides',
                            style: TextStyle(
                                color: _green,
                                fontSize: 18,
                                fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Your narrators on this journey',
                        style: TextStyle(color: Colors.white54, fontSize: 13),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh_rounded, color: Colors.white38),
                  onPressed: onRefresh,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                childAspectRatio: 0.85,
              ),
              itemCount: displayGuides.length,
              itemBuilder: (ctx, i) => _buildGuideCard(displayGuides[i]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGuideCard(TourGuide guide) {
    return Column(
      children: [
        Expanded(
          child: GuideAvatar(guide: guide),
        ),
        const SizedBox(height: 6),
        Text(
          guide.name,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 12,
            fontWeight: FontWeight.normal,
          ),
        ),
      ],
    );
  }
}

// ─── AdminContent ─────────────────────────────────────────────────────────────
// Debug-mode-only screen: clear data actions, guide editor, prompt variants editor.

class AdminContent extends StatefulWidget {
  final List<TourGuide> tourGuides;
  final Future<void> Function() onRefreshTourGuides;
  final List<PromptVariant> promptVariants;
  final Future<void> Function() onRefreshPromptVariants;
  final Future<void> Function() onClearTracks;
  final Map<String, dynamic>? currentHierarchy;
  final Map<String, dynamic>? previousHierarchy;
  final List<String> changedLevels;

  const AdminContent({
    super.key,
    required this.tourGuides,
    required this.onRefreshTourGuides,
    required this.promptVariants,
    required this.onRefreshPromptVariants,
    required this.onClearTracks,
    this.currentHierarchy,
    this.previousHierarchy,
    this.changedLevels = const [],
  });

  @override
  State<AdminContent> createState() => _AdminContentState();
}

class _AdminContentState extends State<AdminContent> {
  static const String _backendBase = 'https://tour-guide-backend-production.up.railway.app';
  static const Color _green = Color(0xFF3DAA74);
  static const Color _cream = Color(0xFFF5EDD8);

  bool _clearingNarrations = false;
  bool _clearingContent = false;
  bool _clearingPings = false;
  bool _clearingTracks = false;
  String? _savingGuide;
  String? _savingVariant;

  static const Map<String, String> _topicLabels = {
    'intro':              'Intro',
    'state_change':       'State Change',
    'nation_change':      'Nation Change',
    'county_town_change': 'County / Town',
    'dwell':              'Nearby Place',
    'dwell_person':       'Famous Person Born Here',
  };

  // ── Clear actions ─────────────────────────────────────────────────────────

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

  Future<void> _clearTracks() async {
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
  }

  // ── Tour Guide editor ────────────────────────────────────────────────────

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

  // ── Prompt Variant editor ────────────────────────────────────────────────

  Future<void> _editPromptVariant(PromptVariant variant) async {
    final labelCtrl    = TextEditingController(text: variant.label);
    final templateCtrl = TextEditingController(text: variant.template);
    bool activeValue   = variant.active;

    final save = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text('Edit variant: ${variant.label}'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Label', style: TextStyle(fontSize: 12, color: Colors.black54)),
                const SizedBox(height: 4),
                TextField(
                  controller: labelCtrl,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(), isDense: true,
                    contentPadding: EdgeInsets.all(10),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    const Expanded(
                      child: Text('Active', style: TextStyle(fontSize: 12, color: Colors.black54)),
                    ),
                    Switch(
                      value: activeValue,
                      activeThumbColor: _green,
                      onChanged: (v) => setDialogState(() => activeValue = v),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                const Text('Template', style: TextStyle(fontSize: 12, color: Colors.black54)),
                const SizedBox(height: 4),
                TextField(
                  controller: templateCtrl,
                  maxLines: 8,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.all(10),
                  ),
                ),
                const SizedBox(height: 8),
                const Text('Variables: {subject}, {location_context}',
                    style: TextStyle(fontSize: 11, color: Colors.black38, fontStyle: FontStyle.italic)),
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
      ),
    );
    if (save != true || !mounted) return;

    setState(() => _savingVariant = variant.id);
    try {
      final response = await http.patch(
        Uri.parse('$_backendBase/prompt-variants/${variant.id}'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'label':    labelCtrl.text.trim(),
          'template': templateCtrl.text.trim(),
          'active':   activeValue,
        }),
      );
      if (!mounted) return;
      if (response.statusCode == 200) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Variant "${labelCtrl.text.trim()}" updated'),
          backgroundColor: _green,
        ));
        await widget.onRefreshPromptVariants();
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
      if (mounted) setState(() => _savingVariant = null);
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final guides = widget.tourGuides.isNotEmpty ? widget.tourGuides : kFallbackGuides;
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
                Icon(Icons.admin_panel_settings_rounded, color: _green, size: 22),
                SizedBox(width: 8),
                Text(
                  'Tour Guides',
                  style: TextStyle(color: _green, fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 14, bottom: 2),
            child: Text(
              'ADMIN',
              style: TextStyle(
                color: Colors.black54,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.5,
              ),
            ),
          ),
          const Text(
            'Debug Tools',
            style: TextStyle(color: Colors.black, fontSize: 28, fontWeight: FontWeight.bold, height: 1.1),
          ),
          const SizedBox(height: 20),

          _buildSectionHeader('Location Hierarchy'),
          _buildHierarchyTable(),

          _buildSectionHeader('Clear Data'),
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
            onTap: _clearingTracks ? null : _clearTracks,
          ),

          _buildSectionHeader('Tour Guides'),
          _buildGuideEditorList(guides),

          _buildSectionHeader('Prompt Variants'),
          _buildPromptVariantsSection(),
        ],
      ),
    );
  }

  Widget _buildGuideEditorList(List<TourGuide> guides) {
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
          final isLast   = idx == guides.length - 1;
          final isSaving = _savingGuide == guide.name;
          return Column(
            children: [
              ListTile(
                title: Text(guide.name,
                    style: const TextStyle(color: Colors.black87, fontSize: 16)),
                subtitle: Text(guide.style,
                    style: const TextStyle(color: Colors.black45, fontSize: 12)),
                trailing: isSaving
                    ? const SizedBox(width: 20, height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black38))
                    : IconButton(
                        icon: const Icon(Icons.edit_rounded, size: 18, color: Colors.black38),
                        tooltip: 'Edit personality',
                        onPressed: () => _editTourGuide(guide),
                      ),
              ),
              if (!isLast)
                const Divider(height: 1, indent: 16, endIndent: 16, color: Colors.black12),
            ],
          );
        }).toList(),
      ),
    );
  }

  Widget _buildPromptVariantsSection() {
    final variants = widget.promptVariants;
    final topics = _topicLabels.keys.toList();
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
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                const Expanded(
                  child: Text('Tap a topic to view / edit variants',
                      style: TextStyle(fontSize: 12, color: Colors.black45)),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh, size: 18, color: Colors.black38),
                  tooltip: 'Refresh',
                  onPressed: widget.onRefreshPromptVariants,
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Colors.black12),
          ...topics.map((topic) {
            final topicVariants = variants.where((v) => v.topic == topic).toList();
            return ExpansionTile(
              title: Text(_topicLabels[topic] ?? topic,
                  style: const TextStyle(fontSize: 15, color: Colors.black87)),
              subtitle: Text(
                  '${topicVariants.length} variant${topicVariants.length == 1 ? '' : 's'}',
                  style: const TextStyle(fontSize: 12, color: Colors.black45)),
              shape: const Border(),
              children: topicVariants.isEmpty
                  ? [const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('No variants loaded', style: TextStyle(color: Colors.black38)),
                    )]
                  : topicVariants.map((v) {
                      final isSaving = _savingVariant == v.id;
                      return ListTile(
                        dense: true,
                        title: Text(v.label,
                            style: TextStyle(
                              fontSize: 14,
                              color: v.active ? Colors.black87 : Colors.black38,
                              fontStyle: v.active ? FontStyle.normal : FontStyle.italic,
                            )),
                        subtitle: Text(v.template,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11, color: Colors.black38)),
                        trailing: isSaving
                            ? const SizedBox(width: 20, height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black38))
                            : Row(mainAxisSize: MainAxisSize.min, children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: v.active ? _green.withValues(alpha: 0.12) : Colors.black12,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(v.active ? 'on' : 'off',
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: v.active ? _green : Colors.black38,
                                        fontWeight: FontWeight.bold,
                                      )),
                                ),
                                const SizedBox(width: 4),
                                IconButton(
                                  icon: const Icon(Icons.edit_rounded, size: 18, color: Colors.black38),
                                  tooltip: 'Edit',
                                  onPressed: () => _editPromptVariant(v),
                                ),
                              ]),
                      );
                    }).toList(),
            );
          }),
        ],
      ),
    );
  }

  static const _hierarchyLevels = [
    {'key': 'nation',       'label': 'Nation'},
    {'key': 'region',       'label': 'Region'},
    {'key': 'state',        'label': 'State'},
    {'key': 'metro_area',   'label': 'Metro Area'},
    {'key': 'county',       'label': 'County'},
    {'key': 'town',         'label': 'Town'},
    {'key': 'neighborhood', 'label': 'Neighborhood'},
  ];

  Widget _buildHierarchyTable() {
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
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: Row(
              children: const [
                SizedBox(width: 92),
                Expanded(
                  child: Text('PREVIOUS',
                      style: TextStyle(color: Colors.black38, fontSize: 9,
                          fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                ),
                Expanded(
                  child: Text('CURRENT',
                      style: TextStyle(color: Colors.black38, fontSize: 9,
                          fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                ),
              ],
            ),
          ),
          const Divider(color: Colors.black12, height: 1),
          ..._hierarchyLevels.map((level) {
            final key     = level['key']!;
            final label   = level['label']!;
            final current  = widget.currentHierarchy?[key]  as String? ?? '';
            final previous = widget.previousHierarchy?[key] as String? ?? '';
            final changed  = widget.changedLevels.contains(key);
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                children: [
                  SizedBox(
                    width: 88,
                    child: Text(label,
                        style: const TextStyle(color: Colors.black45, fontSize: 11,
                            fontWeight: FontWeight.w600)),
                  ),
                  Expanded(
                    child: Text(previous.isEmpty ? '—' : previous,
                        style: const TextStyle(color: Colors.black38, fontSize: 11),
                        overflow: TextOverflow.ellipsis),
                  ),
                  Expanded(
                    child: Text(
                      current.isEmpty ? '—' : current,
                      style: TextStyle(
                        color: changed ? _green : Colors.black87,
                        fontSize: 11,
                        fontWeight: changed ? FontWeight.bold : FontWeight.normal,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            );
          }),
          const SizedBox(height: 4),
        ],
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

// ─── SettingsContent ──────────────────────────────────────────────────────────
// Simplified settings page: Session, Debug Mode toggle, Music status.

class SettingsContent extends StatefulWidget {
  final AppSettings settings;
  final void Function(AppSettings) onChanged;
  final List<String> cachedMusicTracks;
  final String prefDefaultState;
  final int prefMinScore;
  final Future<void> Function({String? defaultState, int? minScore}) onSavePreferences;

  const SettingsContent({
    super.key,
    required this.settings,
    required this.onChanged,
    required this.cachedMusicTracks,
    required this.prefDefaultState,
    required this.prefMinScore,
    required this.onSavePreferences,
  });

  @override
  State<SettingsContent> createState() => _SettingsContentState();
}

class _SettingsContentState extends State<SettingsContent> {
  static const Color _green = Color(0xFF3DAA74);
  static const Color _cream = Color(0xFFF5EDD8);

  late AppSettings _settings;
  late String _prefDefaultState;
  late int _prefMinScore;
  bool _savingPrefs = false;
  bool _prefsSaved = false;

  @override
  void initState() {
    super.initState();
    _settings = AppSettings(
      debugMode: widget.settings.debugMode,
      musicEnabled: widget.settings.musicEnabled,
    );
    _prefDefaultState = widget.prefDefaultState;
    _prefMinScore = widget.prefMinScore;
  }

  void _notify() => widget.onChanged(_settings);

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
                  'Tour Guides',
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
            'Preferences',
            style: TextStyle(color: Colors.black, fontSize: 28, fontWeight: FontWeight.bold, height: 1.1),
          ),
          const SizedBox(height: 20),

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

          _buildSectionHeader('Narration Defaults'),
          _buildNarrationDefaults(),

          _buildSectionHeader('Developer'),
          _buildToggleSetting(
            label: 'Debug Mode',
            description: 'Enables the Admin tab with debug tools and configuration',
            value: _settings.debugMode,
            onChanged: (val) {
              setState(() => _settings.debugMode = val);
              _notify();
            },
          ),

          _buildSectionHeader('Music'),
          _buildToggleSetting(
            label: 'Background Music',
            description: 'Play ambient music while touring',
            value: _settings.musicEnabled,
            onChanged: (val) {
              setState(() => _settings.musicEnabled = val);
              _notify();
            },
          ),
          _buildMusicStatus(),

          _buildSectionHeader('Account'),
          _buildAccountSection(),
        ],
      ),
    );
  }

  static const List<String> _usStates = [
    'AL','AK','AZ','AR','CA','CO','CT','DE','FL','GA',
    'HI','ID','IL','IN','IA','KS','KY','LA','ME','MD',
    'MA','MI','MN','MS','MO','MT','NE','NV','NH','NJ',
    'NM','NY','NC','ND','OH','OK','OR','PA','RI','SC',
    'SD','TN','TX','UT','VT','VA','WA','WV','WI','WY','DC',
  ];

  Widget _buildNarrationDefaults() {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 8, offset: const Offset(0, 2)),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'These defaults are saved to your account and applied when the app starts.',
              style: TextStyle(color: Colors.black45, fontSize: 12),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                // State picker
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'DEFAULT STATE',
                        style: TextStyle(color: Colors.black45, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1.2),
                      ),
                      const SizedBox(height: 6),
                      Container(
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.black12),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: _prefDefaultState,
                            isExpanded: true,
                            style: const TextStyle(color: Colors.black87, fontSize: 14),
                            items: _usStates.map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
                            onChanged: (val) {
                              if (val != null) setState(() => _prefDefaultState = val);
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                // Min score
                SizedBox(
                  width: 80,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'MIN SCORE',
                        style: TextStyle(color: Colors.black45, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1.2),
                      ),
                      const SizedBox(height: 6),
                      Container(
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.black12),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            IconButton(
                              icon: const Icon(Icons.remove, size: 16),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(minWidth: 32, minHeight: 40),
                              onPressed: _prefMinScore > 0
                                  ? () => setState(() => _prefMinScore--)
                                  : null,
                            ),
                            Expanded(
                              child: Text(
                                '$_prefMinScore',
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: Colors.black87, fontSize: 14, fontWeight: FontWeight.w600),
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.add, size: 16),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(minWidth: 32, minHeight: 40),
                              onPressed: _prefMinScore < 10
                                  ? () => setState(() => _prefMinScore++)
                                  : null,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _savingPrefs ? null : () async {
                  setState(() { _savingPrefs = true; _prefsSaved = false; });
                  try {
                    await widget.onSavePreferences(
                      defaultState: _prefDefaultState,
                      minScore: _prefMinScore,
                    );
                    setState(() => _prefsSaved = true);
                    Future.delayed(const Duration(seconds: 2), () {
                      if (mounted) setState(() => _prefsSaved = false);
                    });
                  } finally {
                    if (mounted) setState(() => _savingPrefs = false);
                  }
                },
                icon: _savingPrefs
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : Icon(_prefsSaved ? Icons.check_rounded : Icons.save_rounded, size: 16),
                label: Text(_prefsSaved ? 'Saved!' : 'Save Defaults'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _green,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAccountSection() {
    return StreamBuilder<User?>(
      stream: AuthService.authStateChanges,
      builder: (context, snapshot) {
        final user = snapshot.data ?? FirebaseAuth.instance.currentUser;
        final isAnon = user == null || user.isAnonymous;

        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 8, offset: const Offset(0, 2)),
            ],
          ),
          child: isAnon
              ? Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.person_outline_rounded, color: Colors.black38),
                      title: const Text('Anonymous', style: TextStyle(color: Colors.black87, fontSize: 14)),
                      subtitle: const Text('Sign in to save tour history across devices', style: TextStyle(color: Colors.black45, fontSize: 12)),
                    ),
                    const Divider(height: 1, indent: 16, endIndent: 16, color: Colors.black12),
                    ListTile(
                      leading: const Icon(Icons.login_rounded, color: _green),
                      title: const Text('Link Google Account', style: TextStyle(color: _green, fontSize: 14, fontWeight: FontWeight.w600)),
                      trailing: const Icon(Icons.chevron_right_rounded, color: Colors.black26),
                      onTap: () async {
                        try {
                          await AuthService.linkWithGoogle();
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Google account linked!')),
                            );
                          }
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Sign-in failed: $e')),
                            );
                          }
                        }
                      },
                    ),
                    const Divider(height: 1, indent: 16, endIndent: 16, color: Colors.black12),
                    ListTile(
                      leading: const Icon(Icons.facebook_rounded, color: Color(0xFF1877F2)),
                      title: const Text('Link Facebook Account', style: TextStyle(color: Color(0xFF1877F2), fontSize: 14, fontWeight: FontWeight.w600)),
                      trailing: const Icon(Icons.chevron_right_rounded, color: Colors.black26),
                      onTap: () async {
                        try {
                          await AuthService.linkWithFacebook();
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Facebook account linked!')),
                            );
                          }
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Sign-in failed: $e')),
                            );
                          }
                        }
                      },
                    ),
                  ],
                )
              : Column(
                  children: [
                    ListTile(
                      leading: user.photoURL != null
                          ? CircleAvatar(
                              backgroundImage: NetworkImage(user.photoURL!),
                              radius: 16,
                            )
                          : const Icon(Icons.account_circle_rounded, color: _green),
                      title: Text(
                        user.displayName ?? user.email ?? 'Signed in',
                        style: const TextStyle(color: Colors.black87, fontSize: 14, fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        user.email ?? '',
                        style: const TextStyle(color: Colors.black45, fontSize: 12),
                      ),
                    ),
                    const Divider(height: 1, indent: 16, endIndent: 16, color: Colors.black12),
                    ListTile(
                      leading: const Icon(Icons.logout_rounded, color: Colors.red),
                      title: const Text('Sign Out', style: TextStyle(color: Colors.red, fontSize: 14, fontWeight: FontWeight.w600)),
                      onTap: () async {
                        await AuthService.signOut();
                      },
                    ),
                  ],
                ),
        );
      },
    );
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
