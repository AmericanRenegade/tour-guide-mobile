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

  // ── Location + image state (always running) ────────────────────────────────
  String _locationText = 'Detecting location...';
  bool _isLoadingImage = false;
  Uint8List? _currentImage;
  String _currentLocationName = '';
  Map<String, dynamic>? _currentLocationData;
  Position? _lastImagePosition;
  StreamSubscription<Position>? _locationStream;

  // ── Hierarchy diagnostic state ─────────────────────────────────────────────
  Map<String, dynamic>? _currentHierarchy;
  Map<String, dynamic>? _previousHierarchy;
  List<String> _changedLevels = [];

  // ── Narration state (Start/Stop controlled) ────────────────────────────────
  bool _isTracking = false;
  bool _isFetching = false;
  bool _isLoadingNarration = false;
  Position? _lastNarrationPosition;
  String _lastNarrationLocationName = '';

  // ── Shared ─────────────────────────────────────────────────────────────────
  final AudioPlayer _audioPlayer = AudioPlayer();

  static const double _minMilesBetweenChecks = 0.25;
  static const double _metersPerMile = 1609.34;
  static const String _backendBase = 'https://tour-guide-backend-production.up.railway.app';

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _startLocationTracking();
  }

  @override
  void dispose() {
    _locationStream?.cancel();
    _audioPlayer.dispose();
    super.dispose();
  }

  // ─── Settings + device ID load ───────────────────────────────────────────

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    // Load or generate device ID
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

  // ─── Always-on location + image tracking ────────────────────────────────────

  Future<void> _startLocationTracking() async {
    final hasPermission = await _requestLocationPermission();
    if (!hasPermission) {
      setState(() => _locationText = 'Location permission required');
      return;
    }

    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );
      await _handleLocationUpdate(position, isInitial: true);
    } catch (e) {
      debugPrint('Initial position error: $e');
    }

    _locationStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 100,
      ),
    ).listen((Position position) async {
      await _handleLocationUpdate(position);
    });
  }

  Future<void> _handleLocationUpdate(Position position, {bool isInitial = false}) async {
    if (!isInitial && _lastImagePosition != null) {
      final distanceInMeters = Geolocator.distanceBetween(
        _lastImagePosition!.latitude,
        _lastImagePosition!.longitude,
        position.latitude,
        position.longitude,
      );
      if (distanceInMeters / _metersPerMile < _minMilesBetweenChecks) return;
    }

    final pingData = await _ping(position);
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
      _lastImagePosition = position;
      await _fetchImage(pingData);

      if (_isTracking && !_isFetching) {
        _lastNarrationPosition = position;
        await _fetchNarration(position, newLocationName);
      }
    } else {
      _lastImagePosition = position;
    }
  }

  // ─── /ping ───────────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>?> _ping(Position position, {bool forceNewSession = false}) async {
    if (_deviceId.isEmpty) return null;
    try {
      final response = await http.post(
        Uri.parse('$_backendBase/ping'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'device_id': _deviceId,
          'latitude': position.latitude,
          'longitude': position.longitude,
          'force_new_session': forceNewSession,
        }),
      ).timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) return jsonDecode(response.body);
    } catch (e) {
      debugPrint('Ping error: $e');
    }
    return null;
  }

  // ─── Image fetch ─────────────────────────────────────────────────────────────

  Future<void> _fetchImage(Map<String, dynamic> locationData) async {
    setState(() => _isLoadingImage = true);
    _debug('Fetching image for ${locationData["location_name"]}');
    try {
      final response = await http.post(
        Uri.parse('$_backendBase/image'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'latitude': 0.0,
          'longitude': 0.0,
          'location_name': locationData['location_name'] ?? '',
          'narration_focus': locationData['narration_focus'] ?? '',
          'locality': locationData['locality'] ?? '',
          'sublocality': locationData['sublocality'] ?? '',
          'county': locationData['county'] ?? '',
          'state': locationData['state'] ?? '',
        }),
      ).timeout(const Duration(seconds: 60));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() => _currentImage = base64Decode(data['image'] as String));
      } else {
        _debug('Image error: HTTP ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('Image fetch error: $e');
    } finally {
      setState(() => _isLoadingImage = false);
    }
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

  Future<void> _fetchNarration(Position position, String locationName) async {
    if (_isFetching) return;
    _isFetching = true;
    setState(() => _isLoadingNarration = true);
    _debug('Fetching narration for $locationName');

    try {
      final response = await http.post(
        Uri.parse('$_backendBase/narrate'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'latitude': position.latitude,
          'longitude': position.longitude,
          'mode': 'historical',
        }),
      ).timeout(const Duration(seconds: 90));

      if (!_isTracking) return;

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          _lastNarrationPosition = position;
          _lastNarrationLocationName = locationName;
          _isLoadingNarration = false;
        });
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

  // ─── Start / Stop narration ──────────────────────────────────────────────────

  void _startNarration() async {
    WakelockPlus.enable();
    setState(() => _isTracking = true);

    Position position;
    try {
      position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );
    } catch (e) {
      return;
    }

    final locationName = _currentLocationName.isNotEmpty
        ? _currentLocationName
        : (_currentLocationData?['location_name'] ?? '');

    _lastNarrationPosition = position;
    _lastNarrationLocationName = locationName;
    await _fetchNarration(position, locationName);
  }

  void _stopNarration() {
    _audioPlayer.stop();
    WakelockPlus.disable();
    _isFetching = false;
    setState(() {
      _isTracking = false;
      _isLoadingNarration = false;
      _lastNarrationPosition = null;
      _lastNarrationLocationName = '';
    });
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
        // Get current position and ping with force_new_session flag
        try {
          final position = await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
          );
          await _ping(position, forceNewSession: true);
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
        child: Column(
          children: [
            _buildTopSection(),
            const SizedBox(height: 12),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: _buildImageCard(),
                ),
              ),
            ),
            const SizedBox(height: 12),
            _buildHierarchyPanel(),
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
    );
  }

  Widget _buildImageCard() {
    if (_currentImage != null) {
      return SizedBox.expand(
        child: Image.memory(_currentImage!, fit: BoxFit.cover),
      );
    }
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF1a0a2e), Color(0xFF0d1b2a)],
        ),
      ),
      child: Center(
        child: Text(
          _isLoadingImage ? 'Loading image...' : 'Image will appear here',
          style: TextStyle(color: Colors.white.withValues(alpha:0.4), fontSize: 16),
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

  // ─── Hierarchy diagnostic panel ──────────────────────────────────────────────

  Widget _buildHierarchyPanel() {
    if (_currentHierarchy == null) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha:0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha:0.1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Row(
              children: [
                const SizedBox(width: 88),
                Expanded(
                  child: Text(
                    'PREVIOUS',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha:0.4),
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
                      color: Colors.white.withValues(alpha:0.4),
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
          // Level rows
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
    final current = _currentHierarchy?[key] as String? ?? '';
    final previous = _previousHierarchy?[key] as String? ?? '';
    final changed = _changedLevels.contains(key);

    final rowColor = changed ? Colors.amber.withValues(alpha:0.12) : Colors.transparent;
    final valueColor = changed ? Colors.amber : Colors.white.withValues(alpha:0.75);

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
                    color: Colors.white.withValues(alpha:0.5),
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
              style: TextStyle(
                color: Colors.white.withValues(alpha:0.4),
                fontSize: 11,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (changed)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Icon(Icons.arrow_forward, color: Colors.amber.withValues(alpha:0.7), size: 10),
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

  Widget _buildBottomSection() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
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
        backgroundColor: onPressed != null ? color.withValues(alpha:0.85) : Colors.grey.withValues(alpha:0.3),
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
        elevation: 4,
        shadowColor: Colors.black.withValues(alpha:0.5),
      ),
      child: Text(label, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
    );
  }
}
