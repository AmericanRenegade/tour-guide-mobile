import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';
import 'package:just_audio/just_audio.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:uuid/uuid.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'settings.dart';

void main() {
  runApp(const TourGuideApp());
}

class TourGuideApp extends StatelessWidget {
  const TourGuideApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tour Guide',
      theme: ThemeData.dark(),
      home: const SplashScreen(),
    );
  }
}

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _navigateToHome();
  }

  Future<void> _navigateToHome() async {
    await Future.delayed(const Duration(seconds: 3));
    if (mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const HomeScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1a0a2e),
      body: SizedBox.expand(
        child: Image.asset('assets/Tour_Guide.png', fit: BoxFit.contain),
      ),
    );
  }
}

// ─── Hierarchy level display names ───────────────────────────────────────────

const List<Map<String, String>> _kHierarchyLevels = [
  {'key': 'nation',       'label': 'Nation'},
  {'key': 'region',       'label': 'Region'},
  {'key': 'state',        'label': 'State'},
  {'key': 'metro_area',   'label': 'Metro Area'},
  {'key': 'county',       'label': 'County'},
  {'key': 'town',         'label': 'Town'},
  {'key': 'neighborhood', 'label': 'Neighborhood'},
  {'key': 'landmark',     'label': 'Landmark'},
];

