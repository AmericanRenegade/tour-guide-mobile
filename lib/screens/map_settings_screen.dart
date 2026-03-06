import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MapSettingsScreen extends StatefulWidget {
  const MapSettingsScreen({super.key});

  @override
  State<MapSettingsScreen> createState() => _MapSettingsScreenState();
}

class _MapSettingsScreenState extends State<MapSettingsScreen> {
  static const Color _teal = Color(0xFF0d9488);

  String _mapStyle = 'voyager';
  String _distanceUnit = 'miles';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _mapStyle = prefs.getString('map_style') ?? 'voyager';
      _distanceUnit = prefs.getString('distance_unit') ?? 'miles';
      _loading = false;
    });
  }

  Future<void> _setMapStyle(String? style) async {
    if (style == null) return;
    setState(() => _mapStyle = style);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('map_style', style);
  }

  Future<void> _setDistanceUnit(String? unit) async {
    if (unit == null) return;
    setState(() => _distanceUnit = unit);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('distance_unit', unit);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Map Settings'),
        backgroundColor: _teal,
        foregroundColor: Colors.white,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                // ── Map Style ──
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 20, 16, 8),
                  child: Text(
                    'Map Style',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: Colors.grey,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: _mapStyle,
                        isExpanded: true,
                        items: const [
                          DropdownMenuItem(
                            value: 'voyager',
                            child: Text('Voyager'),
                          ),
                          DropdownMenuItem(
                            value: 'osm',
                            child: Text('Standard'),
                          ),
                          DropdownMenuItem(
                            value: 'positron',
                            child: Text('Light'),
                          ),
                          DropdownMenuItem(
                            value: 'dark',
                            child: Text('Dark'),
                          ),
                          DropdownMenuItem(
                            value: 'satellite',
                            child: Text('Satellite'),
                          ),
                          DropdownMenuItem(
                            value: 'topo',
                            child: Text('Topo'),
                          ),
                        ],
                        onChanged: _setMapStyle,
                      ),
                    ),
                  ),
                ),
                const Divider(height: 32),

                // ── Distance Units ──
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    'Distance Units',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: Colors.grey,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: _distanceUnit,
                        isExpanded: true,
                        items: const [
                          DropdownMenuItem(value: 'miles', child: Text('Miles')),
                          DropdownMenuItem(value: 'km', child: Text('Kilometers')),
                        ],
                        onChanged: _setDistanceUnit,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 32),
              ],
            ),
    );
  }
}
