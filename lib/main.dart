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
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'settings.dart';
import 'auth_service.dart';
import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Firebase initialization — requires google-services.json (Android) and
  // GoogleService-Info.plist (iOS) plus 'flutterfire configure' to generate
  // lib/firebase_options.dart. If those files aren't present yet, Firebase
  // initializes without options (will fail silently for auth calls).
  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  } catch (_) {
    // fallback if options unavailable
  }
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

  // ── Mode / Navigation ──────────────────────────────────────────────────────
  bool _simulationMode = false;
  int _selectedIndex = 0;

  // ── Location state ──────────────────────────────────────────────────────────
  String _locationText = 'Detecting location...';
  double? _currentLat;
  double? _currentLng;
  Timer? _pingTimer;

  // ── Hierarchy diagnostic state ─────────────────────────────────────────────
  Map<String, dynamic>? _currentHierarchy;
  Map<String, dynamic>? _previousHierarchy;
  List<String> _changedLevels = [];

  // ── Narration state ────────────────────────────────────────────────────────
  String _activeSessionId = '';
  bool _isNarrating = false;
  bool _narrationPreparing = false; // true during the 800ms fade-before-audio window
  Timer? _narrationPollTimer;

  // ── Current narration display ──────────────────────────────────────────────
  String _currentSubject  = '';
  String _currentNarrator = '';
  String? _currentImageUrl;
  bool _showingNarration  = false; // true only while a narration is actively playing

  // ── Simulation state ────────────────────────────────────────────────────────
  final TextEditingController _startAddressCtrl = TextEditingController(text: 'Los Angeles, CA');
  final TextEditingController _endAddressCtrl   = TextEditingController(text: 'San Francisco, CA');
  final MapController _mapController = MapController();
  final MapController _displayMapController = MapController();
  List<Map<String, double>> _routeWaypoints     = [];
  int  _waypointIndex    = 0;
  bool _isLoadingRoute   = false;
  bool _simulationRunning = false;

  // ── Shared ─────────────────────────────────────────────────────────────────
  final AudioPlayer _audioPlayer = AudioPlayer();
  StreamSubscription<PlayerState>? _playerStateSub;

  // ── User preferences ────────────────────────────────────────────────────────
  String _prefDefaultState = 'MD';
  int    _prefMinScore      = 7;

  // ── Tour guides ─────────────────────────────────────────────────────────────
  List<TourGuide> _tourGuides = [];
  List<PromptVariant> _promptVariants = [];

  // ── Background music ────────────────────────────────────────────────────────
  final AudioPlayer _musicPlayer = AudioPlayer();
  StreamSubscription<PlayerState>? _musicStateSub;
  final List<String> _cachedTracks = [];
  int _musicTrackIndex = 0;
  double _musicVolume = 1.0;
  Timer? _musicFadeTimer;
  Timer? _musicDeepDuckTimer;
  bool _musicDucked = false;
  DateTime? _nextNarrationAllowedAt;

  static const Duration _pingInterval = Duration(seconds: 15);
  static const String _backendBase = 'https://tour-guide-backend-production.up.railway.app';

  @override
  void initState() {
    super.initState();
    _playerStateSub = _audioPlayer.playerStateStream.listen((_) {
      if (mounted) setState(() {});
    });
    _musicStateSub = _musicPlayer.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        _playNextMusicTrack();
      }
    });
    _initFirebaseAuth();    // anonymous sign-in + backend user sync
    _loadSettings();
    if (!_simulationMode) _startLocationTracking();
    _initMusicCache();      // pre-download tracks in background
    _fetchTourGuides();       // load guide list (with personality) from backend
    _fetchPromptVariants();   // load prompt variant templates from backend
  }

  @override
  void dispose() {
    _pingTimer?.cancel();
    _narrationPollTimer?.cancel();
    _audioPlayer.dispose();
    _playerStateSub?.cancel();
    _musicStateSub?.cancel();
    _authStateSub?.cancel();
    _musicFadeTimer?.cancel();
    _musicDeepDuckTimer?.cancel();
    _musicPlayer.dispose();
    _startAddressCtrl.dispose();
    _endAddressCtrl.dispose();
    _mapController.dispose();
    super.dispose();
  }

  // ─── Firebase auth ────────────────────────────────────────────────────────

  StreamSubscription<User?>? _authStateSub;

  void _initFirebaseAuth() {
    _authStateSub = AuthService.authStateChanges.listen((user) async {
      if (user != null) {
        // Sync user with backend (non-fatal)
        final token = await AuthService.getIdToken();
        if (token != null) _syncAuthWithBackend(token);
      } else {
        // No Firebase user — sign in anonymously
        try {
          await AuthService.signInAnonymously();
          // authStateChanges fires again with the anonymous user
        } catch (e) {
          debugPrint('Anonymous sign-in error: $e');
        }
      }
    });
  }

  Future<void> _syncAuthWithBackend(String idToken) async {
    if (_deviceId.isEmpty) return;
    try {
      final response = await http.post(
        Uri.parse('$_backendBase/auth/sync'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'device_id': _deviceId, 'id_token': idToken}),
      ).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        debugPrint('Auth sync OK: role=${data['role']}, method=${data['auth_method']}');
        // Fetch user preferences after a successful sync
        await _fetchUserPreferences(idToken);
      }
    } catch (e) {
      debugPrint('Auth sync error (non-fatal): $e');
    }
  }

  Future<void> _fetchUserPreferences(String idToken) async {
    try {
      final response = await http.get(
        Uri.parse('$_backendBase/user/preferences'),
        headers: {'Authorization': 'Bearer $idToken'},
      ).timeout(const Duration(seconds: 8));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final state = data['default_state'] as String? ?? 'MD';
        final score = (data['min_score'] as num?)?.toInt() ?? 7;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('pref_default_state', state);
        await prefs.setInt('pref_min_score', score);
        if (mounted) setState(() { _prefDefaultState = state; _prefMinScore = score; });
        debugPrint('Preferences loaded: state=$state, minScore=$score');
      }
    } catch (e) {
      debugPrint('Fetch preferences error (non-fatal): $e');
    }
  }

  Future<void> _saveUserPreferences({String? defaultState, int? minScore}) async {
    try {
      final token = await AuthService.getIdToken();
      if (token == null) return;
      final body = <String, dynamic>{};
      if (defaultState != null) body['default_state'] = defaultState;
      if (minScore != null) body['min_score'] = minScore;
      await http.patch(
        Uri.parse('$_backendBase/user/preferences'),
        headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $token'},
        body: jsonEncode(body),
      ).timeout(const Duration(seconds: 8));
      final prefs = await SharedPreferences.getInstance();
      if (defaultState != null) {
        await prefs.setString('pref_default_state', defaultState);
        if (mounted) setState(() => _prefDefaultState = defaultState);
      }
      if (minScore != null) {
        await prefs.setInt('pref_min_score', minScore);
        if (mounted) setState(() => _prefMinScore = minScore);
      }
    } catch (e) {
      debugPrint('Save preferences error (non-fatal): $e');
    }
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
    // Load cached preferences (updated after auth sync)
    final defaultState = prefs.getString('pref_default_state') ?? 'MD';
    final minScore     = prefs.getInt('pref_min_score') ?? 7;
    if (mounted) {
      setState(() {
        _settings         = settings;
        _deviceId         = deviceId;
        _prefDefaultState = defaultState;
        _prefMinScore     = minScore;
      });
    }
  }

  // ─── Tour guides ─────────────────────────────────────────────────────────────

  Future<void> _fetchTourGuides() async {
    try {
      final response = await http.get(Uri.parse('$_backendBase/tour-guides'))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final guides = (data['tour_guides'] as List)
            .map((g) => TourGuide.fromJson(g as Map<String, dynamic>))
            .toList();
        if (mounted) setState(() => _tourGuides = guides);
        // Cache for offline fallback
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('tourGuides', jsonEncode(guides.map((g) => g.toJson()).toList()));
      }
    } catch (e) {
      debugPrint('Tour guides fetch error: $e');
      // Load from cache if network unavailable
      try {
        final prefs = await SharedPreferences.getInstance();
        final cached = prefs.getString('tourGuides');
        if (cached != null && mounted) {
          final guides = (jsonDecode(cached) as List)
              .map((g) => TourGuide.fromJson(g as Map<String, dynamic>))
              .toList();
          setState(() => _tourGuides = guides);
        }
      } catch (_) {}
    }
  }

  Future<void> _fetchPromptVariants() async {
    try {
      final response = await http.get(Uri.parse('$_backendBase/prompt-variants'))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final variants = (data['variants'] as List)
            .map((v) => PromptVariant.fromJson(v as Map<String, dynamic>))
            .toList();
        if (mounted) setState(() => _promptVariants = variants);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('promptVariants', jsonEncode(variants.map((v) => v.toJson()).toList()));
      }
    } catch (e) {
      debugPrint('Prompt variants fetch error: $e');
      try {
        final prefs = await SharedPreferences.getInstance();
        final cached = prefs.getString('promptVariants');
        if (cached != null && mounted) {
          final variants = (jsonDecode(cached) as List)
              .map((v) => PromptVariant.fromJson(v as Map<String, dynamic>))
              .toList();
          setState(() => _promptVariants = variants);
        }
      } catch (_) {}
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

  Future<void> _handleLocationUpdate(double lat, double lng, {bool forceNewSession = false}) async {
    final pingData = await _ping(lat, lng, forceNewSession: forceNewSession);
    if (pingData == null) return;

    final newLocationName = pingData['location_name'] ?? '';
    final sessionId = pingData['session_id'] as String? ?? '';
    _debug('Ping: $newLocationName | changed: ${(pingData['changed_levels'] as List?)?.join(', ')}');

    setState(() {
      if (sessionId.isNotEmpty) _activeSessionId = sessionId;
      _locationText = newLocationName.isNotEmpty ? newLocationName : 'Unknown location';
      _currentLat = lat;
      _currentLng = lng;
      _currentHierarchy = pingData['current'] != null
          ? Map<String, dynamic>.from(pingData['current'])
          : null;
      _previousHierarchy = pingData['previous'] != null
          ? Map<String, dynamic>.from(pingData['previous'])
          : null;
      _changedLevels = List<String>.from(pingData['changed_levels'] ?? []);
    });
    try {
      _displayMapController.move(LatLng(lat, lng), _displayMapController.camera.zoom);
    } catch (_) {} // controller not yet attached to a widget

  }

  // ─── /ping ───────────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>?> _ping(double lat, double lng, {bool forceNewSession = false}) async {
    if (_deviceId.isEmpty) return null;
    try {
      // Include Firebase ID token so backend can link device → user
      final headers = <String, String>{'Content-Type': 'application/json'};
      final token = await AuthService.getIdToken();
      if (token != null) headers['Authorization'] = 'Bearer $token';

      final response = await http.post(
        Uri.parse('$_backendBase/ping'),
        headers: headers,
        body: jsonEncode({
          'device_id': _deviceId,
          'latitude': lat,
          'longitude': lng,
          'force_new_session': forceNewSession,
          'min_score_filter': _prefMinScore,
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

  // ─── Narration engine ────────────────────────────────────────────────────────

  /// Single dequeue attempt — returns true if audio was played.
  Future<bool> _dequeueAndPlay() async {
    if (_activeSessionId.isEmpty || !_isNarrating || _narrationPreparing) return false;
    _narrationPreparing = true; // lock out concurrent calls during HTTP request + setup
    try {
      final response = await http.post(
        Uri.parse('$_backendBase/narration/dequeue'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'session_id': _activeSessionId}),
      ).timeout(const Duration(seconds: 10));
      if (!_isNarrating) { _narrationPreparing = false; return false; }
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['available'] == true) {
          final subject  = data['subject']  as String? ?? '';
          final narrator = data['narrator'] as String? ?? '';
          setState(() {
            _currentSubject    = subject;
            _currentNarrator   = narrator;
            _currentImageUrl   = null;
            _showingNarration  = true;
          });
          _fetchWikipediaImage(subject);
          _musicDucked = true;
          _fadeMusicTo(0.05, milliseconds: 800);
          await Future.delayed(const Duration(milliseconds: 800));
          if (!_isNarrating) { _narrationPreparing = false; return false; }
          _musicDeepDuckTimer?.cancel();
          _musicDeepDuckTimer = Timer(const Duration(seconds: 7), () {
            _fadeMusicTo(0.0, milliseconds: 1500);
          });
          _debug('Playing: $subject');
          await _playAudio(data['audio'] as String);
          _narrationPreparing = false;
          return true;
        }
      }
    } catch (e) {
      _debug('Dequeue error: $e');
    }
    _narrationPreparing = false; // no content or error — release the lock
    return false;
  }

  Future<void> _fetchWikipediaImage(String subject) async {
    final encoded = Uri.encodeComponent(subject);
    final url = 'https://en.wikipedia.org/w/api.php'
        '?action=query&titles=$encoded&prop=pageimages'
        '&pithumbsize=800&format=json&redirects=1';
    try {
      final response = await http.get(
        Uri.parse(url),
        headers: {'User-Agent': 'TourGuideApp/1.0 (https://github.com/AmericanRenegade/tour-guide-backend)'},
      ).timeout(const Duration(seconds: 8));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final pages = (data['query']['pages'] as Map).values.first;
        final imageUrl = pages['thumbnail']?['source'] as String?;
        if (mounted && imageUrl != null) {
          setState(() => _currentImageUrl = imageUrl);
        }
      } else {
        _debug('Wikipedia image fetch failed: ${response.statusCode}');
      }
    } catch (e) {
      _debug('Wikipedia image error: $e');
    }
  }

  // ─── Background music ────────────────────────────────────────────────────────

  Future<void> _initMusicCache() async {
    try {
      final response = await http.get(
        Uri.parse('$_backendBase/music/tracks'),
      ).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return;
      final data = jsonDecode(response.body);
      final tracks = (data['tracks'] as List).cast<Map<String, dynamic>>();
      if (tracks.isEmpty) return;

      final appDir = await getApplicationDocumentsDirectory();
      final musicDir = Directory('${appDir.path}/music');
      await musicDir.create(recursive: true);

      for (final track in tracks) {
        final filename = track['filename'] as String;
        final localFile = File('${musicDir.path}/$filename');
        if (!await localFile.exists()) {
          final encoded = Uri.encodeComponent(filename);
          final trackResponse = await http.get(
            Uri.parse('$_backendBase/music/track/$encoded'),
          ).timeout(const Duration(seconds: 60));
          if (trackResponse.statusCode == 200) {
            await localFile.writeAsBytes(trackResponse.bodyBytes);
          }
        }
        if (await localFile.exists()) {
          _cachedTracks.add(localFile.path);
        }
      }
      debugPrint('Music: ${_cachedTracks.length} track(s) cached');
      if (mounted) setState(() {}); // refresh settings page track list
    } catch (e) {
      debugPrint('Music cache init error: $e');
    }
  }

  Future<void> _clearCachedTracks() async {
    try {
      _stopMusic();
      final appDir = await getApplicationDocumentsDirectory();
      final musicDir = Directory('${appDir.path}/music');
      if (await musicDir.exists()) {
        await musicDir.delete(recursive: true);
      }
      if (mounted) setState(() => _cachedTracks.clear());
      debugPrint('Music cache cleared');
    } catch (e) {
      debugPrint('Clear cache error: $e');
    }
  }

  Future<void> _startMusic() async {
    if (!_settings.musicEnabled) return;
    if (_cachedTracks.isEmpty) await _initMusicCache();
    if (_cachedTracks.isEmpty) return;
    _cachedTracks.shuffle();
    _musicTrackIndex = 0;
    _musicVolume = 1.0;
    try {
      await _musicPlayer.setVolume(1.0);
      await _musicPlayer.setFilePath(_cachedTracks[0]);
      await _musicPlayer.play();
    } catch (e) {
      debugPrint('Music start error: $e');
    }
  }

  void _stopMusic() {
    _musicFadeTimer?.cancel();
    _musicDeepDuckTimer?.cancel();
    _musicPlayer.stop();
    _musicVolume = 1.0;
  }

  Future<void> _playNextMusicTrack() async {
    if (_cachedTracks.isEmpty) return;
    _musicTrackIndex = (_musicTrackIndex + 1) % _cachedTracks.length;
    if (_musicTrackIndex == 0) _cachedTracks.shuffle();
    try {
      await _musicPlayer.setFilePath(_cachedTracks[_musicTrackIndex]);
      await _musicPlayer.play();
    } catch (e) {
      debugPrint('Music next track error: $e');
    }
  }

  void _fadeMusicTo(double target, {int milliseconds = 1000}) {
    _musicFadeTimer?.cancel();
    final startVolume = _musicVolume;
    const steps = 20;
    final stepDuration = Duration(milliseconds: milliseconds ~/ steps);
    final stepSize = (target - startVolume) / steps;
    int currentStep = 0;
    _musicFadeTimer = Timer.periodic(stepDuration, (timer) {
      currentStep++;
      if (currentStep >= steps) {
        _musicVolume = target;
        _musicPlayer.setVolume(target);
        timer.cancel();
      } else {
        _musicVolume = (_musicVolume + stepSize).clamp(0.0, 1.0);
        _musicPlayer.setVolume(_musicVolume);
      }
    });
  }

  void _restoreMusic() {
    _musicDeepDuckTimer?.cancel();
    _musicDucked = false;
    if (!_settings.musicEnabled) return;
    _fadeMusicTo(1.0, milliseconds: 2000); // ramp straight back up
    setState(() {
      _showingNarration = false;
      _currentImageUrl  = null; // clear stale image so map reappears
    });
  }

  void _startNarrationPoll() {
    _narrationPollTimer?.cancel();
    _narrationPollTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      // playing stays true even after audio finishes — check processingState too
      final audioIdle = !_audioPlayer.playing ||
          _audioPlayer.processingState == ProcessingState.completed ||
          _audioPlayer.processingState == ProcessingState.idle;
      if (!_isNarrating || !audioIdle) return;

      // Narration just ended — restore music unless we're mid-setup for the next one
      if (_musicDucked && !_narrationPreparing) {
        _restoreMusic();
        _nextNarrationAllowedAt = DateTime.now().add(const Duration(seconds: 7));
        return;
      }

      // Cooldown elapsed — try to dequeue the next narration
      final cooldownOk = _nextNarrationAllowedAt == null ||
          DateTime.now().isAfter(_nextNarrationAllowedAt!);
      if (cooldownOk) {
        await _dequeueAndPlay();
      }
    });
  }

  Future<void> _startNarration() async {
    WakelockPlus.enable();
    setState(() { _isNarrating = true; });
    if (_activeSessionId.isEmpty) {
      try {
        final position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
        );
        await _handleLocationUpdate(position.latitude, position.longitude);
      } catch (e) {
        debugPrint('Position error before narration: $e');
      }
    }
    _startNarrationPoll();
    _startMusic();
  }

  void _stopNarration() {
    _narrationPollTimer?.cancel();
    _musicDeepDuckTimer?.cancel();
    _narrationPreparing = false;
    _musicDucked = false;
    _audioPlayer.stop();
    _stopMusic();
    WakelockPlus.disable();
    setState(() {
      _isNarrating      = false;
      _showingNarration = false;
      _currentImageUrl  = null;
    });
  }

  // ─── Mode switching ──────────────────────────────────────────────────────────

  void _switchMode(bool toSimulation) {
    if (_simulationMode == toSimulation) return;
    _pingTimer?.cancel();
    _narrationPollTimer?.cancel();
    _audioPlayer.stop();
    _stopMusic();
    WakelockPlus.disable();
    setState(() {
      _simulationMode = toSimulation;
      _simulationRunning = false;
      _isNarrating = false;
    });
    if (!toSimulation) _startLocationTracking();
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

        // Reset all state for a fresh simulation
        setState(() {
          _routeWaypoints = waypoints;
          _waypointIndex = 0;
          _locationText = 'Setting up route...';
          _currentHierarchy = null;
          _previousHierarchy = null;
          _changedLevels = [];
          _currentSubject = '';
          _currentNarrator = '';
          _currentImageUrl = null;
        });

        // 1. Clear old narrations first (so the new session's intro isn't wiped)
        try {
          await http.post(Uri.parse('$_backendBase/debug/clear-narrations'));
        } catch (e) {
          _debug('Clear narrations error: $e');
        }

        // 2. Ping the starting waypoint with forceNewSession to create a fresh session
        //    and generate the intro narration
        await _handleLocationUpdate(
          waypoints.first['lat']!,
          waypoints.first['lng']!,
          forceNewSession: true,
        );

        _debug('Route: ${waypoints.length} waypoints from $start → $end — new session ready');
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
    setState(() {
      _simulationRunning = true;
      _isNarrating = true;
    });
    WakelockPlus.enable();
    _startNarrationPoll();
    _startMusic();
    _stepSimulationWithIntro();
    _pingTimer = Timer.periodic(_pingInterval, (_) => _stepSimulation());
  }

  Future<void> _stepSimulationWithIntro() async {
    if (_waypointIndex >= _routeWaypoints.length) return;
    final wp = _routeWaypoints[_waypointIndex];
    _waypointIndex++;
    _panMapToWaypoint(wp);
    await _handleLocationUpdate(wp['lat']!, wp['lng']!);
  }

  void _stopSimulation() {
    _pingTimer?.cancel();
    _narrationPollTimer?.cancel();
    _musicDeepDuckTimer?.cancel();
    _narrationPreparing = false;
    _musicDucked = false;
    _audioPlayer.stop();
    _stopMusic();
    WakelockPlus.disable();
    setState(() {
      _simulationRunning = false;
      _isNarrating       = false;
      _showingNarration  = false;
      _currentImageUrl   = null;
    });
  }

  void _panMapToWaypoint(Map<String, double> wp) {
    try {
      _mapController.move(LatLng(wp['lat']!, wp['lng']!), 10);
    } catch (_) {}
  }

  void _stepSimulation() {
    if (_waypointIndex >= _routeWaypoints.length) {
      _stopSimulation();
      setState(() => _locationText = 'Route complete');
      return;
    }
    final wp = _routeWaypoints[_waypointIndex];
    _waypointIndex++;
    _panMapToWaypoint(wp);
    _handleLocationUpdate(wp['lat']!, wp['lng']!);
  }

  // ─── Settings change handler ─────────────────────────────────────────────────

  Future<void> _onSettingsChanged(AppSettings updated) async {
    final wasMusic = _settings.musicEnabled;
    setState(() {
      _settings = updated;
      // If debug mode turned off while on Admin tab (index 4), return to Now Playing
      if (!updated.debugMode && _selectedIndex >= 4) {
        _selectedIndex = 0;
      }
    });
    await updated.save();

    // Live-respond to music toggle
    if (wasMusic && !updated.musicEnabled) {
      _stopMusic();
    } else if (!wasMusic && updated.musicEnabled && (_isNarrating || _simulationRunning) && !_musicDucked) {
      _startMusic();
    }

    if (updated.forceNewSession) {
      setState(() => _settings.forceNewSession = false);
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

  // ─── Debug logging ───────────────────────────────────────────────────────────

  void _debug(String message) {
    if (_settings.debugMode) {
      setState(() => _debugMessage = message);
    }
  }

  // ─── UI ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final showAdmin = _settings.debugMode;
    final pages = [
      _buildNowPlayingPage(),
      _buildTourGuidesPage(),
      _buildSimulatePage(),
      _buildSettingsPage(),
      if (showAdmin) _buildAdminPage(),
    ];
    return Scaffold(
      backgroundColor: _cream,
      body: SafeArea(
        child: IndexedStack(index: _selectedIndex, children: pages),
      ),
      bottomNavigationBar: _buildBottomNav(showAdmin),
    );
  }

  Widget _buildBottomNav(bool showAdmin) {
    return BottomNavigationBar(
      currentIndex: _selectedIndex,
      onTap: (i) => setState(() => _selectedIndex = i),
      type: BottomNavigationBarType.fixed,
      backgroundColor: _cream,
      selectedItemColor: _green,
      unselectedItemColor: Colors.black38,
      items: [
        const BottomNavigationBarItem(icon: Icon(Icons.headphones_rounded), label: 'Now Playing'),
        const BottomNavigationBarItem(icon: Icon(Icons.people_rounded), label: 'Tour Guides'),
        const BottomNavigationBarItem(icon: Icon(Icons.map_outlined), label: 'Simulate'),
        const BottomNavigationBarItem(icon: Icon(Icons.settings_rounded), label: 'Settings'),
        if (showAdmin)
          const BottomNavigationBarItem(
              icon: Icon(Icons.admin_panel_settings_rounded), label: 'Admin'),
      ],
    );
  }

  // ─── Page 0: Now Playing display ────────────────────────────────────────────

  static const Color _green  = Color(0xFF3DAA74);
  static const Color _amber  = Color(0xFFF09840);
  static const Color _cream  = Color(0xFFF5EDD8);

  Widget _buildNowPlayingPage() {
    // mapMode: between narrations / idle — show live map
    // narration active but no image: show "no image" placeholder
    // narration active with image: show Wikipedia image
    final bool mapMode = !_showingNarration;

    final String topicLabel;
    final String subjectText;
    if (mapMode) {
      topicLabel  = 'NOW EXPLORING';
      subjectText = (_currentHierarchy != null && !_locationText.contains('...') && !_locationText.contains('waypoints'))
          ? _locationText
          : 'Ready to Explore';
    } else {
      topicLabel  = 'NEARBY LANDMARK';
      subjectText = _currentSubject.isNotEmpty ? _currentSubject : 'Ready to Explore';
    }

    final bool isActive     = _simulationMode ? _simulationRunning : _isNarrating;
    final bool audioPlaying = isActive &&
        _audioPlayer.playing &&
        _audioPlayer.processingState != ProcessingState.completed &&
        _audioPlayer.processingState != ProcessingState.idle;

    VoidCallback? startAction;
    if (_simulationMode) {
      startAction = _routeWaypoints.isNotEmpty ? _startSimulation : null;
    } else {
      startAction = _startNarration;
    }
    final VoidCallback stopAction;
    if (_simulationMode) {
      stopAction = () {
        _stopSimulation();
        setState(() => _selectedIndex = 2);
      };
    } else {
      stopAction = _stopNarration;
    }

    return Container(
      color: _cream,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ──────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
            child: Row(
              children: [
                const Icon(Icons.directions_bus_rounded, color: _green, size: 22),
                const SizedBox(width: 8),
                const Text(
                  'Tour Guides',
                  style: TextStyle(color: _green, fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),

          // ── Topic label ─────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 2),
            child: Text(
              topicLabel,
              style: const TextStyle(
                color: Colors.black54,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.5,
              ),
            ),
          ),

          // ── Subject name ────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Text(
              subjectText,
              style: const TextStyle(
                color: Colors.black,
                fontSize: 32,
                fontWeight: FontWeight.bold,
                height: 1.1,
              ),
            ),
          ),

          // ── Image card / Map ─────────────────────────────────────────────
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFFE8DFC8),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.12),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (mapMode)
                        _buildDisplayMap()
                      else if (_currentImageUrl != null)
                        Image.network(
                          _currentImageUrl!,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => _buildNoImagePlaceholder(),
                        )
                      else
                        _buildNoImagePlaceholder(),
                      if (!mapMode && _currentNarrator.isNotEmpty)
                        Positioned(
                          left: 12, right: 12, bottom: 12,
                          child: _buildNarratorOverlay(),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // ── Start / Stop Tour + Skip row ────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
            child: Row(
              children: [
                if (isActive) ...[
                  // Tour active: Skip is primary (large), Stop is secondary (small, red)
                  Expanded(
                    flex: 3,
                    child: SizedBox(
                      height: 56,
                      child: ElevatedButton.icon(
                        onPressed: audioPlaying ? _skipNarration : null,
                        icon: const Icon(Icons.skip_next_rounded, size: 22),
                        label: const Text('Skip', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _amber,
                          foregroundColor: Colors.white,
                          disabledBackgroundColor: Colors.grey.shade300,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                          elevation: 3,
                          shadowColor: _amber.withValues(alpha: 0.4),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    height: 56,
                    width: 80,
                    child: ElevatedButton(
                      onPressed: stopAction,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red.shade600,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                        elevation: 0,
                      ),
                      child: const Icon(Icons.stop_rounded, size: 26),
                    ),
                  ),
                ] else ...[
                  // Tour inactive: Start is primary (large), Skip is disabled (small)
                  Expanded(
                    flex: 3,
                    child: SizedBox(
                      height: 56,
                      child: ElevatedButton.icon(
                        onPressed: startAction,
                        icon: const Icon(Icons.play_arrow_rounded, size: 22),
                        label: const Text('Start Tour', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _green,
                          foregroundColor: Colors.white,
                          disabledBackgroundColor: Colors.grey.shade300,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                          elevation: 3,
                          shadowColor: _green.withValues(alpha: 0.4),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    height: 56,
                    width: 80,
                    child: ElevatedButton(
                      onPressed: null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _amber,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: Colors.grey.shade300,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                        elevation: 0,
                      ),
                      child: const Icon(Icons.skip_next_rounded, size: 26),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNoImagePlaceholder() {
    return Container(
      color: const Color(0xFFE8DFC8),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.image_not_supported_rounded,
                size: 52, color: Colors.brown.withValues(alpha: 0.25)),
            const SizedBox(height: 10),
            Text(
              'No image available',
              style: TextStyle(
                color: Colors.brown.withValues(alpha: 0.4),
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNarratorOverlay() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(50),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          // Avatar
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _green.withValues(alpha: 0.15),
            ),
            child: Center(
              child: Text(
                _currentNarrator.isNotEmpty ? _currentNarrator[0].toUpperCase() : '?',
                style: const TextStyle(
                  fontSize: 18, fontWeight: FontWeight.bold, color: _green,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _currentNarrator,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 15, color: Colors.black87,
                  ),
                ),
                Row(
                  children: [
                    Container(
                      width: 7, height: 7,
                      decoration: const BoxDecoration(shape: BoxShape.circle, color: _green),
                    ),
                    const SizedBox(width: 5),
                    const Text(
                      'Telling a story...',
                      style: TextStyle(fontSize: 12, color: Colors.black54),
                    ),
                  ],
                ),
              ],
            ),
          ),
          // Speaker icon
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _amber.withValues(alpha: 0.15),
            ),
            child: const Icon(Icons.volume_up_rounded, color: _amber, size: 18),
          ),
        ],
      ),
    );
  }


  Widget _buildDisplayMap() {
    // Determine map center: use stored position, or first simulation waypoint, or default
    LatLng center;
    if (_currentLat != null && _currentLng != null) {
      center = LatLng(_currentLat!, _currentLng!);
    } else if (_routeWaypoints.isNotEmpty) {
      final wp = _routeWaypoints[_waypointIndex.clamp(0, _routeWaypoints.length - 1)];
      center = LatLng(wp['lat']!, wp['lng']!);
    } else {
      // No position yet — show placeholder
      return Container(
        color: const Color(0xFFE0D5BC),
        child: Center(
          child: Icon(Icons.map_rounded, size: 80, color: Colors.brown.withValues(alpha: 0.2)),
        ),
      );
    }

    return FlutterMap(
      mapController: _displayMapController,
      options: MapOptions(
        initialCenter: center,
        initialZoom: 13,
        interactionOptions: const InteractionOptions(flags: InteractiveFlag.none),
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}@2x.png',
          subdomains: const ['a', 'b', 'c', 'd'],
          userAgentPackageName: 'com.example.tour_guide',
        ),
        MarkerLayer(
          markers: [
            Marker(
              point: center,
              width: 22,
              height: 22,
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _green,
                  border: Border.all(color: Colors.white, width: 3),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 6),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SimpleAttributionWidget(
          source: Text('© OpenStreetMap contributors © CARTO',
              style: TextStyle(fontSize: 9)),
        ),
      ],
    );
  }

  // ─── Simulate page ───────────────────────────────────────────────────────────

  Widget _buildSimulatePage() {
    return Container(
      color: _cream,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
              child: Row(
                children: [
                  const Icon(Icons.directions_bus_rounded, color: _green, size: 22),
                  const SizedBox(width: 8),
                  const Text(
                    'Tour Guides',
                    style: TextStyle(color: _green, fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
            _buildTopSection(),
            _buildSimulationModeToggle(),
            if (_simulationMode) ...[
              _buildStatusBanner(),
              _buildSimulationControls(),
              _buildBottomSection(),
            ],
            if (_settings.debugMode)
              Container(
                margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.amber.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.amber.withValues(alpha: 0.3)),
                ),
                child: Text(
                  _debugMessage.isEmpty ? 'Debug mode on' : _debugMessage,
                  style: TextStyle(color: Colors.brown.shade700, fontSize: 11),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  // ─── Page 2: Settings ───────────────────────────────────────────────────────

  Widget _buildSettingsPage() {
    return SettingsContent(
      settings: _settings,
      onChanged: _onSettingsChanged,
      cachedMusicTracks: _cachedTracks,
      prefDefaultState: _prefDefaultState,
      prefMinScore: _prefMinScore,
      onSavePreferences: _saveUserPreferences,
    );
  }


  Widget _buildTopSection() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Text(
        _locationText,
        style: const TextStyle(
          color: Colors.black,
          fontSize: 28,
          fontWeight: FontWeight.bold,
          height: 1.1,
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
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 8, offset: const Offset(0, 2)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildAddressField(_startAddressCtrl, 'Start address'),
          const SizedBox(height: 8),
          _buildAddressField(_endAddressCtrl, 'End address'),
          const SizedBox(height: 10),
          ElevatedButton(
            onPressed: canFetch ? _fetchRoute : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: _green,
              foregroundColor: Colors.white,
              disabledBackgroundColor: Colors.grey.shade200,
              disabledForegroundColor: Colors.grey.shade400,
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              elevation: 0,
            ),
            child: Text(
              _isLoadingRoute ? 'Loading route...' : 'Get Route',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
            ),
          ),
          if (hasRoute) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Text(
                  'Step $_waypointIndex of ${_routeWaypoints.length}',
                  style: TextStyle(color: Colors.black54, fontSize: 11),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: _routeWaypoints.isEmpty
                          ? 0
                          : _waypointIndex / _routeWaypoints.length,
                      backgroundColor: Colors.black.withValues(alpha: 0.08),
                      color: _green,
                      minHeight: 6,
                    ),
                  ),
                ),
                if (_simulationRunning) ...[
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 28,
                    height: 28,
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      icon: Icon(Icons.skip_next, size: 20, color: _green),
                      tooltip: 'Advance one step',
                      onPressed: _stepSimulation,
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 10),
            _buildSimulationMap(),
          ],
        ],
      ),
    );
  }

  Widget _buildSimulationMap() {
    final waypoints = _routeWaypoints;
    if (waypoints.isEmpty) return const SizedBox.shrink();

    final polylinePoints = waypoints.map((w) => LatLng(w['lat']!, w['lng']!)).toList();
    final currentIdx = (_waypointIndex - 1).clamp(0, waypoints.length - 1);
    final currentPos = polylinePoints[currentIdx];

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        height: 200,
        child: FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: polylinePoints[waypoints.length ~/ 2],
            initialZoom: 7,
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}@2x.png',
              subdomains: const ['a', 'b', 'c', 'd'],
              userAgentPackageName: 'com.example.tour_guide',
            ),
            PolylineLayer(
              polylines: [
                Polyline(
                  points: polylinePoints,
                  strokeWidth: 4,
                  color: Colors.black.withValues(alpha: 0.15),
                ),
                if (currentIdx > 0)
                  Polyline(
                    points: polylinePoints.sublist(0, currentIdx + 1),
                    strokeWidth: 4,
                    color: _green.withValues(alpha: 0.85),
                  ),
              ],
            ),
            MarkerLayer(
              markers: [
                Marker(
                  point: polylinePoints.first,
                  width: 14, height: 14,
                  child: Container(
                    decoration: const BoxDecoration(color: _green, shape: BoxShape.circle),
                  ),
                ),
                Marker(
                  point: polylinePoints.last,
                  width: 14, height: 14,
                  child: Container(
                    decoration: BoxDecoration(color: _amber, shape: BoxShape.circle),
                  ),
                ),
                Marker(
                  point: currentPos,
                  width: 18, height: 18,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      border: Border.all(color: _green, width: 3),
                      boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.25), blurRadius: 4)],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAddressField(TextEditingController ctrl, String hint) {
    return TextField(
      controller: ctrl,
      style: const TextStyle(color: Colors.black87, fontSize: 14),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Colors.black38),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        filled: true,
        fillColor: const Color(0xFFF0EBE0),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
      ),
      onChanged: (_) => setState(() {}),
    );
  }

  // ─── Tour Guides page ─────────────────────────────────────────────────────────

  Widget _buildTourGuidesPage() {
    return TourGuidesScreen(
      guides: _tourGuides,
      onRefresh: _fetchTourGuides,
    );
  }

  // ─── Admin page ───────────────────────────────────────────────────────────────

  Widget _buildAdminPage() {
    return AdminContent(
      tourGuides: _tourGuides,
      onRefreshTourGuides: _fetchTourGuides,
      promptVariants: _promptVariants,
      onRefreshPromptVariants: _fetchPromptVariants,
      onClearTracks: _clearCachedTracks,
      currentHierarchy: _currentHierarchy,
      previousHierarchy: _previousHierarchy,
      changedLevels: _changedLevels,
    );
  }

  // ─── Simulation mode toggle ───────────────────────────────────────────────────

  Widget _buildSimulationModeToggle() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 8, offset: const Offset(0, 2)),
        ],
      ),
      child: SwitchListTile(
        value: _simulationMode,
        onChanged: _switchMode,
        title: const Text('Simulation Mode', style: TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(
          _simulationMode
              ? 'GPS paused — using simulated route'
              : 'GPS active — real location tracking',
        ),
        activeThumbColor: _green,
        contentPadding: EdgeInsets.zero,
      ),
    );
  }

  // ─── Status banner (Simulate page) ───────────────────────────────────────────

  Widget _buildStatusBanner() {
    if (_simulationRunning) {
      return _buildBannerWidget('Simulation Active', Icons.science_rounded, Colors.amber);
    }
    return const SizedBox.shrink();
  }

  Widget _buildBannerWidget(String text, IconData icon, Color color) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Bottom buttons ───────────────────────────────────────────────────────────

  void _skipNarration() async {
    _nextNarrationAllowedAt = null; // explicit skip bypasses cooldown
    _musicDeepDuckTimer?.cancel();
    _audioPlayer.stop();
    final found = await _dequeueAndPlay();
    if (!found) _restoreMusic();
  }

  Widget _buildBottomSection() {
    final bool audioPlaying = _isNarrating &&
        _audioPlayer.playing &&
        _audioPlayer.processingState != ProcessingState.completed &&
        _audioPlayer.processingState != ProcessingState.idle;
    final bool isActive = _simulationRunning;
    final VoidCallback? startAction =
        _routeWaypoints.isNotEmpty ? _startSimulation : null;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: SizedBox(
              height: 52,
              child: ElevatedButton.icon(
                onPressed: isActive ? _stopSimulation : startAction,
                icon: Icon(isActive ? Icons.stop_rounded : Icons.play_arrow_rounded, size: 20),
                label: Text(
                  isActive ? 'Stop Simulation' : 'Start Simulation',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _green,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: Colors.grey.shade200,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
                  elevation: 0,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: SizedBox(
              height: 52,
              child: ElevatedButton.icon(
                onPressed: audioPlaying ? _skipNarration : null,
                icon: const Icon(Icons.skip_next_rounded, size: 20),
                label: const Text('Skip', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _amber,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: Colors.grey.shade200,
                  disabledForegroundColor: Colors.grey.shade400,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
                  elevation: 0,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