// ─── HomeScreen ───────────────────────────────────────────────────────────────

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {

  // ── Settings + device ──────────────────────────────────────────────────────
  AppSettings _settings = AppSettings();
  String _debugMessage = '';
  String _deviceId = '';

  // ── Mode ───────────────────────────────────────────────────────────────────
  bool _simulationMode = false;

  // ── Location state ──────────────────────────────────────────────────────────
  String _locationText = 'Detecting location...';
  String _currentLocationName = '';
  Map<String, dynamic>? _currentLocationData;
  Timer? _pingTimer;

  // ── Hierarchy diagnostic state ─────────────────────────────────────────────
  Map<String, dynamic>? _currentHierarchy;
  Map<String, dynamic>? _previousHierarchy;
  List<String> _changedLevels = [];

  // ── Narration state (GPS mode) ─────────────────────────────────────────────
  bool _isTracking = false;
  bool _isFetching = false;
  bool _isLoadingNarration = false;

  // ── Simulation state ────────────────────────────────────────────────────────
  final TextEditingController _startAddressCtrl = TextEditingController();
  final TextEditingController _endAddressCtrl   = TextEditingController();
  List<Map<String, double>> _routeWaypoints     = [];
  int  _waypointIndex    = 0;
  bool _isLoadingRoute   = false;
  bool _simulationRunning = false;

  // ── Shared ─────────────────────────────────────────────────────────────────
  final AudioPlayer _audioPlayer = AudioPlayer();

  static const Duration _pingInterval = Duration(seconds: 15);
  static const String _backendBase = 'https://tour-guide-backend-production.up.railway.app';

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _startLocationTracking();
  }

  @override
  void dispose() {
    _pingTimer?.cancel();
    _audioPlayer.dispose();
    _startAddressCtrl.dispose();
    _endAddressCtrl.dispose();
    super.dispose();
  }

  // ─── Settings + device ID load ───────────────────────────────────────────

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    var deviceId = prefs.getString('device_id') ?? '';
    if (deviceId.isEmpty) {
      deviceId = const Uuid().v4();
      await prefs.setString('device_id', deviceId);
    }
    final settings = await AppSettings.load();
    if (mounted) {
      setState(() {
        _settings = settings;
        _deviceId = deviceId;
      });
    }
  }

  // ─── Permissions ────────────────────────────────────────────────────────────

  Future<bool> _requestLocationPermission() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return false;
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return false;
    }
    if (permission == LocationPermission.deniedForever) return false;
    return true;
  }

  // ─── GPS location tracking ───────────────────────────────────────────────────

  Future<void> _startLocationTracking() async {
    final hasPermission = await _requestLocationPermission();
    if (!hasPermission) {
      setState(() => _locationText = 'Location permission required');
      return;
    }

    // Initial ping immediately on launch
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );
      await _handleLocationUpdate(position.latitude, position.longitude);
    } catch (e) {
      debugPrint('Initial position error: $e');
    }

    // Then ping every 15 seconds
    _pingTimer = Timer.periodic(_pingInterval, (_) async {
      if (_simulationMode) return; // don't GPS-ping while simulating
      try {
        final position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
        );
        await _handleLocationUpdate(position.latitude, position.longitude);
      } catch (e) {
        debugPrint('Ping timer error: $e');
      }
    });
  }

  // ─── Core location update handler (GPS and simulation share this) ────────────

  Future<void> _handleLocationUpdate(double lat, double lng) async {
    final pingData = await _ping(lat, lng);
    if (pingData == null) return;

    final newLocationName = pingData['location_name'] ?? '';
    _debug('Ping: $newLocationName | changed: ${(pingData['changed_levels'] as List?)?.join(', ')}');

    setState(() {
      _locationText = newLocationName.isNotEmpty ? newLocationName : 'Unknown location';
      _currentLocationData = pingData;
      _currentHierarchy = pingData['current'] != null
          ? Map<String, dynamic>.from(pingData['current'])
          : null;
      _previousHierarchy = pingData['previous'] != null
          ? Map<String, dynamic>.from(pingData['previous'])
          : null;
      _changedLevels = List<String>.from(pingData['changed_levels'] ?? []);
    });

    if (newLocationName != _currentLocationName && newLocationName.isNotEmpty) {
      _currentLocationName = newLocationName;

      if (_isTracking && !_isFetching) {
        await _fetchNarration(lat, lng, newLocationName);
      }
    }
  }

  // ─── /ping ───────────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>?> _ping(double lat, double lng, {bool forceNewSession = false}) async {
    if (_deviceId.isEmpty) return null;
    try {
      final response = await http.post(
        Uri.parse('$_backendBase/ping'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'device_id': _deviceId,
          'latitude': lat,
          'longitude': lng,
          'force_new_session': forceNewSession,
        }),
      ).timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) return jsonDecode(response.body);
    } catch (e) {
      debugPrint('Ping error: $e');
    }
    return null;
  }

  // ─── Audio ──────────────────────────────────────────────────────────────────

  Future<void> _playAudio(String base64Audio) async {
    try {
      final Uint8List audioBytes = base64Decode(base64Audio);
      final tempDir = await getTemporaryDirectory();
      final tempFile = File('${tempDir.path}/narration.mp3');
      await tempFile.writeAsBytes(audioBytes);
      await _audioPlayer.setFilePath(tempFile.path);
      await _audioPlayer.play();
    } catch (e) {
      debugPrint('Audio error: $e');
    }
  }

  // ─── Narration fetch ────────────────────────────────────────────────────────

  Future<void> _fetchNarration(double lat, double lng, String locationName) async {
    if (_isFetching) return;
    _isFetching = true;
    setState(() => _isLoadingNarration = true);
    _debug('Fetching narration for $locationName');

    try {
      final response = await http.post(
        Uri.parse('$_backendBase/narrate'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'latitude': lat,
          'longitude': lng,
          'mode': 'historical',
        }),
      ).timeout(const Duration(seconds: 90));

      if (!_isTracking) return;

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() => _isLoadingNarration = false);
        _debug('Narration ready — playing audio');
        await _audioPlayer.stop();
        await _playAudio(data['audio']);
      } else {
        setState(() => _isLoadingNarration = false);
      }
    } catch (e) {
      if (_isTracking) {
        setState(() => _isLoadingNarration = false);
        _debug('Narration error: $e');
      }
    } finally {
      _isFetching = false;
    }
  }

  // ─── Start / Stop narration (GPS mode) ───────────────────────────────────────

  void _startNarration() async {
    WakelockPlus.enable();
    setState(() => _isTracking = true);

    double lat, lng;
    if (_simulationMode && _routeWaypoints.isNotEmpty) {
      final wp = _routeWaypoints[_waypointIndex.clamp(0, _routeWaypoints.length - 1)];
      lat = wp['lat']!;
      lng = wp['lng']!;
    } else {
      try {
        final position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
        );
        lat = position.latitude;
        lng = position.longitude;
      } catch (e) {
        WakelockPlus.disable();
        setState(() => _isTracking = false);
        return;
      }
    }

    final locationName = _currentLocationName.isNotEmpty
        ? _currentLocationName
        : (_currentLocationData?['location_name'] ?? '');
    await _fetchNarration(lat, lng, locationName);
  }

  void _stopNarration() {
    _audioPlayer.stop();
    WakelockPlus.disable();
    _isFetching = false;
    setState(() {
      _isTracking = false;
      _isLoadingNarration = false;
    });
  }

  // ─── Mode switching ──────────────────────────────────────────────────────────

  void _switchMode(bool toSimulation) {
    if (_simulationMode == toSimulation) return;
    _pingTimer?.cancel();
    _audioPlayer.stop();
    setState(() {
      _simulationMode = toSimulation;
      _simulationRunning = false;
      _isTracking = false;
      _isLoadingNarration = false;
      _isFetching = false;
    });
    if (!toSimulation) {
      _startLocationTracking();
    }
  }

  // ─── Simulation ──────────────────────────────────────────────────────────────

  Future<void> _fetchRoute() async {
    final start = _startAddressCtrl.text.trim();
    final end = _endAddressCtrl.text.trim();
    if (start.isEmpty || end.isEmpty) return;

    setState(() {
      _isLoadingRoute = true;
      _routeWaypoints = [];
      _waypointIndex = 0;
      _locationText = 'Loading route...';
    });

    try {
      final response = await http.post(
        Uri.parse('$_backendBase/route'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'start_address': start,
          'end_address': end,
          'speed_mph': 45.0,
        }),
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final waypoints = (data['waypoints'] as List)
            .map<Map<String, double>>((w) => {
                  'lat': (w['lat'] as num).toDouble(),
                  'lng': (w['lng'] as num).toDouble(),
                })
            .toList();
        setState(() {
          _routeWaypoints = waypoints;
          _waypointIndex = 0;
          _locationText = '${waypoints.length} waypoints loaded';
        });
        _debug('Route: ${waypoints.length} waypoints from $start → $end');
      } else if (response.statusCode == 404) {
        setState(() => _locationText = 'Route not found');
      } else {
        setState(() => _locationText = 'Route error');
        _debug('Route error: HTTP ${response.statusCode}');
      }
    } catch (e) {
      setState(() => _locationText = 'Route error');
      debugPrint('Route fetch error: $e');
    } finally {
      setState(() => _isLoadingRoute = false);
    }
  }

  void _startSimulation() {
    if (_routeWaypoints.isEmpty) return;
    setState(() => _simulationRunning = true);
    _stepSimulation(); // fire first waypoint immediately
    _pingTimer = Timer.periodic(_pingInterval, (_) => _stepSimulation());
  }

  void _stopSimulation() {
    _pingTimer?.cancel();
    setState(() => _simulationRunning = false);
  }

  void _stepSimulation() {
    if (_waypointIndex >= _routeWaypoints.length) {
      _stopSimulation();
      setState(() => _locationText = 'Route complete');
      return;
    }
    final wp = _routeWaypoints[_waypointIndex];
    _waypointIndex++;
    _handleLocationUpdate(wp['lat']!, wp['lng']!);
  }

  // ─── Settings navigation ────────────────────────────────────────────────────

  void _openSettings() async {
    final updated = await Navigator.push<AppSettings>(
      context,
      MaterialPageRoute(
        builder: (context) => SettingsScreen(settings: _settings),
      ),
    );
    if (updated != null) {
      setState(() => _settings = updated);
      await updated.save();

      if (updated.forceNewSession) {
        try {
          double lat, lng;
          if (_simulationMode && _routeWaypoints.isNotEmpty) {
            final wp = _routeWaypoints[_waypointIndex.clamp(0, _routeWaypoints.length - 1)];
            lat = wp['lat']!;
            lng = wp['lng']!;
          } else {
            final position = await Geolocator.getCurrentPosition(
              locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
            );
            lat = position.latitude;
            lng = position.longitude;
          }
          await _ping(lat, lng, forceNewSession: true);
          _debug('New session started');
        } catch (e) {
          debugPrint('Force new session error: $e');
        }
      }
    }
  }

  // ─── Debug logging ───────────────────────────────────────────────────────────

  void _debug(String message) {
    if (_settings.debugMode) {
      setState(() => _debugMessage = message);
    }
  }

  // ─── UI ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            children: [
              _buildTopSection(),
              const SizedBox(height: 8),
              _buildHierarchyPanel(),
              _buildModeToggle(),
              if (_simulationMode) _buildSimulationControls(),
              _buildBottomSection(),
              if (_settings.debugMode)
                Container(
                  width: double.infinity,
                  color: Colors.black,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Text(
                    _debugMessage.isEmpty ? 'Debug mode on' : _debugMessage,
                    style: const TextStyle(color: Colors.yellow, fontSize: 11),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopSection() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Text(
        _locationText,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 28,
          fontWeight: FontWeight.bold,
        ),
        textAlign: TextAlign.center,
      ),
    );
  }

  // ─── Mode toggle ─────────────────────────────────────────────────────────────

  Widget _buildModeToggle() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Expanded(child: _buildToggleButton(label: 'GPS',      active: !_simulationMode, onTap: () => _switchMode(false))),
          const SizedBox(width: 8),
          Expanded(child: _buildToggleButton(label: 'SIMULATE', active:  _simulationMode, onTap: () => _switchMode(true))),
        ],
      ),
    );
  }

  Widget _buildToggleButton({required String label, required bool active, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: active ? Colors.blueGrey.withValues(alpha: 0.7) : Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: active ? Colors.blueGrey : Colors.white.withValues(alpha: 0.15),
          ),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: active ? Colors.white : Colors.white.withValues(alpha: 0.4),
            fontSize: 13,
            fontWeight: active ? FontWeight.bold : FontWeight.normal,
            letterSpacing: 1.0,
          ),
        ),
      ),
    );
  }

  // ─── Simulation controls ─────────────────────────────────────────────────────

  Widget _buildSimulationControls() {
    final hasRoute = _routeWaypoints.isNotEmpty;
    final canFetch = _startAddressCtrl.text.trim().isNotEmpty &&
        _endAddressCtrl.text.trim().isNotEmpty &&
        !_isLoadingRoute;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildAddressField(_startAddressCtrl, 'Start address'),
          const SizedBox(height: 8),
          _buildAddressField(_endAddressCtrl, 'End address'),
          const SizedBox(height: 8),
          ElevatedButton(
            onPressed: canFetch ? _fetchRoute : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: canFetch
                  ? Colors.blueGrey.withValues(alpha: 0.8)
                  : Colors.grey.withValues(alpha: 0.2),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: Text(
              _isLoadingRoute ? 'Loading route...' : 'Get Route',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
            ),
          ),
          if (hasRoute) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  'Step $_waypointIndex of ${_routeWaypoints.length}',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 11),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: LinearProgressIndicator(
                    value: _routeWaypoints.isEmpty
                        ? 0
                        : _waypointIndex / _routeWaypoints.length,
                    backgroundColor: Colors.white.withValues(alpha: 0.1),
                    color: Colors.blueGrey,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildAddressField(TextEditingController ctrl, String hint) {
    return TextField(
      controller: ctrl,
      style: const TextStyle(color: Colors.white, fontSize: 14),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.35)),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.08),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
      ),
      onChanged: (_) => setState(() {}),
    );
  }

  // ─── Hierarchy diagnostic panel ──────────────────────────────────────────────

  Widget _buildHierarchyPanel() {
    if (_currentHierarchy == null) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Row(
              children: [
                const SizedBox(width: 88),
                Expanded(
                  child: Text(
                    'PREVIOUS',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.4),
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    'CURRENT',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.4),
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(color: Colors.white12, height: 1),
          ..._kHierarchyLevels.map((level) => _buildHierarchyRow(
            label: level['label']!,
            key: level['key']!,
          )),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  Widget _buildHierarchyRow({required String label, required String key}) {
    final current  = _currentHierarchy?[key]  as String? ?? '';
    final previous = _previousHierarchy?[key] as String? ?? '';
    final changed  = _changedLevels.contains(key);

    final rowColor   = changed ? Colors.amber.withValues(alpha: 0.12) : Colors.transparent;
    final valueColor = changed ? Colors.amber : Colors.white.withValues(alpha: 0.75);

    return Container(
      color: rowColor,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: Row(
              children: [
                if (changed)
                  const Padding(
                    padding: EdgeInsets.only(right: 4),
                    child: Icon(Icons.star, color: Colors.amber, size: 10),
                  )
                else
                  const SizedBox(width: 14),
                Text(
                  label,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Text(
              previous.isNotEmpty ? previous : '—',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 11),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (changed)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Icon(Icons.arrow_forward, color: Colors.amber.withValues(alpha: 0.7), size: 10),
            )
          else
            const SizedBox(width: 18),
          Expanded(
            child: Text(
              current.isNotEmpty ? current : '—',
              style: TextStyle(
                color: valueColor,
                fontSize: 11,
                fontWeight: changed ? FontWeight.bold : FontWeight.normal,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  // ─── Bottom buttons ───────────────────────────────────────────────────────────

  Widget _buildBottomSection() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (_simulationMode) ...[
            _buildButton(
              label: 'Start',
              color: Colors.green,
              onPressed: (!_simulationRunning && _routeWaypoints.isNotEmpty) ? _startSimulation : null,
            ),
            const SizedBox(width: 16),
            _buildButton(
              label: 'Stop',
              color: Colors.red,
              onPressed: _simulationRunning ? _stopSimulation : null,
            ),
          ] else ...[
            _buildButton(
              label: 'Play',
              color: Colors.green,
              onPressed: _isTracking ? null : _startNarration,
            ),
            const SizedBox(width: 16),
            _buildButton(
              label: 'Stop',
              color: Colors.red,
              onPressed: _isTracking ? _stopNarration : null,
            ),
          ],
          const SizedBox(width: 16),
          _buildButton(
            label: 'Settings',
            color: Colors.blueGrey,
            onPressed: _openSettings,
          ),
        ],
      ),
    );
  }

  Widget _buildButton({
    required String label,
    required Color color,
    VoidCallback? onPressed,
  }) {
    return ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: onPressed != null ? color.withValues(alpha: 0.85) : Colors.grey.withValues(alpha: 0.3),
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
        elevation: 4,
        shadowColor: Colors.black.withValues(alpha: 0.5),
      ),
      child: Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
    );
  }
}
