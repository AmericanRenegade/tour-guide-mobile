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
import '../models/narration_card_item.dart';
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
  // ── Narration carousel state ──
  final List<NarrationCardItem> _carouselItems = [];
  final PageController _carouselController = PageController();
  int _activeCardIndex = -1; // index of currently-playing card (-1 = none)
  bool _carouselVisible = false;
  double _carouselOpacity = 1.0;
  final Set<String> _carouselNarrationIds = {};
  bool _pausedBySwipe = false;
  bool _playingNarration = false;
  bool _narrationPaused = false;
  bool _skippingNarration = false;

  // Trivia interstitial state
  bool _waitingForReveal = false;
  Completer<void>? _revealCompleter;
  int _countdownSeconds = 0;
  Timer? _countdownTimer;

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
    _carouselController.dispose();
    _countdownTimer?.cancel();
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
    // Clean up carousel + audio when trip ends
    if (_tripService.tripState == TripState.idle) {
      if (_playingNarration) {
        _audioService.stop();
        _playingNarration = false;
        _skippingNarration = false;
      }
      if (_carouselVisible) {
        _carouselVisible = false;
        _carouselOpacity = 0.0;
      }
      _activeCardIndex = -1;
      if (mounted) setState(() {});
      // Clear carousel items after slide-down animation
      Future.delayed(const Duration(milliseconds: 400), () {
        if (mounted) {
          _carouselItems.clear();
          _carouselNarrationIds.clear();
          setState(() {});
        }
      });
      return;
    }
    // Sync carousel with pool — show all queued items as cards
    _syncCarouselWithPool();
    if (_tripService.pendingNarration != null && !_playingNarration) {
      _playNarration();
    } else if (!_playingNarration && _carouselItems.isEmpty) {
      // Trip just started with nothing queued yet — show waiting card
      _addWaitingPlaceholder();
      if (mounted) setState(() {});
    }
  }

  Future<void> _startLearnPlayback() async {
    _learnPlaying = true;
    // Pause (not stop) the main narration so it can resume where it left off.
    // The _playNarration loop stays suspended at its await — when we resume(),
    // the audio continues and the loop completes naturally.
    final wasNarrating = _playingNarration;
    if (wasNarrating) await _audioService.pause();
    if (mounted) setState(() {
      _narrationPaused = false;
      _carouselVisible = false;
      _learnCardVisible = true;
    });
    final narration = _tripService.interruptNarration;
    if (narration != null) {
      await _previewAudioService.playBase64(narration.audioBase64);
    }
    _tripService.clearInterrupt();
    if (mounted) setState(() => _learnCardVisible = false);
    _learnPlaying = false;
    // Resume main narration from where it was paused
    if (wasNarrating) {
      await _audioService.resume();
      if (mounted) setState(() {
        _carouselVisible = true;
        _carouselOpacity = 1.0;
      });
    }
  }

  Future<void> _playNarration() async {
    final narration = _tripService.pendingNarration;
    if (narration == null) return;
    _playingNarration = true;
    _skippingNarration = false;
    _narrationPaused = false;
    _pausedBySwipe = false;
    _removeWaitingPlaceholder();

    // Determine relationship to active carousel card
    final activeCard = _activeCardIndex >= 0 && _activeCardIndex < _carouselItems.length
        ? _carouselItems[_activeCardIndex]
        : null;
    final resumingSame = activeCard != null && activeCard.id == narration.narrationId;
    final sameGroup = !resumingSame &&
        activeCard != null &&
        activeCard.isTrivia &&
        narration.groupId != null &&
        narration.groupId == activeCard.groupId;

    if (resumingSame) {
      // Resuming after learn interrupt — re-show carousel, same card
      if (mounted) setState(() {
        _carouselVisible = true;
        _carouselOpacity = 1.0;
      });
    } else if (sameGroup) {
      // Absorb trivia interstitial/answer into existing card
      activeCard.absorb(narration);
      if (mounted) setState(() {});
    } else {
      // New narration — mark previous active as played
      if (activeCard != null && activeCard.isActive) {
        activeCard.state = NarrationCardState.played;
        activeCard.playedAt = DateTime.now();
      }
      // Find existing card (from pool sync) or create one
      final existingIdx = _carouselItems.indexWhere((c) => c.id == narration.narrationId);
      if (existingIdx >= 0) {
        _activeCardIndex = existingIdx;
        _carouselItems[existingIdx].state = NarrationCardState.active;
      } else {
        final card = NarrationCardItem.fromPending(narration);
        _carouselItems.add(card);
        _carouselNarrationIds.add(narration.narrationId);
        _enforceHistoryLimit();
        _activeCardIndex = _carouselItems.length - 1;
      }
      if (mounted) {
        setState(() {
          _carouselVisible = true;
          _carouselOpacity = 1.0;
          _waitingForReveal = false;
          _countdownSeconds = 0;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_carouselController.hasClients) {
            _carouselController.animateToPage(
              _activeCardIndex,
              duration: const Duration(milliseconds: 350),
              curve: Curves.easeOutCubic,
            );
          }
        });
      }
    }

    // Play audio / handle content type
    if (narration.isTourProgress) {
      await Future.delayed(const Duration(seconds: 4));
    } else if (narration.isTriviaInterstitial) {
      await _handleTriviaInterstitial(narration);
    } else {
      await _audioService.playBase64(narration.audioBase64);
    }

    // Guard: learn interrupt — _startLearnPlayback() will restart us
    if (_learnPlaying) return;
    // Guard: trip ended — _onTripChanged already cleaned up
    if (_tripService.tripState == TripState.idle) return;

    // Advance queue (confirms played to backend, removes from local queue)
    _tripService.advanceQueue();
    _skippingNarration = false;

    // Check what's next
    final nextNarration = _tripService.pendingNarration;
    if (nextNarration != null) {
      final currentCard = _activeCardIndex >= 0 && _activeCardIndex < _carouselItems.length
          ? _carouselItems[_activeCardIndex]
          : null;
      final nextSameGroup = currentCard != null &&
          currentCard.isTrivia &&
          nextNarration.groupId != null &&
          nextNarration.groupId == currentCard.groupId;
      if (!nextSameGroup && currentCard != null && currentCard.isActive) {
        currentCard.state = NarrationCardState.played;
        currentCard.playedAt = DateTime.now();
      }
      _playingNarration = false;
      _playNarration();
      return;
    }

    // Nothing pending — mark active card as played, keep carousel visible
    if (_activeCardIndex >= 0 && _activeCardIndex < _carouselItems.length) {
      final card = _carouselItems[_activeCardIndex];
      card.state = NarrationCardState.played;
      card.playedAt = DateTime.now();
    }
    _activeCardIndex = -1;
    _playingNarration = false;
    _addWaitingPlaceholder();
    if (mounted) setState(() {});
  }

  void _enforceHistoryLimit() {
    const maxCards = 25;
    while (_carouselItems.length > maxCards) {
      _carouselNarrationIds.remove(_carouselItems[0].id);
      _carouselItems.removeAt(0);
      if (_activeCardIndex > 0) _activeCardIndex--;
    }
  }

  /// Create carousel cards for all pool items not yet shown.
  /// Trivia interstitial/answer are skipped — they'll be absorbed during playback.
  void _syncCarouselWithPool() {
    final pool = _tripService.narrationPool;
    final seenGroups = <String>{};
    for (final item in _carouselItems) {
      if (item.groupId != null) seenGroups.add(item.groupId!);
    }
    bool added = false;
    for (final narration in pool) {
      if (_carouselNarrationIds.contains(narration.narrationId)) continue;
      if (narration.isTriviaInterstitial || narration.isTriviaAnswer) continue;
      if (narration.groupId != null && seenGroups.contains(narration.groupId)) continue;
      final card = NarrationCardItem.fromPending(narration);
      card.state = NarrationCardState.queued;
      _carouselItems.add(card);
      _carouselNarrationIds.add(narration.narrationId);
      if (narration.groupId != null) seenGroups.add(narration.groupId!);
      added = true;
    }
    if (added) {
      _enforceHistoryLimit();
      if (!_carouselVisible && _carouselItems.isNotEmpty) {
        _carouselVisible = true;
        _carouselOpacity = 1.0;
      }
      if (mounted) setState(() {});
    }
  }

  /// Add a "Waiting for next tour stop..." placeholder card at the end.
  void _addWaitingPlaceholder() {
    // Don't double-add
    if (_carouselItems.isNotEmpty && _carouselItems.last.isPlaceholder) return;
    _carouselItems.add(NarrationCardItem.waitingPlaceholder());
    if (!_carouselVisible) {
      _carouselVisible = true;
      _carouselOpacity = 1.0;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_carouselController.hasClients) {
        _carouselController.animateToPage(
          _carouselItems.length - 1,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  /// Remove the waiting placeholder (when a real narration arrives).
  void _removeWaitingPlaceholder() {
    _carouselItems.removeWhere((c) => c.isPlaceholder);
  }

  void _onCarouselPageChanged(int index) {
    if (index < 0 || index >= _carouselItems.length) return;
    final card = _carouselItems[index];

    // Swiped to a queued card → skip breathe timer and trigger playback
    if (card.state == NarrationCardState.queued && !card.isPlaceholder && !_playingNarration) {
      _tripService.skipBreatheTimer();
      // _onTripChanged will fire from notifyListeners and start playback
      return;
    }

    // Swiped away from active card → pause; swiped back → resume
    if (_playingNarration && _activeCardIndex >= 0) {
      if (index != _activeCardIndex && !_pausedBySwipe) {
        _audioService.pause();
        _pausedBySwipe = true;
        if (mounted) setState(() => _narrationPaused = true);
      } else if (index == _activeCardIndex && _pausedBySwipe) {
        _audioService.resume();
        _pausedBySwipe = false;
        if (mounted) setState(() => _narrationPaused = false);
      }
    }
  }

  void _toggleNarrationPause() {
    if (_narrationPaused) {
      _audioService.resume();
    } else {
      _audioService.pause();
    }
    setState(() => _narrationPaused = !_narrationPaused);
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
            _buildNarrationCarousel(),
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

  // ── Narration carousel ───────────────────────────────────────────────────

  Widget _buildNarrationCarousel() {
    final nearbyExtra = _nearbyVisible ? 236.0 : 0.0;
    final maxCardHeight = MediaQuery.of(context).size.height
        - MediaQuery.of(context).padding.top - 8 - 40 - 8
        - nearbyExtra
        - 48 - 120;
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
      bottom: _carouselVisible ? 120 : -600,
      left: 0,
      right: 0,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 500),
        opacity: _carouselOpacity,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxCardHeight),
          child: _carouselItems.isEmpty
              ? const SizedBox.shrink()
              : PageView.builder(
                  controller: _carouselController,
                  physics: const BouncingScrollPhysics(),
                  onPageChanged: _onCarouselPageChanged,
                  itemCount: _carouselItems.length + 1,
                  itemBuilder: (context, index) {
                    if (index >= _carouselItems.length) {
                      return const SizedBox.shrink();
                    }
                    return Align(
                      alignment: Alignment.bottomCenter,
                      child: _buildCarouselCard(
                        _carouselItems[index],
                        index == _activeCardIndex,
                      ),
                    );
                  },
                ),
        ),
      ),
    );
  }

  Widget _buildCarouselCard(NarrationCardItem item, bool isActive) {
    // Waiting placeholder card
    if (item.isPlaceholder) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Card(
          elevation: 6,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          color: Colors.white,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.explore, color: _teal.withValues(alpha: 0.4), size: 40),
                const SizedBox(height: 12),
                Text(
                  'Waiting for next tour stop...',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    color: Colors.grey.shade600,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final breatheRemaining = _tripService.breatheSecondsRemaining;
    final isQueued = item.state == NarrationCardState.queued;
    final realCards = _carouselItems.where((c) => !c.isPlaceholder);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Card(
        elevation: 6,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        color: Colors.white,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // "Playing in Xs..." banner for queued cards with breathe delay
              if (isQueued && breatheRemaining > 0) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  margin: const EdgeInsets.only(bottom: 10),
                  decoration: BoxDecoration(
                    color: _teal.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'Playing in ${breatheRemaining}s...',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: _teal.withValues(alpha: 0.8),
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
              // Top row: guide avatar + title + narrator
              Row(
                children: [
                  _buildCardAvatar(item, 56),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (isActive)
                          _MarqueeText(
                            text: _cardTitle(item),
                            style: const TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 18),
                          )
                        else
                          Text(
                            _cardTitle(item),
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        if (item.locationName.isNotEmpty)
                          Text(
                            item.locationName,
                            style: const TextStyle(color: Colors.grey, fontSize: 13),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        if (item.narrator.isNotEmpty && !item.isTriviaInterstitial)
                          Text(
                            item.narrator,
                            style: const TextStyle(color: Colors.grey, fontSize: 13),
                          ),
                      ],
                    ),
                  ),
                  if (realCards.length > 1)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: _teal.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        '${realCards.toList().indexOf(item) + 1} of ${realCards.length}',
                        style: const TextStyle(
                          color: _teal,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                ],
              ),
              // Trivia interstitial: countdown or tap-to-reveal (active only)
              if (isActive && item.isTriviaInterstitial && _waitingForReveal) ...[
                const SizedBox(height: 16),
                if (_countdownSeconds > 0) ...[
                  Text(
                    'Answer in $_countdownSeconds s...',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF7C3AED),
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
                      backgroundColor: const Color(0xFF7C3AED),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
                    ),
                  ),
                ),
              ],
              // Trivia history: show answer text on played trivia cards
              if (!isActive && item.isTrivia && item.answerText != null) ...[
                const SizedBox(height: 8),
                Text(
                  item.answerText!,
                  style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              // Controls row: Play/Pause + Like + Feedback (all cards except interstitial)
              if (!item.isTourProgress && !item.isTriviaInterstitial) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    // Play / Pause
                    SizedBox(
                      width: 46,
                      height: 46,
                      child: IconButton(
                        padding: EdgeInsets.zero,
                        icon: Icon(
                          (isActive && !_narrationPaused)
                              ? Icons.pause_circle_filled
                              : Icons.play_circle_filled,
                          color: _teal,
                          size: 42,
                        ),
                        onPressed: () {
                          if (isActive) {
                            _toggleNarrationPause();
                          } else if (isQueued) {
                            _tripService.skipBreatheTimer();
                          } else if (item.hasAudio) {
                            _audioService.playBase64(item.audioBase64!);
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Like
                    SizedBox(
                      width: 46,
                      height: 46,
                      child: IconButton(
                        padding: EdgeInsets.zero,
                        icon: Icon(
                          item.liked ? Icons.thumb_up : Icons.thumb_up_outlined,
                          color: item.liked ? _teal : Colors.grey.shade400,
                          size: 28,
                        ),
                        onPressed: () {
                          setState(() => item.liked = !item.liked);
                        },
                      ),
                    ),
                    const Spacer(),
                    // Feedback
                    GestureDetector(
                      onTap: () {},
                      child: const Text(
                        'Feedback',
                        style: TextStyle(
                          fontSize: 15,
                          color: Color(0xFF2563EB),
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
    );
  }

  String _cardTitle(NarrationCardItem item) {
    if (item.isTriviaQuestion) return 'Trivia';
    if (item.isTriviaInterstitial) return 'Think About It...';
    if (item.isTriviaAnswer) return 'Answer';
    if ((item.storyTitle ?? '').isNotEmpty) return item.storyTitle!;
    return item.locationName;
  }

  Widget _buildCardAvatar(NarrationCardItem item, double size) {
    if (item.isTourProgress) {
      return Container(
        width: size, height: size,
        decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFFFFF8E1)),
        child: Icon(Icons.emoji_events, color: const Color(0xFFF9A825), size: size * 0.53),
      );
    }
    if (item.isTriviaQuestion) {
      return Container(
        width: size, height: size,
        decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFFF3E8FF)),
        child: Center(child: Text('\u2753', style: TextStyle(fontSize: size * 0.47))),
      );
    }
    if (item.isTriviaInterstitial) {
      return Container(
        width: size, height: size,
        decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFFF3E8FF)),
        child: Icon(Icons.timer, color: const Color(0xFF7C3AED), size: size * 0.53),
      );
    }
    if (item.isTriviaAnswer) {
      return Container(
        width: size, height: size,
        decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFFDCFCE7)),
        child: Center(child: Text('\u{1F4A1}', style: TextStyle(fontSize: size * 0.47))),
      );
    }
    if (item.guidePhotoUrl != null) {
      return ClipOval(
        child: Image.network(
          item.guidePhotoUrl!,
          width: size, height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _fallbackAvatarSized(size),
        ),
      );
    }
    return _fallbackAvatarSized(size);
  }

  Widget _fallbackAvatarSized(double size) {
    return Container(
      width: size, height: size,
      decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFFe0f2f1)),
      child: Icon(Icons.volume_up, color: _teal, size: size * 0.5),
    );
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
        opacity: _carouselVisible ? 0.0 : 1.0,
        child: IgnorePointer(
          ignoring: _carouselVisible,
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
