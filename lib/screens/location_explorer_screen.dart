import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../auth_service.dart';
import '../models/location_detail.dart';

class LocationExplorerScreen extends StatefulWidget {
  final String locationId;
  final String? locationName;
  const LocationExplorerScreen({
    super.key,
    required this.locationId,
    this.locationName,
  });

  @override
  State<LocationExplorerScreen> createState() => _LocationExplorerScreenState();
}

class _LocationExplorerScreenState extends State<LocationExplorerScreen> {
  static const String _backendBase =
      'https://tour-guide-backend-production.up.railway.app';
  static const Color _teal = Color(0xFF0d9488);

  LocationDetail? _location;
  List<StorySummary> _stories = [];
  bool _loading = true;
  bool _togglingVisit = false;

  @override
  void initState() {
    super.initState();
    _fetchDetail();
  }

  Future<void> _fetchDetail() async {
    try {
      final headers = <String, String>{};
      final token = await AuthService.getIdToken();
      if (token != null) headers['Authorization'] = 'Bearer $token';

      final response = await http
          .get(Uri.parse('$_backendBase/locations/${widget.locationId}'), headers: headers)
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 200 && mounted) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        setState(() {
          _location = LocationDetail.fromJson(data['location'] as Map<String, dynamic>);
          _stories = (data['stories'] as List)
              .map((j) => StorySummary.fromJson(j as Map<String, dynamic>))
              .toList();
          _loading = false;
        });
      }
    } catch (e) {
      debugPrint('LocationExplorer fetchDetail error: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _toggleVisited(bool visited) async {
    if (_togglingVisit || _location == null) return;
    setState(() => _togglingVisit = true);

    // Optimistic update
    final oldVisited = _location!.visited;
    setState(() {
      _location = LocationDetail(
        id: _location!.id,
        name: _location!.name,
        description: _location!.description,
        lat: _location!.lat,
        lng: _location!.lng,
        photoUrl: _location!.photoUrl,
        county: _location!.county,
        stateCode: _location!.stateCode,
        locationType: _location!.locationType,
        visited: visited,
      );
    });

    try {
      final token = await AuthService.getIdToken();
      if (token == null) throw Exception('Not authenticated');

      if (visited) {
        await http.post(
          Uri.parse('$_backendBase/user/locations/${widget.locationId}/visit'),
          headers: {'Authorization': 'Bearer $token'},
        ).timeout(const Duration(seconds: 10));
      } else {
        await http.delete(
          Uri.parse('$_backendBase/user/locations/${widget.locationId}/visit'),
          headers: {'Authorization': 'Bearer $token'},
        ).timeout(const Duration(seconds: 10));
      }
    } catch (e) {
      debugPrint('LocationExplorer toggleVisited error: $e');
      // Revert on failure
      if (mounted) {
        setState(() {
          _location = LocationDetail(
            id: _location!.id,
            name: _location!.name,
            description: _location!.description,
            lat: _location!.lat,
            lng: _location!.lng,
            photoUrl: _location!.photoUrl,
            county: _location!.county,
            stateCode: _location!.stateCode,
            locationType: _location!.locationType,
            visited: oldVisited,
          );
        });
      }
    } finally {
      if (mounted) setState(() => _togglingVisit = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = _location?.name ?? widget.locationName ?? 'Location';

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        backgroundColor: _teal,
        foregroundColor: Colors.white,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _location == null
              ? const Center(child: Text('Location not found'))
              : RefreshIndicator(
                  onRefresh: _fetchDetail,
                  child: ListView(
                    padding: const EdgeInsets.only(bottom: 32),
                    children: [
                      // ── Photo ──
                      _buildPhoto(),
                      // ── Info ──
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _location!.name,
                              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                            ),
                            if (_location!.county != null || _location!.stateCode != null) ...[
                              const SizedBox(height: 4),
                              Text(
                                [
                                  if (_location!.county != null) _location!.county!,
                                  if (_location!.stateCode != null) _location!.stateCode!,
                                ].join(' · '),
                                style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
                              ),
                            ],
                          ],
                        ),
                      ),
                      // ── Visited toggle ──
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                        child: Card(
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                            side: BorderSide(color: Colors.grey.shade200),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                            child: Row(
                              children: [
                                Icon(
                                  _location!.visited ? Icons.check_circle : Icons.radio_button_unchecked,
                                  color: _location!.visited ? _teal : Colors.grey.shade400,
                                  size: 22,
                                ),
                                const SizedBox(width: 12),
                                const Expanded(
                                  child: Text('Visited', style: TextStyle(fontSize: 15)),
                                ),
                                Switch(
                                  value: _location!.visited,
                                  activeTrackColor: _teal,
                                  onChanged: _togglingVisit ? null : _toggleVisited,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      // ── Stories ──
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
                        child: Text(
                          'STORIES (${_stories.length})',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: Colors.grey.shade600,
                            letterSpacing: 1.0,
                          ),
                        ),
                      ),
                      if (_stories.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          child: Text(
                            'No stories available yet for this location.',
                            style: TextStyle(fontSize: 14, color: Colors.grey.shade500),
                          ),
                        )
                      else
                        ..._stories.map(_buildStoryTile),
                      // ── Description ──
                      if (_location!.description != null && _location!.description!.isNotEmpty) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
                          child: Text(
                            'ABOUT',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: Colors.grey.shade600,
                              letterSpacing: 1.0,
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Text(
                            _location!.description!,
                            style: TextStyle(fontSize: 14, color: Colors.grey.shade700, height: 1.5),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
    );
  }

  Widget _buildPhoto() {
    if (_location?.photoUrl != null) {
      return Image.network(
        _location!.photoUrl!,
        height: 200,
        width: double.infinity,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _photoPlaceholder(),
      );
    }
    return _photoPlaceholder();
  }

  Widget _photoPlaceholder() {
    return Container(
      height: 200,
      width: double.infinity,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.grey.shade200, Colors.grey.shade100],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      child: Icon(Icons.place, size: 64, color: Colors.grey.shade400),
    );
  }

  Widget _buildStoryTile(StorySummary story) {
    final duration = story.audioDurationS != null
        ? '${(story.audioDurationS! / 60).floor()}:${(story.audioDurationS! % 60).round().toString().padLeft(2, '0')}'
        : null;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: Colors.grey.shade200),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.mic, color: _teal, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      story.title ?? 'Untitled Story',
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      [
                        if (story.narrator != null) 'Narrator: ${story.narrator}',
                        if (duration != null) duration,
                      ].join(' · '),
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                    ),
                    if (story.guideAudioCount > 0) ...[
                      const SizedBox(height: 2),
                      Text(
                        '${story.guideAudioCount} guide recording${story.guideAudioCount != 1 ? 's' : ''}',
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
