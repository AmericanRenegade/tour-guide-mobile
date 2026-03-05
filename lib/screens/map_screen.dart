import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/active_location.dart';
import '../services/trip_service.dart';
import '../services/audio_service.dart';
import '../auth_service.dart';
import '../models/tour.dart';
import 'settings_screen.dart';
import 'tours_screen.dart';

// ── Map screen ──────────────────────────────────────────────────────────────

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  static const String _backendBase =
      'https://tour-guide-backend-production.up.railway.app';
  static const Color _teal = Color(0xFF0d9488);

  final MapController _mapController = MapController();
  final AudioService _audioService = AudioService();
  late final TripService _tripService;

  List<ActiveLocation> _locations = [];
  LatLng? _userPosition;
  bool _followingUser = true;
  StreamSubscription<Position>? _positionSub;
  bool _narrationVisible = false;
  bool _playingNarration = false;
  bool _narrationPaused = false;
  bool _skippingNarration = false;
  bool _narrationMuted = false;
  double _narrationSlideX = 0; // 0 = visible, 1 = slid off right

  // Trivia interstitial state
  bool _waitingForReveal = false;
  Completer<void>? _revealCompleter;
  int _countdownSeconds = 0;
  Timer? _countdownTimer;

  // "Up next" countdown state
  int _upNextSeconds = 0;
  Timer? _upNextTimer;
  bool _upNextVisible = false;
  double _narrationOpacity = 1.0;

  // Active tour
  Tour? _activeTour;

  // Nearby POIs card
  bool _nearbyVisible = false;
  final ScrollController _nearbyScrollController = ScrollController();

  // Learn / preview interrupt
  final AudioService _previewAudioService = AudioService();
  bool _learnCardVisible = false;
  bool _learnPlaying = false;
  String? _loadingLearnPoiId;

  // Version
  String _version = '';

  // Map style
  String _mapStyle = 'regular';

  @override
  void initState() {
    super.initState();
    _tripService = TripService();
    _tripService.addListener(_onTripChanged);
    _fetchLocations();
    _startLocationTracking();
    _syncAuth();
    _loadVersion();
    _loadActiveTour();
    _loadMapStyle();
  }

  Future<void> _loadMapStyle() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) setState(() => _mapStyle = prefs.getString('map_style') ?? 'regular');
  }

  @override
  void dispose() {
    _tripService.removeListener(_onTripChanged);
    _tripService.dispose();
    _positionSub?.cancel();
    _audioService.dispose();
    _previewAudioService.dispose();
    _nearbyScrollController.dispose();
    _countdownTimer?.cancel();
    _upNextTimer?.cancel();
    super.dispose();
  }

  // ── Locations ───────────────────────────────────────────────────────────────

  Future<void> _fetchLocations() async {
    try {
      final response = await http
          .get(Uri.parse('$_backendBase/locations/active'))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final list = (data['locations'] as List)
            .map((j) => ActiveLocation.fromJson(j as Map<String, dynamic>))
            .toList();
        if (mounted) setState(() => _locations = list);
      }
    } catch (e) {
      debugPrint('MapScreen fetchLocations error: $e');
    }
  }

  // ── GPS ─────────────────────────────────────────────────────────────────────

  Future<void> _startLocationTracking() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }
    if (permission == LocationPermission.deniedForever) return;

    _positionSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
      ),
    ).listen((pos) {
      final ll = LatLng(pos.latitude, pos.longitude);
      if (mounted) setState(() => _userPosition = ll);
      if (_followingUser) {
        try {
          _mapController.move(ll, _mapController.camera.zoom);
        } catch (_) {}
      }
    });
  }

  // ── Auth sync ──────────────────────────────────────────────────────────────

  Future<void> _syncAuth() async {
    final token = await AuthService.getIdToken();
    if (token == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final deviceId = prefs.getString('device_id') ?? '';
      await http
          .post(
            Uri.parse('$_backendBase/auth/sync'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'device_id': deviceId, 'id_token': token}),
          )
          .timeout(const Duration(seconds: 10));
    } catch (_) {}
  }

  // ── Version ───────────────────────────────────────────────────────────────

  Future<void> _loadVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (mounted) setState(() => _version = 'v${info.version}+${info.buildNumber}');
  }

  // ── Active tour ──────────────────────────────────────────────────────────

  Future<void> _loadActiveTour() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString('selected_tour_json');
    if (json != null && mounted) {
      final tour = Tour.fromJson(jsonDecode(json) as Map<String, dynamic>);
      setState(() => _activeTour = tour);
    } else if (mounted) {
      setState(() => _activeTour = null);
    }
  }

  // ── Map events ──────────────────────────────────────────────────────────

  void _onMapEvent(MapEvent event) {
    // Detect user-initiated drags and stop following
    if (event.source == MapEventSource.dragEnd ||
        event.source == MapEventSource.multiFingerEnd) {
      if (_followingUser) {
        setState(() => _followingUser = false);
      }
    }
  }

  // ── Narration ──────────────────────────────────────────────────────────────

  void _onTripChanged() {
    // Interrupt check runs regardless of trip state — Learn works even when
    // not exploring.
    if (_tripService.isInterrupting && !_learnPlaying) {
      _startLearnPlayback();
      return;
    }
    // Clean up narration card + audio when trip ends
    if (_tripService.tripState == TripState.idle) {
      if (_upNextSeconds > 0) _cancelUpNext();
      if (_playingNarration) {
        _audioService.stop();
        _playingNarration = false;
        _skippingNarration = false;
      }
      if (_narrationVisible) {
        _narrationVisible = false;
        _narrationOpacity = 0.0;
        _narrationSlideX = 0;
      }
      if (mounted) setState(() {});
      return;
    }
    if (_tripService.pendingNarration != null && !_playingNarration) {
      _playNarration();
    }
  }

  Future<void> _startLearnPlayback() async {
    _learnPlaying = true;
    // Stop the main narration — works whether audio has started or not.
    // The _cancelled flag in AudioService prevents play() from firing if we
    // stopped it mid-setup (the race condition fix).
    final wasNarrating = _playingNarration;
    await _audioService.stop();
    if (mounted) setState(() {
      _narrationPaused = false;
      _narrationVisible = false;
      _learnCardVisible = true;
    });
    final narration = _tripService.interruptNarration;
    if (narration != null) {
      await _previewAudioService.playBase64(narration.audioBase64);
    }
    _tripService.clearInterrupt();
    if (mounted) setState(() => _learnCardVisible = false);
    _learnPlaying = false;
    // Restart the narration that was interrupted (it's still at the front of
    // the queue since we never called advanceQueue).
    if (wasNarrating) {
      _playingNarration = false;
      if (mounted && _tripService.pendingNarration != null &&
          _tripService.tripState != TripState.idle) {
        _playNarration();
      }
    }
  }

  Future<void> _playNarration() async {
    final narration = _tripService.pendingNarration;
    if (narration == null) return;
    _playingNarration = true;
    _skippingNarration = false;
    _narrationPaused = false;
    // Cancel any running up-next banner
    _cancelUpNext();
    if (mounted) setState(() {
      _narrationVisible = true;
      _narrationOpacity = 1.0;
      _waitingForReveal = false;
      _countdownSeconds = 0;
    });

    if (narration.isTourProgress) {
      // Tour progress notification — show card briefly, no audio playback
      await Future.delayed(const Duration(seconds: 4));
    } else if (narration.isTriviaInterstitial) {
      // Trivia interstitial — pause between question and answer
      await _handleTriviaInterstitial(narration);
    } else {
      // Normal story / trivia question / trivia answer — play audio
      await _audioService.playBase64(narration.audioBase64);
    }

    // If a preview interrupt fired while we were playing (or setting up audio),
    // bail out — _startLearnPlayback() will restart us after the preview ends.
    if (_learnPlaying) return;

    // If trip ended while we were playing, _onTripChanged already cleaned up
    if (_tripService.tripState == TripState.idle) return;

    // Advance queue (confirms played to backend, removes from local queue)
    _tripService.advanceQueue();
    final wasSkipped = _skippingNarration;
    _skippingNarration = false;

    // If more narrations in queue and ready immediately, play next
    if (_tripService.pendingNarration != null) {
      // Reset slide position so new card appears
      if (mounted) {
        setState(() {
          _narrationSlideX = 0;
        });
      }
      if (!wasSkipped) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
      if (mounted && _tripService.pendingNarration != null) {
        _playingNarration = false;
        _playNarration();
        return;
      }
    }

    // No more narrations ready now — fade out the card
    if (mounted) setState(() => _narrationOpacity = 0.0);
    await Future.delayed(const Duration(milliseconds: 500));
    if (mounted) setState(() => _narrationVisible = false);
    _playingNarration = false;
    // Reset slideX after card has animated off-screen
    if (mounted) setState(() => _narrationSlideX = 0);

    // Check if there's an up-next narration behind a breathe gap
    _startUpNextCountdown();
  }

  void _startUpNextCountdown() {
    final remaining = _tripService.breatheSecondsRemaining;
    final upNext = _tripService.upNextNarration;
    if (remaining < 8 || upNext == null) return; // too short for banner
    if (!mounted) return;

    // Wait 1s pause after card fades before showing banner
    Future.delayed(const Duration(seconds: 1), () {
      if (!mounted || _playingNarration) return;
      final displaySeconds = _tripService.breatheSecondsRemaining - 1; // close 1s early
      if (displaySeconds <= 0) {
        _onTripChanged(); // gap already elapsed, trigger next
        return;
      }
      setState(() {
        _upNextSeconds = displaySeconds;
        _upNextVisible = true;
      });
      _upNextTimer?.cancel();
      _upNextTimer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (_upNextSeconds <= 1 || _playingNarration) {
          t.cancel();
          _upNextTimer = null;
          // Fade out banner
          if (mounted) setState(() => _upNextVisible = false);
          Future.delayed(const Duration(milliseconds: 500), () {
            if (mounted) setState(() => _upNextSeconds = 0);
            _onTripChanged(); // re-check pendingNarration
          });
          return;
        }
        if (mounted) setState(() => _upNextSeconds--);
      });
    });
  }

  void _cancelUpNext() {
    _upNextTimer?.cancel();
    _upNextTimer = null;
    _upNextSeconds = 0;
    _upNextVisible = false;
  }

  void _skipNarration() {
    // Slide card off to the right, then stop audio
    setState(() {
      _narrationSlideX = 1;
      _narrationPaused = false;
    });
    Future.delayed(const Duration(milliseconds: 300), () {
      _skippingNarration = true;
      _audioService.stop();
      // Don't reset _narrationSlideX here — _playNarration resets it
      // only when a new narration is ready or after the card is hidden.
    });
  }

  void _toggleNarrationPause() {
    if (_narrationPaused) {
      _audioService.resume();
    } else {
      _audioService.pause();
    }
    setState(() => _narrationPaused = !_narrationPaused);
  }

  void _toggleNarrationMute() {
    _audioService.toggleMute();
    setState(() => _narrationMuted = _audioService.isMuted);
  }

  /// Handle the trivia interstitial pause between question and answer.
  /// Reads user preference: 'auto' (countdown), 'manual' (tap), 'instant'.
  Future<void> _handleTriviaInterstitial(PendingNarration narration) async {
    final prefs = await SharedPreferences.getInstance();
    final mode = prefs.getString('trivia_reveal_mode') ?? 'auto';

    if (mode == 'instant') {
      // Skip interstitial entirely
      return;
    }

    if (mode == 'manual') {
      // Wait for user tap
      _revealCompleter = Completer<void>();
      if (mounted) setState(() => _waitingForReveal = true);
      await _revealCompleter!.future;
      _revealCompleter = null;
      if (mounted) setState(() => _waitingForReveal = false);
      return;
    }

    // Default: 'auto' countdown — user preference overrides server default
    final seconds = prefs.getInt('trivia_countdown_s') ?? narration.revealDelayS ?? 10;
    _revealCompleter = Completer<void>();
    if (mounted) setState(() {
      _waitingForReveal = true;
      _countdownSeconds = seconds;
    });

    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_countdownSeconds <= 1 || _skippingNarration) {
        timer.cancel();
        _countdownTimer = null;
        if (!(_revealCompleter?.isCompleted ?? true)) {
          _revealCompleter?.complete();
        }
        return;
      }
      if (mounted) setState(() => _countdownSeconds--);
    });

    await _revealCompleter!.future;
    _countdownTimer?.cancel();
    _countdownTimer = null;
    _revealCompleter = null;
    if (mounted) setState(() => _waitingForReveal = false);
  }

  /// Immediately reveal the trivia answer (tap-to-reveal or skip countdown).
  void _revealTriviaAnswer() {
    if (_revealCompleter != null && !_revealCompleter!.isCompleted) {
      _revealCompleter!.complete();
    }
  }

  // ── Center on user ─────────────────────────────────────────────────────────

  void _centerOnUser() {
    if (_userPosition == null) return;
    _followingUser = true;
    _mapController.move(_userPosition!, _mapController.camera.zoom);
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _tripService,
      builder: (context, _) => Scaffold(
        body: Stack(
          children: [
            _buildMap(),
            _buildUpNextBanner(),
            _buildNarrationCard(),
            _buildCenterButton(),
            _buildTripControls(),
            _buildVersionLabel(),
            _buildNearbyCard(),
            _buildLearnCard(),
            _buildPills(),
          ],
        ),
      ),
    );
  }

  Widget _buildMap() {
    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: const LatLng(38.9072, -77.0369), // DC default
        initialZoom: 12,
        onMapEvent: _onMapEvent,
      ),
      children: [
        TileLayer(
          urlTemplate: _mapStyle == 'light'
              ? 'https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}.png'
              : 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          subdomains: _mapStyle == 'light' ? const ['a', 'b', 'c', 'd'] : const [],
          userAgentPackageName: 'com.tourguide.app',
        ),
        // POI markers
        MarkerLayer(
          markers: _locations
              .map((loc) => Marker(
                    point: LatLng(loc.lat, loc.lng),
                    width: 12,
                    height: 12,
                    child: Container(
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: _teal,
                      ),
                    ),
                  ))
              .toList(),
        ),
        // User location
        if (_userPosition != null)
          MarkerLayer(
            markers: [
              Marker(
                point: _userPosition!,
                width: 16,
                height: 16,
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.blue,
                    border: Border.all(color: Colors.white, width: 2),
                    boxShadow: const [
                      BoxShadow(color: Color(0x443b82f6), blurRadius: 8),
                    ],
                  ),
                ),
              ),
            ],
          ),
      ],
    );
  }

  // ── "Up next" banner ───────────────────────────────────────────────────────

  Widget _buildUpNextBanner() {
    final upNext = _tripService.upNextNarration;
    final showBanner = _upNextSeconds > 0 && upNext != null && !_narrationVisible;
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
      bottom: showBanner && _upNextVisible ? 120 : -200,
      left: 16,
      right: 16,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 500),
        opacity: _upNextVisible ? 1.0 : 0.0,
        child: Card(
          elevation: 4,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          color: const Color(0xFFF8FAFC), // slate-50
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                // Guide avatar (36x36)
                _buildSmallGuideAvatar(upNext),
                const SizedBox(width: 10),
                // Story title + location
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Up next',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: Colors.grey.shade500,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        (upNext?.storyTitle ?? '').isNotEmpty
                            ? upNext!.storyTitle!
                            : upNext?.locationName ?? '',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if ((upNext?.locationName ?? '').isNotEmpty &&
                          (upNext?.storyTitle ?? '').isNotEmpty)
                        Text(
                          upNext!.locationName,
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // Countdown pill
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: _teal.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${_upNextSeconds}s',
                    style: const TextStyle(
                      color: _teal,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSmallGuideAvatar(PendingNarration? narration) {
    const double size = 36;
    if (narration?.guidePhotoUrl != null) {
      return ClipOval(
        child: Image.network(
          narration!.guidePhotoUrl!,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => Container(
            width: size,
            height: size,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Color(0xFFe0f2f1),
            ),
            child: const Icon(Icons.volume_up, color: _teal, size: 18),
          ),
        ),
      );
    }
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: Color(0xFFe0f2f1),
      ),
      child: const Icon(Icons.volume_up, color: _teal, size: 18),
    );
  }

  // ── Narration card ─────────────────────────────────────────────────────────

  Widget _buildNarrationCard() {
    final narration = _tripService.pendingNarration;
    final nearbyExtra = _nearbyVisible ? 236.0 : 0.0; // card 220 + spacing 16
    final maxCardHeight = MediaQuery.of(context).size.height
        - MediaQuery.of(context).padding.top - 8 - 40 - 8 // pills row
        - nearbyExtra
        - 48 - 120; // breathing room + trip controls
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
      bottom: _narrationVisible ? 120 : -600,
      left: 16,
      right: 16,
      child: AnimatedSlide(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInCubic,
        offset: Offset(_narrationSlideX * 1.5, 0),
        child: AnimatedOpacity(
          duration: Duration(milliseconds: _narrationSlideX > 0 ? 250 : 500),
          opacity: _narrationSlideX > 0 ? 0.0 : _narrationOpacity,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxCardHeight),
            child: Card(
              elevation: 8,
              margin: EdgeInsets.zero,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                children: [
                  // Top row: guide photo + title + narrator
                  Row(
                    children: [
                      _buildGuideAvatar(narration),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _MarqueeText(
                              text: _narrationTitle(narration),
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold, fontSize: 18),
                            ),
                            if ((narration?.locationName ?? '').isNotEmpty)
                              Text(
                                narration!.locationName,
                                style: const TextStyle(
                                    color: Colors.grey, fontSize: 14),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            if ((narration?.narrator ?? '').isNotEmpty &&
                                !(narration?.isTriviaInterstitial ?? false))
                              Text(
                                narration!.narrator,
                                style: const TextStyle(
                                    color: Colors.grey, fontSize: 14),
                              ),
                          ],
                        ),
                      ),
                      if (_tripService.totalNarrationsInBatch > 1)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: _teal.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            '${_tripService.currentPlayingIndex} of ${_tripService.totalNarrationsInBatch}',
                            style: const TextStyle(
                              color: _teal,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                    ],
                  ),
                  // Interstitial: countdown or tap-to-reveal
                  if (narration != null && narration.isTriviaInterstitial && _waitingForReveal) ...[
                    const SizedBox(height: 16),
                    if (_countdownSeconds > 0) ...[
                      Text(
                        'Answer in $_countdownSeconds s...',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF7C3AED), // purple-600
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    SizedBox(
                      width: double.infinity,
                      height: 44,
                      child: ElevatedButton.icon(
                        onPressed: _revealTriviaAnswer,
                        icon: const Icon(Icons.lightbulb_outline, size: 20),
                        label: Text(
                          _countdownSeconds > 0 ? 'Reveal Now' : 'Tap to Reveal Answer',
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF7C3AED), // purple-600
                          foregroundColor: Colors.white,
                          elevation: 0,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
                        ),
                      ),
                    ),
                  ],
                  // Controls row: Skip, Pause/Play, Mute, Feedback
                  // Hidden for tour progress and trivia interstitial
                  if (narration != null &&
                      !narration.isTourProgress &&
                      !narration.isTriviaInterstitial) ...[
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        // Skip button — yellow, prominent
                        SizedBox(
                          height: 38,
                          child: ElevatedButton.icon(
                            onPressed: _skipNarration,
                            icon: const Icon(Icons.skip_next, size: 20),
                            label: const Text('Skip', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFFBBF24), // amber-400
                              foregroundColor: Colors.black87,
                              elevation: 0,
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(19)),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        // Pause/Play button — larger
                        SizedBox(
                          width: 42,
                          height: 42,
                          child: IconButton(
                            padding: EdgeInsets.zero,
                            icon: Icon(
                              _narrationPaused ? Icons.play_circle_filled : Icons.pause_circle_filled,
                              color: _teal,
                              size: 38,
                            ),
                            onPressed: _toggleNarrationPause,
                          ),
                        ),
                        const SizedBox(width: 4),
                        // Mute button
                        SizedBox(
                          width: 42,
                          height: 42,
                          child: IconButton(
                            padding: EdgeInsets.zero,
                            icon: Icon(
                              _narrationMuted ? Icons.volume_off : Icons.volume_up,
                              color: Colors.grey.shade500,
                              size: 28,
                            ),
                            onPressed: _toggleNarrationMute,
                          ),
                        ),
                        const Spacer(),
                        // Feedback — blue hyperlink style
                        GestureDetector(
                          onTap: () {
                            // TODO: feedback mechanism
                          },
                          child: const Text(
                            'Feedback',
                            style: TextStyle(
                              fontSize: 15,
                              color: Color(0xFF2563EB), // blue-600
                              decoration: TextDecoration.underline,
                              decorationColor: Color(0xFF2563EB),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
          ),
        ),
      ),
    );
  }

  /// Title text for the narration card, varying by content type.
  String _narrationTitle(PendingNarration? narration) {
    if (narration == null) return '';
    if (narration.isTriviaQuestion) return 'Trivia';
    if (narration.isTriviaInterstitial) return 'Think About It...';
    if (narration.isTriviaAnswer) return 'Answer';
    if ((narration.storyTitle ?? '').isNotEmpty) return narration.storyTitle!;
    return narration.locationName;
  }

  Widget _buildGuideAvatar(PendingNarration? narration) {
    if (narration?.isTourProgress == true) {
      return Container(
        width: 60,
        height: 60,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: Color(0xFFFFF8E1),
        ),
        child: const Icon(Icons.emoji_events, color: Color(0xFFF9A825), size: 32),
      );
    }
    if (narration?.isTriviaQuestion == true) {
      return Container(
        width: 60,
        height: 60,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: Color(0xFFF3E8FF), // purple-100
        ),
        child: const Center(
          child: Text('❓', style: TextStyle(fontSize: 28)),
        ),
      );
    }
    if (narration?.isTriviaInterstitial == true) {
      return Container(
        width: 60,
        height: 60,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: Color(0xFFF3E8FF), // purple-100
        ),
        child: const Icon(Icons.timer, color: Color(0xFF7C3AED), size: 32),
      );
    }
    if (narration?.isTriviaAnswer == true) {
      return Container(
        width: 60,
        height: 60,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: Color(0xFFDCFCE7), // green-100
        ),
        child: const Center(
          child: Text('💡', style: TextStyle(fontSize: 28)),
        ),
      );
    }
    if (narration?.guidePhotoUrl != null) {
      return ClipOval(
        child: Image.network(
          narration!.guidePhotoUrl!,
          width: 60,
          height: 60,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _fallbackAvatar(),
        ),
      );
    }
    return _fallbackAvatar();
  }

  Widget _fallbackAvatar() {
    return Container(
      width: 60,
      height: 60,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: Color(0xFFe0f2f1),
      ),
      child: const Icon(Icons.volume_up, color: _teal, size: 30),
    );
  }

  // ── Center-on-me button ────────────────────────────────────────────────────

  Widget _buildCenterButton() {
    if (_userPosition == null) return const SizedBox.shrink();
    return Positioned(
      bottom: 110,
      right: 16,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 250),
        opacity: _narrationVisible ? 0.0 : 1.0,
        child: IgnorePointer(
          ignoring: _narrationVisible,
          child: Material(
            elevation: 4,
            shape: const CircleBorder(),
            color: Colors.white,
            child: InkWell(
              onTap: _centerOnUser,
              customBorder: const CircleBorder(),
              child: const SizedBox(
                width: 44,
                height: 44,
                child: Icon(Icons.my_location, color: _teal, size: 22),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── Trip controls ──────────────────────────────────────────────────────────

  Widget _buildTripControls() {
    return Positioned(
      bottom: 24,
      left: 16,
      right: 16,
      child: Card(
        elevation: 6,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: _tripControlRow(),
        ),
      ),
    );
  }

  Widget _tripControlRow() {
    switch (_tripService.tripState) {
      case TripState.idle:
        return SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _tripService.startTrip,
            icon: const Icon(Icons.explore),
            label: const Text('Explore'),
            style: ElevatedButton.styleFrom(
              backgroundColor: _teal,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        );

      case TripState.active:
        return Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _tripService.pauseTrip,
                icon: const Icon(Icons.pause),
                label: const Text('Pause'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: () => _confirmStop(),
                icon: const Icon(Icons.stop),
                label: const Text('Stop'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red.shade700,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
          ],
        );

      case TripState.paused:
        return Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _tripService.resumeTrip,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Resume Exploring'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _teal,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: () => _confirmStop(),
                icon: const Icon(Icons.stop),
                label: const Text('Stop'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red.shade700,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
          ],
        );
    }
  }

  Future<void> _confirmStop() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Stop exploring?'),
        content: const Text('This will end the current explore session.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Stop',
                  style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (ok == true && mounted) await _tripService.stopTrip();
  }

  // ── Version label ─────────────────────────────────────────────────────────

  Widget _buildVersionLabel() {
    if (_version.isEmpty) return const SizedBox.shrink();
    return Positioned(
      bottom: 100,
      right: 16,
      child: IgnorePointer(
        child: Text(
          _version,
          style: TextStyle(
            fontSize: 10,
            color: Colors.grey.shade600,
          ),
        ),
      ),
    );
  }

  // ── Nearby POIs card ───────────────────────────────────────────────────────

  IconData _iconForPoiType(String? type) {
    switch (type?.toLowerCase()) {
      case 'city': return Icons.location_city;
      case 'town': return Icons.home_work;
      case 'neighborhood': return Icons.map;
      default: return Icons.place;
    }
  }

  Widget _buildNearbyCard() {
    if (!_nearbyVisible) return const SizedBox.shrink();
    final top = MediaQuery.of(context).padding.top + 8 + 40 + 8;
    final pois = _tripService.nearbyPois;
    final radius = _tripService.nearbyRadiusMiles;

    return Positioned(
      top: top,
      left: 16,
      right: 16,
      child: Card(
        elevation: 6,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 220),
          child: pois.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'Nothing within $radius ${radius == 1 ? "mile" : "miles"}.\nExpand your distance limit in Settings → Explore Settings.',
                    style: const TextStyle(color: Colors.grey, fontSize: 13),
                  ),
                )
              : ListView.separated(
                  controller: _nearbyScrollController,
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: pois.length,
                  separatorBuilder: (_, _) => const Divider(height: 1, indent: 56),
                  itemBuilder: (_, i) {
                    final poi = pois[i];
                    return ListTile(
                      dense: true,
                      leading: Icon(_iconForPoiType(poi.locationType),
                          color: _teal, size: 20),
                      title: Text(poi.name,
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      subtitle: Text('${poi.distanceMiles} mi',
                          style: const TextStyle(fontSize: 11, color: Colors.grey)),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Learn — enabled when preview story exists
                          SizedBox(
                            height: 28,
                            child: OutlinedButton.icon(
                              onPressed: (poi.hasPreview && !_learnPlaying && _loadingLearnPoiId == null)
                                  ? () async {
                                      setState(() => _loadingLearnPoiId = poi.id);
                                      try {
                                        await _tripService.learnPoi(poi);
                                      } catch (_) {
                                        if (mounted) {
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            const SnackBar(content: Text('No preview available')),
                                          );
                                        }
                                      } finally {
                                        if (mounted) setState(() => _loadingLearnPoiId = null);
                                      }
                                    }
                                  : null,
                              icon: _loadingLearnPoiId == poi.id
                                  ? const SizedBox(
                                      width: 14, height: 14,
                                      child: CircularProgressIndicator(strokeWidth: 2))
                                  : const Icon(Icons.play_circle_outline, size: 14),
                              label: const Text('Learn', style: TextStyle(fontSize: 11)),
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 8),
                                minimumSize: Size.zero,
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          // Save
                          SizedBox(
                            height: 28,
                            child: OutlinedButton.icon(
                              onPressed: () => _tripService.toggleSavePoi(poi.id),
                              icon: Icon(
                                poi.isSaved ? Icons.bookmark : Icons.bookmark_border,
                                size: 14,
                                color: poi.isSaved ? _teal : null,
                              ),
                              label: Text(poi.isSaved ? 'Saved' : 'Save',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: poi.isSaved ? _teal : null,
                                  )),
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 8),
                                minimumSize: Size.zero,
                                side: poi.isSaved
                                    ? const BorderSide(color: _teal)
                                    : null,
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          // Go
                          SizedBox(
                            height: 28,
                            child: OutlinedButton.icon(
                              onPressed: () async {
                                final name = Uri.encodeComponent(poi.name);
                                final uri = Uri.parse(
                                    'geo:${poi.lat},${poi.lng}?q=${poi.lat},${poi.lng}($name)');
                                if (await canLaunchUrl(uri)) {
                                  await launchUrl(uri,
                                      mode: LaunchMode.externalApplication);
                                }
                              },
                              icon: const Icon(Icons.directions, size: 14),
                              label: const Text('Go', style: TextStyle(fontSize: 11)),
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 8),
                                minimumSize: Size.zero,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ),
    );
  }

  // ── Learn / preview card ───────────────────────────────────────────────────

  Widget _buildLearnCard() {
    if (!_learnCardVisible) return const SizedBox.shrink();
    final narration = _tripService.interruptNarration;
    final amber = Colors.amber.shade700;
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
      bottom: _learnCardVisible ? 120 : -400,
      left: 16,
      right: 16,
      child: Card(
        elevation: 8,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  // Guide avatar
                  _buildGuideAvatar(narration),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.amber.shade100,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text('PREVIEW',
                                  style: TextStyle(
                                      fontSize: 9,
                                      fontWeight: FontWeight.bold,
                                      color: amber,
                                      letterSpacing: 0.8)),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                narration?.storyTitle ?? narration?.locationName ?? '',
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        if ((narration?.locationName ?? '').isNotEmpty)
                          Text(narration!.locationName,
                              style: const TextStyle(fontSize: 12, color: Colors.grey)),
                      ],
                    ),
                  ),
                  // Dismiss button
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    color: Colors.grey,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: () async {
                      await _previewAudioService.stop();
                      _tripService.clearInterrupt();
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Pills row ──────────────────────────────────────────────────────────────

  Widget _buildPills() {
    final top = MediaQuery.of(context).padding.top + 8;
    return Positioned(
      top: top,
      left: 16,
      child: Row(
        children: [
          _buildToursPill(),
          const SizedBox(width: 8),
          _buildNearbyPill(),
          const SizedBox(width: 8),
          _buildSettingsPill(),
        ],
      ),
    );
  }

  Widget _buildNearbyPill() {
    final color = _nearbyVisible ? _teal : Colors.grey;
    return Material(
      elevation: 2,
      borderRadius: BorderRadius.circular(16),
      color: Colors.white,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => setState(() => _nearbyVisible = !_nearbyVisible),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.near_me, size: 16, color: color),
              const SizedBox(width: 4),
              Text('Nearby', style: TextStyle(fontSize: 12, color: color)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildToursPill() {
    final hasTour = _activeTour != null;
    final pillColor = hasTour ? _teal : Colors.grey;
    final label = hasTour
        ? (_activeTour!.name.length > 16
            ? '${_activeTour!.name.substring(0, 16)}...'
            : _activeTour!.name)
        : 'Tours';
    return Material(
      elevation: 2,
      borderRadius: BorderRadius.circular(16),
      color: Colors.white,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => ToursScreen(
              userLat: _userPosition?.latitude,
              userLng: _userPosition?.longitude,
            )),
          );
          _loadActiveTour();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.map_outlined, size: 16, color: pillColor),
              const SizedBox(width: 4),
              Text(label,
                  style: TextStyle(fontSize: 12, color: pillColor)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSettingsPill() {
    return Material(
      elevation: 2,
      borderRadius: BorderRadius.circular(16),
      color: Colors.white,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const SettingsScreen()),
          );
          _loadMapStyle();
        },
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.settings, size: 16, color: Colors.grey),
              SizedBox(width: 4),
              Text('Settings',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
            ],
          ),
        ),
      ),
    );
  }

}

