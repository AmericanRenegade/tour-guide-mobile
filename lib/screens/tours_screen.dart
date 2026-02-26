import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/tour.dart';

class ToursScreen extends StatefulWidget {
  const ToursScreen({super.key});

  @override
  State<ToursScreen> createState() => _ToursScreenState();
}

class _ToursScreenState extends State<ToursScreen> {
  static const String _backendBase =
      'https://tour-guide-backend-production.up.railway.app';
  static const Color _teal = Color(0xFF0d9488);

  List<Tour> _tours = [];
  bool _loading = true;
  String? _selectedTourId;

  @override
  void initState() {
    super.initState();
    _loadSelectedTour();
    _fetchTours();
  }

  Future<void> _loadSelectedTour() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() => _selectedTourId = prefs.getString('selected_tour_id'));
  }

  Future<void> _fetchTours() async {
    try {
      final response = await http
          .get(Uri.parse('$_backendBase/tours'))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 200 && mounted) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final tours = (data['tours'] as List)
            .map((j) => Tour.fromJson(j as Map<String, dynamic>))
            .toList();
        setState(() {
          _tours = tours;
          _loading = false;
        });
      }
    } catch (e) {
      debugPrint('ToursScreen fetch error: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _selectTour(Tour? tour) async {
    final prefs = await SharedPreferences.getInstance();
    if (tour == null || tour.id == _selectedTourId) {
      // Deselect
      await prefs.remove('selected_tour_id');
      await prefs.remove('selected_tour_json');
      setState(() => _selectedTourId = null);
    } else {
      // Select
      await prefs.setString('selected_tour_id', tour.id);
      await prefs.setString('selected_tour_json', jsonEncode(tour.toJson()));
      setState(() => _selectedTourId = tour.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tours'),
        backgroundColor: _teal,
        foregroundColor: Colors.white,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _tours.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Text(
                      'No tours available yet.',
                      style: TextStyle(color: Colors.grey, fontSize: 16),
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: _tours.length,
                  separatorBuilder: (_, __) =>
                      const Divider(height: 1, indent: 16, endIndent: 16),
                  itemBuilder: (_, i) {
                    final tour = _tours[i];
                    final selected = tour.id == _selectedTourId;
                    return ListTile(
                      title: Text(
                        tour.name,
                        style: TextStyle(
                          fontWeight:
                              selected ? FontWeight.bold : FontWeight.normal,
                          color: selected ? _teal : null,
                        ),
                      ),
                      subtitle: tour.description != null &&
                              tour.description!.isNotEmpty
                          ? Text(
                              tour.description!,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13),
                            )
                          : null,
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '${tour.locationCount} locations',
                            style: const TextStyle(
                                fontSize: 12, color: Colors.grey),
                          ),
                          if (selected) ...[
                            const SizedBox(width: 8),
                            const Icon(Icons.check_circle,
                                color: _teal, size: 20),
                          ],
                        ],
                      ),
                      onTap: () => _selectTour(tour),
                    );
                  },
                ),
    );
  }
}
