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

part 'map_screen_carousel.dart';
part 'map_screen_controls.dart';
part 'map_screen_nearby.dart';
part 'map_screen_learn.dart';
part 'map_screen_pills.dart';
part 'map_screen_widgets.dart';

// ── Constants ────────────────────────────────────────────────────────────────

const String _kBackendBase =
    'https://tour-guide-backend-production.up.railway.app';
const Color _kTeal = Color(0xFF0d9488);

// ── Map screen ──────────────────────────────────────────────────────────────

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
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
  // Incremented each time _playActiveCard is (re)entered; stale loops see
  // a mismatched generation and exit. Solves: learn interrupt during breathe,
  // pause/unpause during non-audio phases, etc.
  int _playGeneration = 0;

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
    super.dispose();
  }

  // ── Locations ───────────────────────────────────────────────────────────────

  Future<void> _fetchLocations() async {
    try {
      final response = await http
          .get(Uri.parse('$_kBackendBase/locations/active'))
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
            Uri.parse('$_kBackendBase/auth/sync'),
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
    if (event.source == MapEventSource.dragEnd ||
        event.source == MapEventSource.multiFingerEnd) {
      if (_followingUser) {
        setState(() => _followingUser = false);
      }
    }
  }

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
      _deactivateCurrentCard();
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
      _syncCarouselWithPool();
      return;
    }
    _syncCarouselWithPool();
    if (!_isPlaying) {
      _activateNextCard();
    }
  }

  // ── Learn / preview interrupt ────────────────────────────────────────────

  Future<void> _startLearnPlayback() async {
    _learnPlaying = true;

    final hadActiveCard = _activeCardIndex >= 0;
    final activeCard = _activeCard;
    if (activeCard != null && !activeCard.paused) {
      activeCard.lastPosition = _audioService.currentPosition;
      _audioService.pause();
    }
    // Kill any running phase loop (breathe Future.delayed, trivia, etc.)
    _playGeneration++;

    if (mounted) setState(() {
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

    if (!mounted || _tripService.tripState == TripState.idle) return;

    _syncCarouselWithPool();

    if (_carouselItems.isNotEmpty && mounted) {
      setState(() {
        _carouselVisible = true;
        _carouselOpacity = 1.0;
      });
    }

    if (hadActiveCard && _activeCardIndex >= 0) {
      // Re-enter phase loop from current phase; breathe recalculates remaining
      // time, audio resumes from lastPosition, trivia restarts countdown.
      _playActiveCard();
    } else if (!_isPlaying) {
      _activateNextCard();
    }
  }

  // ── Core state machine ───────────────────────────────────────────────────

  void _deactivateCurrentCard() {
    if (_activeCardIndex < 0) return;
    final card = _activeCard;
    if (card != null) {
      card.lastPosition = _audioService.currentPosition;
      card.deactivate();
    }
    _playingCardId = null;
    _playGeneration++; // kill any running phase loop
    _activeCardIndex = -1;
    _audioService.stop();
  }

  void _activateCard(int index, {bool skipBreathe = false}) {
    if (index < 0 || index >= _carouselItems.length) return;
    final card = _carouselItems[index];
    if (card.isPlaceholder) return;

    if (index == _activeCardIndex) {
      _togglePause();
      return;
    }

    _deactivateCurrentCard();
    _removeWaitingPlaceholder();

    // Re-find index after placeholder removal may have shifted items
    final adjustedIndex = _carouselItems.indexOf(card);
    if (adjustedIndex < 0) return;

    _activeCardIndex = adjustedIndex;
    card.activate(skipBreathe: skipBreathe);

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

  void _activateNextCard() {
    final currentPage = _carouselController.hasClients
        ? (_carouselController.page?.round() ?? 0)
        : 0;

    for (int i = currentPage; i < _carouselItems.length; i++) {
      final card = _carouselItems[i];
      if (card.isPlaceholder || card.completed) continue;
      if (card.state == NarrationCardState.queued) {
        _activateCard(i);
        return;
      }
    }

    _deactivateCurrentCard();
    _addWaitingPlaceholder();
    if (mounted) setState(() {});
  }

  NarrationCardItem _createGroupCard(PendingNarration narration) {
    final group = narration.groupId != null
        ? _tripService.getGroupNarrations(narration.groupId)
        : <PendingNarration>[];
    return NarrationCardItem.fromGroup(
        group.isNotEmpty ? group : [narration]);
  }

  Future<void> _playActiveCard() async {
    final card = _activeCard;
    if (card == null) return;

    final cardId = card.id;
    _playingCardId = cardId;
    final gen = ++_playGeneration;

    if (mounted) setState(() {
      _carouselVisible = true;
      _carouselOpacity = 1.0;
    });

    do {
      if (_playGeneration != gen) return;
      final phase = card.currentPhase;

      switch (phase.type) {
        case PhaseType.breatheDelay:
          final breatheLeft = _tripService.breatheSecondsRemaining;
          if (breatheLeft > 0) {
            card.breatheTotalSeconds = breatheLeft;
            card.breatheActive = true;
            if (mounted) setState(() {});
            await Future.delayed(Duration(seconds: breatheLeft));
            card.breatheActive = false;
            if (mounted) setState(() {});
            _tripService.skipBreatheTimer();
            if (_playGeneration != gen) return;
          }
        case PhaseType.tourProgressDelay:
          await Future.delayed(const Duration(seconds: 4));
        case PhaseType.triviaInterstitial:
          if (mounted) setState(() {});
          await _handleTriviaInterstitial(card, gen);
        case PhaseType.audio:
          if (phase.audioBase64 != null) {
            if (mounted) setState(() {});
            await _audioService.playBase64(
              phase.audioBase64!,
              startFrom: card.lastPosition,
            );
          }
      }

      if (_playGeneration != gen) return;
      if (card.paused) return;
    } while (card.advancePhase());

    _onCardComplete(cardId);
  }

  void _onCardComplete(String cardId) {
    if (_playingCardId != cardId) return;
    if (_learnPlaying) return;
    if (_tripService.tripState == TripState.idle) return;

    final card = _activeCard;
    if (card == null) return;

    card.completed = true;
    final fromIndex = _activeCardIndex;

    final inPool = card.narrationIds.any(
      (id) => _tripService.narrationPool.any((n) => n.narrationId == id),
    );
    if (inPool) {
      _tripService.advanceGroup(card.narrationIds);
    }

    _syncCarouselWithPool();
    _advanceForward(fromIndex);
  }

  void _advanceForward(int fromIndex) {
    _deactivateCurrentCard();

    int nextIdx = fromIndex + 1;
    while (nextIdx < _carouselItems.length &&
        _carouselItems[nextIdx].isPlaceholder) {
      nextIdx++;
    }

    if (nextIdx >= _carouselItems.length) {
      _addWaitingPlaceholder();
      if (mounted) setState(() {});
      return;
    }

    final nextCard = _carouselItems[nextIdx];

    if (nextCard.completed) {
      _animateToPage(nextIdx);
      if (mounted) setState(() {});
      return;
    }

    _activateCard(nextIdx);
  }

  // ── Pause / resume ───────────────────────────────────────────────────────

  void _togglePause() {
    final card = _activeCard;
    if (card == null) return;
    if (card.paused) {
      card.paused = false;
      if (card.currentPhase.type == PhaseType.audio) {
        _audioService.resume();
      } else {
        // Non-audio phase (breathe, trivia, etc.) — the old loop exited on
        // card.paused; re-enter from the current phase.
        _playActiveCard();
      }
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

    if (index == _activeCardIndex) {
      if (card.paused) {
        _audioService.resume();
        card.paused = false;
        if (mounted) setState(() {});
      }
      return;
    }

    if (card.completed) {
      _deactivateCurrentCard();
      if (mounted) setState(() {});
      return;
    }

    _activateCard(index, skipBreathe: true);
  }

  // ── Trivia interstitial ──────────────────────────────────────────────────

  Future<void> _handleTriviaInterstitial(NarrationCardItem card, int gen) async {
    final prefs = await SharedPreferences.getInstance();
    if (_playGeneration != gen) return;
    final mode = prefs.getString('trivia_reveal_mode') ?? 'auto';

    if (mode == 'instant') return;

    final completer = Completer<void>();
    card.revealCompleter = completer;
    card.waitingForReveal = true;

    if (mode == 'manual') {
      if (mounted) setState(() {});
      await completer.future;
      card.revealCompleter = null;
      card.waitingForReveal = false;
      if (mounted) setState(() {});
      return;
    }

    final seconds = prefs.getInt('trivia_countdown_s') ?? card.currentPhase.revealDelayS ?? 10;
    card.countdownSeconds = seconds;
    if (mounted) setState(() {});

    // Auto-reveal after countdown; manual reveal completes early.
    // Capture completer locally so a stale timer can't complete a fresh one.
    Future.delayed(Duration(seconds: seconds), () {
      if (!completer.isCompleted) completer.complete();
    });

    await completer.future;
    card.revealCompleter = null;
    card.waitingForReveal = false;
    if (mounted) setState(() {});
  }

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
      if (narration.groupId != null && narration.groupSeq != 0) continue;
      if (_carouselNarrationIds.contains(narration.narrationId)) continue;
      if (narration.groupId != null && seenGroups.contains(narration.groupId)) continue;

      final card = _createGroupCard(narration);
      card.state = NarrationCardState.queued;
      _carouselItems.add(card);
      for (final id in card.narrationIds) {
        _carouselNarrationIds.add(id);
      }
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
            buildNarrationCarousel(),
            _buildCenterButton(),
            buildTripControls(),
            _buildVersionLabel(),
            buildNearbyCard(),
            buildLearnCard(),
            buildPills(),
          ],
        ),
      ),
    );
  }

  Widget _buildMap() {
    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: const LatLng(38.9072, -77.0369),
        initialZoom: 12,
        onMapEvent: _onMapEvent,
      ),
      children: [
        TileLayer(
          urlTemplate: _tileUrl,
          subdomains: _tileSubdomains,
          userAgentPackageName: 'com.tourguide.app',
        ),
        MarkerLayer(
          markers: _locations
              .map((loc) => Marker(
                    point: LatLng(loc.lat, loc.lng),
                    width: 12,
                    height: 12,
                    child: Container(
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: _kTeal,
                      ),
                    ),
                  ))
              .toList(),
        ),
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
                child: Icon(Icons.my_location, color: _kTeal, size: 22),
              ),
            ),
          ),
        ),
      ),
    );
  }

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
}
