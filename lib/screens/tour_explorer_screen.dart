import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../auth_service.dart';
import '../models/tour.dart';
import '../models/tour_location.dart';
import 'location_explorer_screen.dart';

class TourExplorerScreen extends StatefulWidget {
  final Tour tour;
  const TourExplorerScreen({super.key, required this.tour});

  @override
  State<TourExplorerScreen> createState() => _TourExplorerScreenState();
}

class _TourExplorerScreenState extends State<TourExplorerScreen> {
  static const String _backendBase =
      'https://tour-guide-backend-production.up.railway.app';
  static const Color _teal = Color(0xFF0d9488);

  late Tour _tour;
  List<TourLocation> _locations = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _tour = widget.tour;
    _fetchDetail();
  }

  Future<void> _fetchDetail() async {
    try {
      final headers = <String, String>{};
      final token = await AuthService.getIdToken();
      if (token != null) headers['Authorization'] = 'Bearer $token';

      final response = await http
          .get(Uri.parse('$_backendBase/tours/${_tour.id}/detail'), headers: headers)
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 200 && mounted) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final tourJson = data['tour'] as Map<String, dynamic>;
        final locs = (data['locations'] as List)
            .map((j) => TourLocation.fromJson(j as Map<String, dynamic>))
            .toList();
        setState(() {
          _tour = Tour(
            id: tourJson['id'] as String,
            name: tourJson['name'] as String,
            description: tourJson['description'] as String?,
            photoUrl: tourJson['photo_url'] as String?,
            locationCount: (tourJson['location_count'] as num?)?.toInt() ?? 0,
            locationIds: _tour.locationIds,
            stateCodes: _tour.stateCodes,
            locationsVisited: (tourJson['locations_visited'] as num?)?.toInt() ?? 0,
            enrolled: tourJson['enrolled'] as bool? ?? false,
          );
          _locations = locs;
          _loading = false;
        });
      }
    } catch (e) {
      debugPrint('TourExplorer fetchDetail error: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _joinTour() async {
    try {
      final token = await AuthService.getIdToken();
      if (token == null) return;
      await http.post(
        Uri.parse('$_backendBase/user/tours/${_tour.id}/join'),
        headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 10));

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('selected_tour_id', _tour.id);
      await prefs.setString('selected_tour_json', jsonEncode(_tour.toJson()));
    } catch (e) {
      debugPrint('TourExplorer joinTour error: $e');
    }
    _fetchDetail();
  }

  Future<void> _leaveTour() async {
    try {
      final token = await AuthService.getIdToken();
      if (token == null) return;
      await http.post(
        Uri.parse('$_backendBase/user/tours/${_tour.id}/leave'),
        headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 10));

      final prefs = await SharedPreferences.getInstance();
      if (prefs.getString('selected_tour_id') == _tour.id) {
        await prefs.remove('selected_tour_id');
        await prefs.remove('selected_tour_json');
      }
    } catch (e) {
      debugPrint('TourExplorer leaveTour error: $e');
    }
    _fetchDetail();
  }

  @override
  Widget build(BuildContext context) {
    final pct = _tour.locationCount > 0
        ? (_tour.locationsVisited / _tour.locationCount * 100).round()
        : 0;
    final progress = _tour.locationCount > 0
        ? _tour.locationsVisited / _tour.locationCount
        : 0.0;

    return Scaffold(
      appBar: AppBar(
        title: Text(_tour.name),
        backgroundColor: _teal,
        foregroundColor: Colors.white,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _fetchDetail,
              child: ListView(
                padding: const EdgeInsets.only(bottom: 32),
                children: [
                  // ── Hero photo ──
                  _buildHeroPhoto(),
                  // ── Progress + enrollment ──
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (_tour.description != null && _tour.description!.isNotEmpty) ...[
                          Text(_tour.description!,
                              style: TextStyle(fontSize: 14, color: Colors.grey.shade700)),
                          const SizedBox(height: 12),
                        ],
                        // Progress bar
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: progress,
                            minHeight: 8,
                            backgroundColor: Colors.grey.shade200,
                            valueColor: const AlwaysStoppedAnimation(_teal),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '${_tour.locationsVisited} of ${_tour.locationCount} visited · $pct%',
                          style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
                        ),
                        const SizedBox(height: 12),
                        // Join / Leave button
                        SizedBox(
                          width: double.infinity,
                          child: _tour.enrolled
                              ? OutlinedButton(
                                  onPressed: _leaveTour,
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: Colors.red.shade400,
                                    side: BorderSide(color: Colors.red.shade300),
                                  ),
                                  child: const Text('Leave Tour'),
                                )
                              : ElevatedButton(
                                  onPressed: _joinTour,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: _teal,
                                    foregroundColor: Colors.white,
                                  ),
                                  child: const Text('Join Tour'),
                                ),
                        ),
                      ],
                    ),
                  ),
                  // ── Locations header ──
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
                    child: Text(
                      'LOCATIONS',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: Colors.grey.shade600,
                        letterSpacing: 1.0,
                      ),
                    ),
                  ),
                  // ── Location list ──
                  ..._locations.map(_buildLocationTile),
                ],
              ),
            ),
    );
  }

  Widget _buildHeroPhoto() {
    if (_tour.photoUrl != null) {
      return Image.network(
        _tour.photoUrl!,
        height: 180,
        width: double.infinity,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _heroPlaceholder(),
      );
    }
    return _heroPlaceholder();
  }

  Widget _heroPlaceholder() {
    return Container(
      height: 180,
      width: double.infinity,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [_teal.withValues(alpha: 0.2), _teal.withValues(alpha: 0.05)],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      child: const Icon(Icons.map, size: 64, color: _teal),
    );
  }

  Widget _buildLocationTile(TourLocation loc) {
    return InkWell(
      onTap: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => LocationExplorerScreen(
              locationId: loc.id,
              locationName: loc.name,
            ),
          ),
        );
        _fetchDetail(); // re-fetch in case visit status changed
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            // Visit indicator
            Icon(
              loc.visited ? Icons.check_circle : Icons.radio_button_unchecked,
              color: loc.visited ? _teal : Colors.grey.shade300,
              size: 22,
            ),
            const SizedBox(width: 12),
            // Location thumbnail
            _locationThumbnail(loc),
            const SizedBox(width: 12),
            // Name + story count
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    loc.name,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: loc.visited ? Colors.black87 : Colors.black54,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    loc.storyCount == 1
                        ? '1 story'
                        : '${loc.storyCount} stories',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: Colors.grey.shade300, size: 20),
          ],
        ),
      ),
    );
  }

  Widget _locationThumbnail(TourLocation loc) {
    if (loc.photoUrl != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.network(
          loc.photoUrl!,
          width: 40,
          height: 40,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _locationPlaceholder(),
        ),
      );
    }
    return _locationPlaceholder();
  }

  Widget _locationPlaceholder() {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Icon(Icons.place, color: Colors.grey.shade400, size: 20),
    );
  }
}
