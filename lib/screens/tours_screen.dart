import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../auth_service.dart';
import '../models/tour.dart';

class ToursScreen extends StatefulWidget {
  final double? userLat;
  final double? userLng;
  const ToursScreen({super.key, this.userLat, this.userLng});

  @override
  State<ToursScreen> createState() => _ToursScreenState();
}

class _ToursScreenState extends State<ToursScreen> {
  static const String _backendBase =
      'https://tour-guide-backend-production.up.railway.app';
  static const Color _teal = Color(0xFF0d9488);

  List<Tour> _allTours = [];
  List<String> _availableStates = [];
  String? _filterState;
  double? _filterRadiusMiles;
  bool _loading = true;
  double? _userLat;
  double? _userLng;

  List<Tour> get _myTours => _allTours.where((t) => t.enrolled).toList();
  List<Tour> get _availableTours => _allTours.where((t) => !t.enrolled).toList();

  @override
  void initState() {
    super.initState();
    _userLat = widget.userLat;
    _userLng = widget.userLng;
    _fetchStates();
    _fetchTours();
    if (_userLat == null) _resolvePosition();
  }

  Future<void> _resolvePosition() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return;
      final perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return;
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.low),
      ).timeout(const Duration(seconds: 5));
      if (mounted) setState(() { _userLat = pos.latitude; _userLng = pos.longitude; });
    } catch (_) {}
  }

  Future<void> _fetchStates() async {
    try {
      final response = await http
          .get(Uri.parse('$_backendBase/tours/states'))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 200 && mounted) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        setState(() {
          _availableStates = (data['states'] as List).cast<String>();
        });
      }
    } catch (e) {
      debugPrint('ToursScreen fetchStates error: $e');
    }
  }

  Future<void> _fetchTours() async {
    if (mounted) setState(() => _loading = true);
    try {
      final params = <String, String>{};
      if (_filterState != null) params['state'] = _filterState!;
      if (_filterRadiusMiles != null && _userLat != null && _userLng != null) {
        params['lat'] = _userLat.toString();
        params['lng'] = _userLng.toString();
        params['radius_miles'] = _filterRadiusMiles.toString();
      }

      final uri = Uri.parse('$_backendBase/tours').replace(queryParameters: params.isNotEmpty ? params : null);
      final headers = <String, String>{};
      final token = await AuthService.getIdToken();
      if (token != null) headers['Authorization'] = 'Bearer $token';

      final response = await http.get(uri, headers: headers).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200 && mounted) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final tours = (data['tours'] as List)
            .map((j) => Tour.fromJson(j as Map<String, dynamic>))
            .toList();
        setState(() { _allTours = tours; _loading = false; });
      }
    } catch (e) {
      debugPrint('ToursScreen fetch error: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _joinTour(Tour tour) async {
    try {
      final token = await AuthService.getIdToken();
      if (token == null) return;
      await http.post(
        Uri.parse('$_backendBase/user/tours/${tour.id}/join'),
        headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 10));

      // Save as active tour for map screen
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('selected_tour_id', tour.id);
      await prefs.setString('selected_tour_json', jsonEncode(tour.toJson()));
    } catch (e) {
      debugPrint('ToursScreen joinTour error: $e');
    }
    _fetchTours();
  }

  Future<void> _leaveTour(Tour tour) async {
    try {
      final token = await AuthService.getIdToken();
      if (token == null) return;
      await http.post(
        Uri.parse('$_backendBase/user/tours/${tour.id}/leave'),
        headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 10));

      // Clear from map screen if this was the active tour
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getString('selected_tour_id') == tour.id) {
        await prefs.remove('selected_tour_id');
        await prefs.remove('selected_tour_json');
      }
    } catch (e) {
      debugPrint('ToursScreen leaveTour error: $e');
    }
    _fetchTours();
  }

  @override
  Widget build(BuildContext context) {
    final myTours = _myTours;
    final available = _availableTours;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Tours'),
        backgroundColor: _teal,
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          // ── Filter bar ──
          _buildFilterBar(),
          const Divider(height: 1),
          // ── Content ──
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _allTours.isEmpty
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(32),
                          child: Text('No tours match your filters.',
                              style: TextStyle(color: Colors.grey, fontSize: 16)),
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: _fetchTours,
                        child: ListView(
                          padding: const EdgeInsets.only(bottom: 24),
                          children: [
                            if (myTours.isNotEmpty) ...[
                              _sectionHeader('MY TOURS'),
                              ...myTours.map(_buildMyTourCard),
                            ],
                            _sectionHeader('AVAILABLE TOURS'),
                            if (available.isEmpty)
                              const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                child: Text('No available tours match your filters.',
                                    style: TextStyle(color: Colors.grey, fontSize: 14)),
                              )
                            else
                              ...available.map(_buildAvailableTourCard),
                          ],
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  // ── Filter bar ──────────────────────────────────────────────────────────────

  Widget _buildFilterBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          // State dropdown
          Expanded(
            child: Container(
              height: 36,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.shade300),
                borderRadius: BorderRadius.circular(8),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String?>(
                  value: _filterState,
                  isExpanded: true,
                  hint: const Text('All States', style: TextStyle(fontSize: 13)),
                  style: const TextStyle(fontSize: 13, color: Colors.black87),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('All States')),
                    ..._availableStates.map((s) =>
                        DropdownMenuItem(value: s, child: Text(s))),
                  ],
                  onChanged: (v) {
                    setState(() => _filterState = v);
                    _fetchTours();
                  },
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Distance dropdown
          Expanded(
            child: Container(
              height: 36,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.shade300),
                borderRadius: BorderRadius.circular(8),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<double?>(
                  value: _filterRadiusMiles,
                  isExpanded: true,
                  hint: const Text('Any Distance', style: TextStyle(fontSize: 13)),
                  style: const TextStyle(fontSize: 13, color: Colors.black87),
                  items: const [
                    DropdownMenuItem(value: null, child: Text('Any Distance')),
                    DropdownMenuItem(value: 25, child: Text('Within 25 mi')),
                    DropdownMenuItem(value: 50, child: Text('Within 50 mi')),
                    DropdownMenuItem(value: 100, child: Text('Within 100 mi')),
                    DropdownMenuItem(value: 250, child: Text('Within 250 mi')),
                  ],
                  onChanged: (v) {
                    setState(() => _filterRadiusMiles = v);
                    _fetchTours();
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Section header ──────────────────────────────────────────────────────────

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: Colors.grey.shade600,
          letterSpacing: 1.0,
        ),
      ),
    );
  }

  // ── My Tour card (enrolled, with progress) ────────────────────────────────

  Widget _buildMyTourCard(Tour tour) {
    final pct = tour.locationCount > 0
        ? (tour.locationsVisited / tour.locationCount * 100).round()
        : 0;
    final progress = tour.locationCount > 0
        ? tour.locationsVisited / tour.locationCount
        : 0.0;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      elevation: 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: _teal.withValues(alpha: 0.3)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.map, color: _teal, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(tour.name,
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                ),
                SizedBox(
                  height: 28,
                  child: TextButton(
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      foregroundColor: Colors.red.shade400,
                      textStyle: const TextStyle(fontSize: 12),
                    ),
                    onPressed: () => _leaveTour(tour),
                    child: const Text('Leave'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Progress bar
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 6,
                backgroundColor: Colors.grey.shade200,
                valueColor: const AlwaysStoppedAnimation(_teal),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${tour.locationsVisited} of ${tour.locationCount} locations · $pct%',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }

  // ── Available tour card ───────────────────────────────────────────────────

  Widget _buildAvailableTourCard(Tour tour) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _joinTour(tour),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Icon(Icons.map_outlined, color: Colors.grey.shade400, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tour.name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                    const SizedBox(height: 2),
                    Text(
                      '${tour.locationCount} locations${tour.stateCodes.isNotEmpty ? ' · ${tour.stateCodes.join(", ")}' : ''}',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: _teal.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Text('Join',
                    style: TextStyle(color: _teal, fontSize: 12, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
