import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/active_location.dart';
import '../services/trip_service.dart';
import '../services/audio_service.dart';
import '../auth_service.dart';
import '../models/tour.dart';
import 'settings_screen.dart';
import 'tours_screen.dart';

// ── Search result model ─────────────────────────────────────────────────────

class SearchResult {
  final String id;
  final String name;
  final double lat;
  final double lng;
  final String? county;
  final String? stateCode;
  final double? distanceMiles;

  const SearchResult({
    required this.id,
    required this.name,
    required this.lat,
    required this.lng,
    this.county,
    this.stateCode,
    this.distanceMiles,
  });

  factory SearchResult.fromJson(Map<String, dynamic> j) => SearchResult(
        id: j['id'] as String,
        name: j['name'] as String,
        lat: (j['lat'] as num).toDouble(),
        lng: (j['lng'] as num).toDouble(),
        county: j['county'] as String?,
        stateCode: j['state_code'] as String?,
        distanceMiles: (j['distance_miles'] as num?)?.toDouble(),
      );
}

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

  // Narration text auto-scroll
  final ScrollController _narrationScrollController = ScrollController();
  StreamSubscription<Duration>? _positionStreamSub;

  // Search state
  bool _searchActive = false;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  List<SearchResult> _searchResults = [];
  Timer? _searchDebounce;
  bool _searchLoading = false;
  // Search filters
  double? _searchRadiusMiles;
  String _searchState = '';
  String _searchCounty = '';

  // Version
  String _version = '';

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
  }

  @override
  void dispose() {
    _tripService.removeListener(_onTripChanged);
    _tripService.dispose();
    _positionSub?.cancel();
    _positionStreamSub?.cancel();
    _audioService.dispose();
    _narrationScrollController.dispose();
    _searchController.dispose();
    _searchFocus.dispose();
    _searchDebounce?.cancel();
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
    // Clean up narration card + audio when trip ends
    if (_tripService.tripState == TripState.idle) {
      if (_upNextSeconds > 0) _cancelUpNext();
      if (_playingNarration) {
        _audioService.stop();
        _positionStreamSub?.cancel();
        _positionStreamSub = null;
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
      _positionStreamSub?.cancel();
      _positionStreamSub =
          _audioService.positionStream.listen(_onAudioPositionChanged);

      await _audioService.playBase64(narration.audioBase64);

      _positionStreamSub?.cancel();
      _positionStreamSub = null;
    }

    // If trip ended while we were playing, _onTripChanged already cleaned up
    if (_tripService.tripState == TripState.idle) return;

    // Advance queue (confirms played to backend, removes from local queue)
    _tripService.advanceQueue();
    final wasSkipped = _skippingNarration;
    _skippingNarration = false;

    // If more narrations in queue and ready immediately, play next
    if (_tripService.pendingNarration != null) {
      // Reset scroll for the next narration
      if (_narrationScrollController.hasClients) {
        _narrationScrollController.jumpTo(0);
      }
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

    // Default: 'auto' countdown
    final seconds = narration.revealDelayS ?? 15;
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

  void _onAudioPositionChanged(Duration position) {
    final total = _audioService.duration;
    if (total == null || total.inMilliseconds == 0) return;
    if (!_narrationScrollController.hasClients) return;
    final maxScroll = _narrationScrollController.position.maxScrollExtent;
    if (maxScroll <= 0) return; // text fits without scrolling

    // Delay scroll start by 3 seconds, finish 3 seconds before end.
    // This gives the user time to read the opening text and ensures
    // the final lines are visible for a few seconds before the card fades.
    const startDelayMs = 3000;
    const endBufferMs = 3000;
    final totalMs = total.inMilliseconds;
    final posMs = position.inMilliseconds;
    final scrollWindowMs = totalMs - startDelayMs - endBufferMs;
    if (scrollWindowMs <= 0) return; // audio too short to scroll

    final scrollProgress =
        ((posMs - startDelayMs) / scrollWindowMs).clamp(0.0, 1.0);
    _narrationScrollController
        .jumpTo((scrollProgress * maxScroll).clamp(0.0, maxScroll));
  }

  // ── Search ─────────────────────────────────────────────────────────────────

  void _onSearchChanged(String query) {
    _searchDebounce?.cancel();
    if (query.trim().isEmpty) {
      setState(() {
        _searchResults = [];
        _searchLoading = false;
      });
      return;
    }
    setState(() => _searchLoading = true);
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      _doSearch(query.trim());
    });
  }

  Future<void> _doSearch(String query) async {
    try {
      final params = <String, String>{
        'q': query,
        'limit': '20',
      };
      if (_userPosition != null) {
        params['lat'] = _userPosition!.latitude.toString();
        params['lng'] = _userPosition!.longitude.toString();
      }
      if (_searchRadiusMiles != null) {
        params['radius_miles'] = _searchRadiusMiles.toString();
      }
      if (_searchState.isNotEmpty) {
        params['state'] = _searchState;
      }
      if (_searchCounty.isNotEmpty) {
        params['county'] = _searchCounty;
      }
      final uri =
          Uri.parse('$_backendBase/search').replace(queryParameters: params);
      final response =
          await http.get(uri).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200 && mounted) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final results = (data['results'] as List)
            .map((j) => SearchResult.fromJson(j as Map<String, dynamic>))
            .toList();
        setState(() {
          _searchResults = results;
          _searchLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Search error: $e');
      if (mounted) setState(() => _searchLoading = false);
    }
  }

  void _selectSearchResult(SearchResult result) {
    setState(() {
      _searchActive = false;
      _searchResults = [];
      _searchController.clear();
    });
    _searchFocus.unfocus();
    _mapController.move(LatLng(result.lat, result.lng), 15);
  }

  void _dismissSearch() {
    setState(() {
      _searchActive = false;
      _searchResults = [];
      _searchController.clear();
    });
    _searchFocus.unfocus();
  }

  void _showSearchOptions() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => _SearchOptionsSheet(
        radiusMiles: _searchRadiusMiles,
        state: _searchState,
        county: _searchCounty,
        onApply: (radius, state, county) {
          setState(() {
            _searchRadiusMiles = radius;
            _searchState = state;
            _searchCounty = county;
          });
          Navigator.pop(ctx);
          // Re-run search with new filters
          if (_searchController.text.trim().isNotEmpty) {
            _onSearchChanged(_searchController.text);
          }
        },
      ),
    );
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
            _buildSearchBar(),
            if (!_searchActive) _buildPills(),
            if (_searchActive) _buildSearchResults(),
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
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.tourguide.app',
        ),
        // Zone overlays — circles
        CircleLayer(
          circles: _locations
              .where((loc) => !loc.isPolygon)
              .map((loc) => CircleMarker(
                    point: LatLng(loc.lat, loc.lng),
                    radius: loc.circleRadiusM,
                    useRadiusInMeter: true,
                    color: const Color(0x330d9488),
                    borderColor: _teal,
                    borderStrokeWidth: 1,
                  ))
              .toList(),
        ),
        // Zone overlays — polygons (single and multi-ring)
        PolygonLayer(
          polygons: _locations
              .where((loc) => loc.isPolygon)
              .expand((loc) => loc.allPolygonRings.map((ring) => Polygon(
                    points: ring.map((c) => LatLng(c[0], c[1])).toList(),
                    color: const Color(0x330d9488),
                    borderColor: _teal,
                    borderStrokeWidth: 1,
                  )))
              .toList(),
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
    final maxCardHeight = MediaQuery.of(context).size.height
        - MediaQuery.of(context).padding.top - 68 - 48 // below pills
        - 120; // above trip controls
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
                  // Narration text (scrolling) — for stories & trivia Q/A
                  if ((narration?.narrationText ?? '').isNotEmpty &&
                      !(narration?.isTriviaInterstitial ?? false)) ...[
                    const SizedBox(height: 10),
                    const Divider(height: 1),
                    const SizedBox(height: 8),
                    Flexible(
                      child: ShaderMask(
                        shaderCallback: (bounds) => const LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.white, Colors.white, Colors.transparent],
                          stops: [0.0, 0.85, 1.0],
                        ).createShader(bounds),
                        blendMode: BlendMode.dstIn,
                        child: SingleChildScrollView(
                          controller: _narrationScrollController,
                          physics: const ClampingScrollPhysics(),
                          child: Text(
                            narration!.narrationText,
                            style: const TextStyle(
                              fontSize: 15,
                              height: 1.5,
                              color: Color(0xFF444444),
                            ),
                          ),
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
            icon: const Icon(Icons.play_arrow),
            label: const Text('Start Trip'),
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
                label: const Text('Resume'),
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
        title: const Text('End trip?'),
        content: const Text('This will end the current trip session.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('End Trip',
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

  // ── Search bar ─────────────────────────────────────────────────────────────

  Widget _buildSearchBar() {
    final top = MediaQuery.of(context).padding.top + 8;
    return Positioned(
      top: top,
      left: 16,
      right: 16,
      child: Material(
        elevation: 4,
        borderRadius: BorderRadius.circular(16),
        color: Colors.white,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: _searchActive
              ? null
              : () => setState(() {
                    _searchActive = true;
                    // Focus after frame builds
                    WidgetsBinding.instance
                        .addPostFrameCallback((_) => _searchFocus.requestFocus());
                  }),
          child: SizedBox(
            height: 48,
            child: Row(
              children: [
                const SizedBox(width: 14),
                const Icon(Icons.search, color: Colors.grey, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: _searchActive
                      ? TextField(
                          controller: _searchController,
                          focusNode: _searchFocus,
                          onChanged: _onSearchChanged,
                          decoration: const InputDecoration(
                            hintText: 'Search tours and places',
                            hintStyle: TextStyle(color: Colors.grey, fontSize: 15),
                            border: InputBorder.none,
                            contentPadding: EdgeInsets.zero,
                            isDense: true,
                          ),
                          style: const TextStyle(fontSize: 15),
                        )
                      : const Text(
                          'Search tours and places',
                          style: TextStyle(color: Colors.grey, fontSize: 15),
                        ),
                ),
                if (_searchActive && _searchController.text.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.close, size: 20, color: Colors.grey),
                    onPressed: () {
                      _searchController.clear();
                      _onSearchChanged('');
                    },
                  ),
                IconButton(
                  icon: Icon(
                    Icons.tune,
                    size: 20,
                    color: (_searchRadiusMiles != null ||
                            _searchState.isNotEmpty ||
                            _searchCounty.isNotEmpty)
                        ? _teal
                        : Colors.grey,
                  ),
                  onPressed: _showSearchOptions,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSearchResults() {
    final top = MediaQuery.of(context).padding.top + 68;
    return Positioned(
      top: top,
      left: 16,
      right: 16,
      bottom: 0,
      child: GestureDetector(
        onTap: _dismissSearch,
        behavior: HitTestBehavior.opaque,
        child: Align(
          alignment: Alignment.topCenter,
          child: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(12),
            color: Colors.white,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: _searchLoading
                  ? const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(
                          child: SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(strokeWidth: 2))),
                    )
                  : _searchResults.isEmpty &&
                          _searchController.text.isNotEmpty
                      ? const Padding(
                          padding: EdgeInsets.all(16),
                          child: Text('No results found',
                              style: TextStyle(color: Colors.grey)),
                        )
                      : _searchResults.isEmpty
                          ? const SizedBox.shrink()
                          : ListView.separated(
                              shrinkWrap: true,
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              itemCount: _searchResults.length,
                              separatorBuilder: (_, __) =>
                                  const Divider(height: 1, indent: 16),
                              itemBuilder: (_, i) {
                                final r = _searchResults[i];
                                final subtitle = [
                                  if (r.county != null) r.county,
                                  if (r.stateCode != null) r.stateCode,
                                ].join(', ');
                                return ListTile(
                                  dense: true,
                                  title: Text(r.name,
                                      style: const TextStyle(fontSize: 14)),
                                  subtitle: subtitle.isNotEmpty
                                      ? Text(subtitle,
                                          style: const TextStyle(
                                              fontSize: 12,
                                              color: Colors.grey))
                                      : null,
                                  trailing: r.distanceMiles != null
                                      ? Text(
                                          '${r.distanceMiles!.toStringAsFixed(1)} mi',
                                          style: const TextStyle(
                                              fontSize: 12, color: _teal),
                                        )
                                      : null,
                                  onTap: () => _selectSearchResult(r),
                                );
                              },
                            ),
            ),
          ),
        ),
      ),
    );
  }

  // ── Pills row (Tours + Settings) ──────────────────────────────────────────

  Widget _buildPills() {
    final top = MediaQuery.of(context).padding.top + 68;
    return Positioned(
      top: top,
      left: 16,
      child: Row(
        children: [
          _buildToursPill(),
          const SizedBox(width: 8),
          _buildSettingsPill(),
        ],
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
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const SettingsScreen()),
        ),
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

// ── Search options bottom sheet ──────────────────────────────────────────────

class _SearchOptionsSheet extends StatefulWidget {
  final double? radiusMiles;
  final String state;
  final String county;
  final void Function(double? radius, String state, String county) onApply;

  const _SearchOptionsSheet({
    required this.radiusMiles,
    required this.state,
    required this.county,
    required this.onApply,
  });

  @override
  State<_SearchOptionsSheet> createState() => _SearchOptionsSheetState();
}

class _SearchOptionsSheetState extends State<_SearchOptionsSheet> {
  late double? _radius;
  late TextEditingController _stateCtrl;
  late TextEditingController _countyCtrl;

  static const List<double?> _distanceOptions = [
    10,
    25,
    50,
    100,
    null,
  ];
  static const List<String> _distanceLabels = [
    '10 mi',
    '25 mi',
    '50 mi',
    '100 mi',
    'Any',
  ];

  @override
  void initState() {
    super.initState();
    _radius = widget.radiusMiles;
    _stateCtrl = TextEditingController(text: widget.state);
    _countyCtrl = TextEditingController(text: widget.county);
  }

  @override
  void dispose() {
    _stateCtrl.dispose();
    _countyCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Search Options',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          // Distance chips
          const Text('Distance',
              style: TextStyle(fontSize: 13, color: Colors.grey)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: List.generate(_distanceOptions.length, (i) {
              final selected = _radius == _distanceOptions[i];
              return ChoiceChip(
                label: Text(_distanceLabels[i]),
                selected: selected,
                selectedColor: const Color(0xFF0d9488).withValues(alpha: 0.15),
                onSelected: (_) => setState(() => _radius = _distanceOptions[i]),
              );
            }),
          ),
          const SizedBox(height: 16),
          // State filter
          TextField(
            controller: _stateCtrl,
            decoration: const InputDecoration(
              labelText: 'State (e.g. VA, MD)',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            textCapitalization: TextCapitalization.characters,
          ),
          const SizedBox(height: 12),
          // County filter
          TextField(
            controller: _countyCtrl,
            decoration: const InputDecoration(
              labelText: 'County',
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => widget.onApply(
                _radius,
                _stateCtrl.text.trim(),
                _countyCtrl.text.trim(),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0d9488),
                foregroundColor: Colors.white,
              ),
              child: const Text('Apply'),
            ),
          ),
        ],
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
