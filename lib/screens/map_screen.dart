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
  // Guard: set at _playActiveCard start, cleared by _deactivateCurrentCard.
  // Prevents stale _onAudioFinished from advancing the queue.
  String? _playingCardId;
  Timer? _breatheCountdownTimer;
  Timer? _countdownTimer; // trivia interstitial countdown

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
  String _mapStyle = 'voyager';

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

  String get _tileUrl {
    switch (_mapStyle) {
      case 'osm':
        return 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
      case 'positron':
        return 'https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png';
      case 'dark':
        return 'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png';
      case 'satellite':
        return 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';
      case 'topo':
        return 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Topo_Map/MapServer/tile/{z}/{y}/{x}';
      case 'voyager':
      default:
        return 'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}{r}.png';
    }
  }

  List<String> get _tileSubdomains {
    switch (_mapStyle) {
      case 'osm':
      case 'satellite':
      case 'topo':
        return const [];
      default:
        return const ['a', 'b', 'c', 'd'];
    }
  }

  Future<void> _loadMapStyle() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) setState(() => _mapStyle = prefs.getString('map_style') ?? 'voyager');
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
    _breatheCountdownTimer?.cancel();
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

  // ═══════════════════════════════════════════════════════════════════════════
  // CAROUSEL STATE MACHINE
  //
  // Single entry point: _activateCard(index) owns all card transitions.
  // _onTripChanged, _onCarouselPageChanged, and button presses all funnel
  // through _activateCard. No recursion, no generation counters.
  // ═══════════════════════════════════════════════════════════════════════════

  bool get _isPlaying => _activeCardIndex >= 0;

  NarrationCardItem? get _activeCard =>
      _activeCardIndex >= 0 && _activeCardIndex < _carouselItems.length
          ? _carouselItems[_activeCardIndex]
          : null;

  // ── Trip service listener ────────────────────────────────────────────────

  void _onTripChanged() {
    if (_tripService.isInterrupting && !_learnPlaying) {
      _startLearnPlayback();
      return;
    }
    if (_tripService.tripState == TripState.idle) {
      // Trip ended — clean up even during learn interrupt
      _deactivateCurrentCard();
      _breatheCountdownTimer?.cancel();
      _carouselVisible = false;
      _carouselOpacity = 0.0;
      if (mounted) setState(() {});
      Future.delayed(const Duration(milliseconds: 400), () {
        if (mounted) {
          _carouselItems.clear();
          _carouselNarrationIds.clear();
          setState(() {});
        }
      });
      return;
    }
    if (_learnPlaying) {
      // During learn interrupt: sync cards into carousel but don't start
      // playback — restore logic in _startLearnPlayback handles that.
      _syncCarouselWithPool();
      return;
    }
    _syncCarouselWithPool();
    final breatheActive = _breatheCountdownTimer?.isActive ?? false;
    if (!_isPlaying && !breatheActive) {
      _activateNextCard();
    }
  }

  // ── Learn / preview interrupt ────────────────────────────────────────────

  Future<void> _startLearnPlayback() async {
    _learnPlaying = true;

    // Snapshot: pause audio if a card was actively playing (not user-paused)
    final activeCard = _activeCard;
    bool pausedForLearn = false;
    if (activeCard != null && !activeCard.paused) {
      activeCard.lastPosition = _audioService.currentPosition;
      _audioService.pause();
      pausedForLearn = true;
    }
    // Pause breathe countdown (will resume or re-evaluate on restore)
    _breatheCountdownTimer?.cancel();

    // Hide carousel, show learn card
    if (mounted) setState(() {
      _carouselVisible = false;
      _learnCardVisible = true;
    });

    // Play learn content
    final narration = _tripService.interruptNarration;
    if (narration != null) {
      await _previewAudioService.playBase64(narration.audioBase64);
    }
    _tripService.clearInterrupt();

    // Hide learn card
    if (mounted) setState(() => _learnCardVisible = false);
    _learnPlaying = false;

    // Bail if trip ended or widget disposed while learn was playing
    if (!mounted || _tripService.tripState == TripState.idle) return;

    // Re-sync carousel with pool (queue may have changed during interrupt)
    _syncCarouselWithPool();

    // Restore carousel visibility if we have content
    if (_carouselItems.isNotEmpty && mounted) {
      setState(() {
        _carouselVisible = true;
        _carouselOpacity = 1.0;
      });
    }

    // Resume or find next
    if (pausedForLearn && _activeCardIndex >= 0) {
      // We paused audio for the learn interrupt — resume from saved position
      _audioService.resume();
    } else if (!_isPlaying) {
      // Nothing was active (breathe countdown, waiting, etc.) — re-evaluate
      _activateNextCard();
    }
  }

  // ── Core state machine ───────────────────────────────────────────────────

  /// Cleanly shut down the current active card.
  void _deactivateCurrentCard() {
    if (_activeCardIndex < 0) return;
    final card = _activeCard;
    if (card != null) {
      card.lastPosition = _audioService.currentPosition;
      card.deactivate();
    }
    _playingCardId = null;
    _activeCardIndex = -1;
    _audioService.stop();
  }

  /// THE single transition point — activate a card at [index].
  /// Called from: swipe, trip service, play button, auto-advance.
  void _activateCard(int index) {
    if (index < 0 || index >= _carouselItems.length) return;
    final card = _carouselItems[index];
    if (card.isPlaceholder) return;

    // Same card → toggle pause
    if (index == _activeCardIndex) {
      _togglePause();
      return;
    }

    _deactivateCurrentCard();
    _removeWaitingPlaceholder();
    _breatheCountdownTimer?.cancel();

    _activeCardIndex = index;
    card.activate();

    // Align trip service so _currentlyServed and _activeGroupId match
    // the card being played. Critical for trivia (ensures interstitial/
    // answer are served next) and for correct advanceQueue behavior.
    _tripService.serveNarration(card.id);

    if (mounted) {
      setState(() {
        _carouselVisible = true;
        _carouselOpacity = 1.0;
      });
      final targetPage = _activeCardIndex;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_carouselController.hasClients) {
          final currentPage = _carouselController.page?.round() ?? 0;
          if (currentPage != targetPage) {
            _carouselController.animateToPage(
              targetPage,
              duration: const Duration(milliseconds: 350),
              curve: Curves.easeOutCubic,
            );
          }
        }
      });
    }

    _playActiveCard();
  }

  /// Find the next card to activate (from trip service queue).
  void _activateNextCard() {
    // Check if trip service has a narration ready
    final narration = _tripService.pendingNarration;
    if (narration != null) {
      // Trivia group: absorb into active card instead of creating a new one
      final active = _activeCard;
      if (active != null &&
          active.isTrivia &&
          narration.groupId != null &&
          narration.groupId == active.groupId) {
        active.absorb(narration);
        if (mounted) setState(() {});
        _playActiveCard();
        return;
      }

      // Find existing card (from pool sync) or create one
      _removeWaitingPlaceholder();
      var idx = _carouselItems.indexWhere((c) => c.id == narration.narrationId);
      if (idx < 0) {
        final card = NarrationCardItem.fromPending(narration);
        _carouselItems.add(card);
        _carouselNarrationIds.add(narration.narrationId);
        _enforceHistoryLimit();
        idx = _carouselItems.length - 1;
      }
      _activateCard(idx);
      return;
    }

    // Nothing from pendingNarration — check if there's an upcoming candidate
    // behind a breathe timer (show it with countdown on the card).
    final upNext = _tripService.upNextNarration;
    if (upNext != null) {
      _deactivateCurrentCard();
      _removeWaitingPlaceholder();
      // Find or create the card for the upcoming narration
      var idx = _carouselItems.indexWhere((c) => c.id == upNext.narrationId);
      if (idx < 0) {
        final card = NarrationCardItem.fromPending(upNext);
        card.state = NarrationCardState.queued;
        _carouselItems.add(card);
        _carouselNarrationIds.add(upNext.narrationId);
        _enforceHistoryLimit();
        idx = _carouselItems.length - 1;
      }
      final card = _carouselItems[idx];
      final breatheLeft = _tripService.breatheSecondsRemaining;
      if (breatheLeft > 0) {
        card.countdownSeconds = breatheLeft;
        if (mounted) {
          setState(() {
            _carouselVisible = true;
            _carouselOpacity = 1.0;
          });
          _animateToPage(idx);
        }
        _startBreatheCountdown(idx);
      } else {
        // Breathe already expired — activate immediately
        _tripService.skipBreatheTimer();
        _activateCard(idx);
      }
      return;
    }

    // Nothing in pool at all — show waiting placeholder
    _deactivateCurrentCard();
    _addWaitingPlaceholder();
    if (mounted) setState(() {});
  }

  /// Play audio for the currently active card.
  Future<void> _playActiveCard() async {
    final card = _activeCard;
    if (card == null) return;

    final cardId = card.id;
    _playingCardId = cardId;

    // Show carousel
    if (mounted) setState(() {
      _carouselVisible = true;
      _carouselOpacity = 1.0;
    });

    // Play based on content type / trivia phase
    if (card.isTourProgress) {
      await Future.delayed(const Duration(seconds: 4));
    } else if (card.isTriviaInterstitial) {
      await _handleTriviaInterstitial(card);
    } else if (card.isTriviaAnswer && card.answerAudioBase64 != null) {
      // Trivia answer phase — play the answer audio (not the question's)
      await _audioService.playBase64(card.answerAudioBase64!);
    } else if (card.audioBase64 != null) {
      await _audioService.playBase64(card.audioBase64!,
          startFrom: card.lastPosition);
    }

    // Audio finished — check if we're still the active playback
    _onAudioFinished(cardId);
  }

  /// Called when audio playback completes (naturally or via stop).
  void _onAudioFinished(String cardId) {
    // Stale check: if _playingCardId was cleared by _deactivateCurrentCard,
    // another card was activated externally — bail out.
    if (_playingCardId != cardId) return;
    // If paused, don't advance — user will resume manually.
    final card = _activeCard;
    if (card != null && card.paused) return;
    // Guard: learn interrupt or trip ended
    if (_learnPlaying) return;
    if (_tripService.tripState == TripState.idle) return;

    // Save final position
    if (card != null) {
      card.lastPosition = _audioService.currentPosition;
    }

    // Advance queue and find next
    _tripService.advanceQueue();
    _activateNextCard();
  }

  // ── Breathe countdown (on-card) ──────────────────────────────────────────

  void _startBreatheCountdown(int cardIndex) {
    _breatheCountdownTimer?.cancel();
    _breatheCountdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (cardIndex < 0 || cardIndex >= _carouselItems.length) {
        timer.cancel();
        return;
      }
      final card = _carouselItems[cardIndex];
      if (card.countdownSeconds <= 1) {
        timer.cancel();
        _breatheCountdownTimer = null;
        card.countdownSeconds = 0;
        // Breathe done — activate the card
        _tripService.skipBreatheTimer();
        _activateCard(cardIndex);
        return;
      }
      card.countdownSeconds--;
      if (mounted) setState(() {});
    });
  }

  // ── Pause / resume ───────────────────────────────────────────────────────

  void _togglePause() {
    final card = _activeCard;
    if (card == null) return;
    if (card.paused) {
      _audioService.resume();
      card.paused = false;
    } else {
      card.lastPosition = _audioService.currentPosition;
      _audioService.pause();
      card.paused = true;
    }
    if (mounted) setState(() {});
  }

  // ── Swipe handler ────────────────────────────────────────────────────────

  void _onCarouselPageChanged(int index) {
    if (index < 0 || index >= _carouselItems.length) return;
    final card = _carouselItems[index];
    if (card.isPlaceholder) return;

    // Swiped back to active card → resume if paused by swipe-away
    if (index == _activeCardIndex) {
      if (card.paused) {
        _audioService.resume();
        card.paused = false;
        if (mounted) setState(() {});
      }
      return;
    }

    // Swiped to a queued card → skip breathe countdown and activate
    if (card.state == NarrationCardState.queued) {
      _breatheCountdownTimer?.cancel();
      _tripService.skipBreatheTimer();
      _activateCard(index);
      return;
    }

    // Swiped to a history card → pause active audio (don't deactivate)
    if (_isPlaying) {
      final active = _activeCard;
      if (active != null && !active.paused) {
        active.lastPosition = _audioService.currentPosition;
        _audioService.pause();
        active.paused = true;
        if (mounted) setState(() {});
      }
    }
  }

  // ── Trivia interstitial ──────────────────────────────────────────────────

  /// Handle the trivia interstitial pause between question and answer.
  Future<void> _handleTriviaInterstitial(NarrationCardItem card) async {
    final prefs = await SharedPreferences.getInstance();
    final mode = prefs.getString('trivia_reveal_mode') ?? 'auto';

    if (mode == 'instant') return;

    if (mode == 'manual') {
      card.revealCompleter = Completer<void>();
      card.waitingForReveal = true;
      if (mounted) setState(() {});
      await card.revealCompleter!.future;
      card.revealCompleter = null;
      card.waitingForReveal = false;
      if (mounted) setState(() {});
      return;
    }

    // Default: 'auto' countdown
    final seconds = prefs.getInt('trivia_countdown_s') ?? card.revealDelayS ?? 10;
    card.revealCompleter = Completer<void>();
    card.waitingForReveal = true;
    card.countdownSeconds = seconds;
    if (mounted) setState(() {});

    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (card.countdownSeconds <= 1) {
        timer.cancel();
        _countdownTimer = null;
        if (!(card.revealCompleter?.isCompleted ?? true)) {
          card.revealCompleter?.complete();
        }
        return;
      }
      card.countdownSeconds--;
      if (mounted) setState(() {});
    });

    await card.revealCompleter!.future;
    _countdownTimer?.cancel();
    _countdownTimer = null;
    card.revealCompleter = null;
    card.waitingForReveal = false;
    if (mounted) setState(() {});
  }

  /// Immediately reveal the trivia answer.
  void _revealTriviaAnswer() {
    final card = _activeCard;
    if (card?.revealCompleter != null && !card!.revealCompleter!.isCompleted) {
      card.revealCompleter!.complete();
    }
  }

  // ── Carousel helpers ─────────────────────────────────────────────────────

  void _animateToPage(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_carouselController.hasClients) {
        final currentPage = _carouselController.page?.round() ?? 0;
        if (currentPage != index) {
          _carouselController.animateToPage(
            index,
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeOutCubic,
          );
        }
      }
    });
  }

  void _enforceHistoryLimit() {
    const maxCards = 25;
    while (_carouselItems.length > maxCards) {
      _carouselNarrationIds.remove(_carouselItems[0].id);
      _carouselItems.removeAt(0);
      if (_activeCardIndex > 0) _activeCardIndex--;
    }
  }

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

  void _addWaitingPlaceholder() {
    if (_carouselItems.isNotEmpty && _carouselItems.last.isPlaceholder) return;
    _carouselItems.add(NarrationCardItem.waitingPlaceholder());
    if (!_carouselVisible) {
      _carouselVisible = true;
      _carouselOpacity = 1.0;
    }
    _animateToPage(_carouselItems.length - 1);
  }

  void _removeWaitingPlaceholder() {
    _carouselItems.removeWhere((c) => c.isPlaceholder);
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
          urlTemplate: _tileUrl,
          subdomains: _tileSubdomains,
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
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
      bottom: _carouselVisible ? 120 : -600,
      left: 0,
      right: 0,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 500),
        opacity: _carouselOpacity,
        child: _carouselItems.isEmpty
            ? const SizedBox.shrink()
            : _ExpandablePageView(
                controller: _carouselController,
                physics: const BouncingScrollPhysics(),
                onPageChanged: _onCarouselPageChanged,
                itemCount: _carouselItems.length,
                itemBuilder: (context, index) {
                  return _buildCarouselCard(
                    _carouselItems[index],
                    index == _activeCardIndex,
                  );
                },
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
          surfaceTintColor: Colors.transparent,
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

    final isQueued = item.state == NarrationCardState.queued;
    final realCards = _carouselItems.where((c) => !c.isPlaceholder);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Card(
        elevation: 6,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        color: Colors.white,
        surfaceTintColor: Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // "Playing in Xs..." banner for queued cards with breathe delay
              if (isQueued && item.countdownSeconds > 0) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  margin: const EdgeInsets.only(bottom: 10),
                  decoration: BoxDecoration(
                    color: _teal.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'Playing in ${item.countdownSeconds}s...',
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
              if (isActive && item.isTriviaInterstitial && item.waitingForReveal) ...[
                const SizedBox(height: 16),
                if (item.countdownSeconds > 0) ...[
                  Text(
                    'Answer in ${item.countdownSeconds} s...',
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
                      item.countdownSeconds > 0 ? 'Reveal Now' : 'Tap to Reveal Answer',
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
                    () {
                      final cardIndex = _carouselItems.indexOf(item);
                      final showPause = isActive && !item.paused;
                      return SizedBox(
                        height: 42,
                        width: 110,
                        child: ElevatedButton.icon(
                          onPressed: () {
                            if (isActive) {
                              _togglePause();
                            } else if (cardIndex >= 0) {
                              _activateCard(cardIndex);
                            }
                          },
                          icon: Icon(
                            showPause ? Icons.pause : Icons.play_arrow,
                            size: 22,
                          ),
                          label: Text(
                            showPause ? 'Pause' : 'Play',
                            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: showPause
                                ? const Color(0xFFFBBF24) // yellow
                                : const Color(0xFF22C55E), // green
                            foregroundColor: showPause ? Colors.black87 : Colors.white,
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(21),
                            ),
                          ),
                        ),
                      );
                    }(),
                    const SizedBox(width: 10),
                    // Like (heart)
                    SizedBox(
                      width: 42,
                      height: 42,
                      child: IconButton(
                        padding: EdgeInsets.zero,
                        icon: Icon(
                          item.liked ? Icons.favorite : Icons.favorite_border,
                          color: item.liked ? Colors.red : Colors.grey.shade400,
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

// ── Expandable PageView ─────────────────────────────────────────────────────
// A PageView whose height adapts to the current page's content.
// Measures each page's natural height after layout and interpolates smoothly
// as the user swipes between pages.

class _ExpandablePageView extends StatefulWidget {
  final PageController controller;
  final int itemCount;
  final Widget Function(BuildContext, int) itemBuilder;
  final ValueChanged<int>? onPageChanged;
  final ScrollPhysics? physics;
  final double fallbackHeight;

  const _ExpandablePageView({
    required this.controller,
    required this.itemCount,
    required this.itemBuilder,
    this.onPageChanged,
    this.physics,
    this.fallbackHeight = 200.0,
  });

  @override
  State<_ExpandablePageView> createState() => _ExpandablePageViewState();
}

class _ExpandablePageViewState extends State<_ExpandablePageView> {
  final Map<int, double> _heights = {};
  double _currentHeight = 0;

  @override
  void initState() {
    super.initState();
    _currentHeight = widget.fallbackHeight;
    widget.controller.addListener(_onScroll);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onScroll);
    super.dispose();
  }

  void _onScroll() {
    if (!widget.controller.hasClients) return;
    final page = widget.controller.page ?? 0;
    final lower = page.floor().clamp(0, widget.itemCount - 1);
    final upper = page.ceil().clamp(0, widget.itemCount - 1);
    final t = page - page.floor();
    final lowerH = _heights[lower] ?? widget.fallbackHeight;
    final upperH = _heights[upper] ?? widget.fallbackHeight;
    final interpolated = lowerH + (upperH - lowerH) * t;
    if ((interpolated - _currentHeight).abs() > 0.5) {
      setState(() => _currentHeight = interpolated);
    }
  }

  void _onChildSized(int index, double height) {
    if ((_heights[index] ?? 0) == height) return;
    _heights[index] = height;
    // If this is the current page (or we haven't sized yet), update immediately
    final currentPage = widget.controller.hasClients
        ? (widget.controller.page?.round() ?? 0)
        : 0;
    if (index == currentPage) {
      setState(() => _currentHeight = height);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      height: _currentHeight,
      child: PageView.builder(
        controller: widget.controller,
        physics: widget.physics,
        onPageChanged: widget.onPageChanged,
        itemCount: widget.itemCount,
        itemBuilder: (context, index) {
          return OverflowBox(
            minHeight: 0,
            maxHeight: double.infinity,
            alignment: Alignment.bottomCenter,
            child: _SizeReporter(
              onSized: (size) => _onChildSized(index, size.height),
              child: widget.itemBuilder(context, index),
            ),
          );
        },
      ),
    );
  }
}

/// Reports its child's rendered size after every layout.
class _SizeReporter extends StatefulWidget {
  final Widget child;
  final ValueChanged<Size> onSized;
  const _SizeReporter({required this.child, required this.onSized});

  @override
  State<_SizeReporter> createState() => _SizeReporterState();
}

class _SizeReporterState extends State<_SizeReporter> {
  final _key = GlobalKey();
  Size _lastSize = Size.zero;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  void _measure() {
    final rb = _key.currentContext?.findRenderObject() as RenderBox?;
    if (rb != null && rb.hasSize) {
      final size = rb.size;
      if (size != _lastSize) {
        _lastSize = size;
        widget.onSized(size);
      }
    }
  }

  @override
  void didUpdateWidget(covariant _SizeReporter oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(key: _key, child: widget.child);
  }
}