/// Auto-scrolling marquee text: pause → scroll to end → pause → reset → repeat.
class _MarqueeText extends StatefulWidget {
  final String text;
  final TextStyle? style;
  const _MarqueeText({required this.text, this.style});

  @override
  State<_MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<_MarqueeText> {
  final ScrollController _sc = ScrollController();
  Timer? _timer;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _startCycle());
  }

  @override
  void didUpdateWidget(_MarqueeText old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) {
      _timer?.cancel();
      _sc.jumpTo(0);
      WidgetsBinding.instance.addPostFrameCallback((_) => _startCycle());
    }
  }

  void _startCycle() {
    if (_disposed || !_sc.hasClients) return;
    final maxScroll = _sc.position.maxScrollExtent;
    if (maxScroll <= 0) return; // text fits, no scrolling needed

    _timer?.cancel();
    // Initial pause, then scroll
    _timer = Timer(const Duration(seconds: 2), () {
      if (_disposed || !_sc.hasClients) return;
      // Scroll speed: ~40px/s
      final durationMs = (maxScroll / 40 * 1000).toInt();
      _sc.animateTo(maxScroll,
          duration: Duration(milliseconds: durationMs),
          curve: Curves.linear);
      // After scroll completes, pause then reset
      _timer = Timer(Duration(milliseconds: durationMs + 2000), () {
        if (_disposed || !_sc.hasClients) return;
        _sc.jumpTo(0);
        // Restart the cycle
        _startCycle();
      });
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _sc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      controller: _sc,
      scrollDirection: Axis.horizontal,
      physics: const NeverScrollableScrollPhysics(),
      child: Text(widget.text, style: widget.style, maxLines: 1),
    );
  }
}
