import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../auth_service.dart';

class TourGuidesScreen extends StatefulWidget {
  const TourGuidesScreen({super.key});

  @override
  State<TourGuidesScreen> createState() => _TourGuidesScreenState();
}

class _TourGuidesScreenState extends State<TourGuidesScreen> {
  static const String _backendBase =
      'https://tour-guide-backend-production.up.railway.app';
  static const Color _teal = Color(0xFF0d9488);

  List<Map<String, dynamic>> _guides = [];
  String? _preferredGuideId; // UUID or null
  Set<String> _suppressedGuideIds = {};
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      // Fetch guides and user preferences in parallel
      final guidesFuture = http
          .get(Uri.parse('$_backendBase/tour-guides'))
          .timeout(const Duration(seconds: 10));

      final token = await AuthService.getIdToken();
      Future<http.Response>? prefsFuture;
      if (token != null) {
        prefsFuture = http
            .get(
              Uri.parse('$_backendBase/user/guide-preferences'),
              headers: {'Authorization': 'Bearer $token'},
            )
            .timeout(const Duration(seconds: 10));
      }

      final guidesResp = await guidesFuture;
      if (guidesResp.statusCode == 200) {
        final data = jsonDecode(guidesResp.body) as Map<String, dynamic>;
        final guides = (data['tour_guides'] as List)
            .map((g) => g as Map<String, dynamic>)
            .toList();
        if (mounted) setState(() => _guides = guides);
      }

      if (prefsFuture != null) {
        final prefsResp = await prefsFuture;
        if (prefsResp.statusCode == 200) {
          final prefs = jsonDecode(prefsResp.body) as Map<String, dynamic>;
          if (mounted) {
            setState(() {
              _preferredGuideId = prefs['preferred_guide_id'] as String?;
              final suppressed = prefs['suppressed_guide_ids'] as List?;
              _suppressedGuideIds =
                  suppressed?.map((e) => e as String).toSet() ?? {};
            });
          }
        }
      }
    } catch (e) {
      debugPrint('TourGuidesScreen load error: $e');
    }

    if (mounted) setState(() => _loading = false);
  }

  Future<void> _savePreferences() async {
    setState(() => _saving = true);
    try {
      final token = await AuthService.getIdToken();
      if (token == null) return;
      await http
          .patch(
            Uri.parse('$_backendBase/user/guide-preferences'),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'preferred_guide_id': _preferredGuideId,
              'suppressed_guide_ids': _suppressedGuideIds.toList(),
            }),
          )
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      debugPrint('TourGuidesScreen save error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to save preferences')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _setPreferredGuide(String? guideId) {
    setState(() => _preferredGuideId = guideId);
    _savePreferences();
  }

  void _toggleGuideSuppression(String guideId, String guideName) {
    final wasSuppressed = _suppressedGuideIds.contains(guideId);
    setState(() {
      if (wasSuppressed) {
        _suppressedGuideIds.remove(guideId);
      } else {
        _suppressedGuideIds.add(guideId);
      }
    });
    _savePreferences();

    // Warn when suppressing a guide
    if (!wasSuppressed && mounted) {
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("You won't hear any narrations from $guideName"),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () {
              setState(() => _suppressedGuideIds.remove(guideId));
              _savePreferences();
            },
          ),
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  Widget _buildGuidePhoto(Map<String, dynamic> guide, {double size = 48}) {
    final photoUrl = guide['photo_url'] as String?;
    final name = guide['name'] as String? ?? '?';
    if (photoUrl != null && photoUrl.isNotEmpty) {
      return ClipOval(
        child: Image.network(
          photoUrl,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _fallbackAvatar(name, size),
        ),
      );
    }
    return _fallbackAvatar(name, size);
  }

  Widget _fallbackAvatar(String name, double size) {
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: [Color(0xFF0d9488), Color(0xFF14b8a6)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Center(
        child: Text(
          name.isNotEmpty ? name[0].toUpperCase() : '?',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: size * 0.4,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tour Guides'),
        backgroundColor: _teal,
        foregroundColor: Colors.white,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                // ── Lead Narrator dropdown ──
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 20, 16, 8),
                  child: Text(
                    'Lead Narrator',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: Colors.grey,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: _preferredGuideId,
                        isExpanded: true,
                        hint: const Text('No preference'),
                        items: [
                          const DropdownMenuItem<String>(
                            value: null,
                            child: Text('No preference'),
                          ),
                          ..._guides.map((g) {
                            final id = g['id'] as String;
                            final name = g['name'] as String? ?? '';
                            return DropdownMenuItem<String>(
                              value: id,
                              child: Row(
                                children: [
                                  _buildGuidePhoto(g, size: 28),
                                  const SizedBox(width: 10),
                                  Text(name),
                                ],
                              ),
                            );
                          }),
                        ],
                        onChanged: _setPreferredGuide,
                      ),
                    ),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 4, 16, 16),
                  child: Text(
                    'Preferred guide when available for a story',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),

                // ── All Guides ──
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    'All Guides',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: Colors.grey,
                    ),
                  ),
                ),
                ..._guides.map((g) {
                  final id = g['id'] as String;
                  final name = g['name'] as String? ?? '';
                  final style = g['style'] as String? ?? '';
                  final isSuppressed = _suppressedGuideIds.contains(id);
                  return Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: Opacity(
                      opacity: isSuppressed ? 0.45 : 1.0,
                      child: Card(
                        elevation: isSuppressed ? 0 : 1,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(
                            color: isSuppressed
                                ? Colors.grey.shade300
                                : _teal.withAlpha(50),
                          ),
                        ),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () => _toggleGuideSuppression(id, name),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Row(
                              children: [
                                _buildGuidePhoto(g, size: 48),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        name,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 16,
                                        ),
                                      ),
                                      if (style.isNotEmpty)
                                        Text(
                                          style,
                                          style: TextStyle(
                                            color: Colors.grey.shade600,
                                            fontSize: 13,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                    ],
                                  ),
                                ),
                                Icon(
                                  isSuppressed
                                      ? Icons.radio_button_off
                                      : Icons.check_circle,
                                  color:
                                      isSuppressed ? Colors.grey.shade400 : _teal,
                                  size: 28,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                }),
                if (_saving)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ),
                const SizedBox(height: 24),
              ],
            ),
    );
  }
}
