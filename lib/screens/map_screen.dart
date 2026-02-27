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

  // Active tour
  Tour? _activeTour;
  Set<String> _visitedTourLocations = {};

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
      // Load local cache first (fast)
      final visited = prefs.getStringList('tour_visited_${tour.id}') ?? [];
      setState(() {
        _activeTour = tour;
        _visitedTourLocations = visited.toSet();
      });
      // Then fetch server-side visited locations (authoritative)
      _fetchServerVisitedLocations(tour);
    } else if (mounted) {
      setState(() {
        _activeTour = null;
        _visitedTourLocations = {};
      });
    }
  }

  Future<void> _fetchServerVisitedLocations(Tour tour) async {
    try {
      final token = await AuthService.getIdToken();
      if (token == null) return;
      final locationIdsParam = tour.locationIds.join(',');
      final response = await http.get(
        Uri.parse('$_backendBase/user/visited-locations?location_ids=$locationIdsParam'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200 && mounted) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final visited = (data['visited'] as List)
            .map((v) => (v as Map<String, dynamic>)['location_id'] as String)
            .toSet();
        setState(() => _visitedTourLocations = visited);
        // Persist locally for offline
        final prefs = await SharedPreferences.getInstance();
        prefs.setStringList('tour_visited_${tour.id}', visited.toList());
      }
    } catch (e) {
      debugPrint('MapScreen fetchServerVisited error: $e');
    }
  }

  void _trackTourProgress(String? locationId) {
    if (_activeTour == null || locationId == null) return;
    if (!_activeTour!.locationIds.contains(locationId)) return;
    if (_visitedTourLocations.contains(locationId)) return;
    setState(() => _visitedTourLocations.add(locationId));
    SharedPreferences.getInstance().then((prefs) {
      prefs.setStringList(
          'tour_visited_${_activeTour!.id}', _visitedTourLocations.toList());
    });
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
    if (_tripService.pendingNarration != null && !_playingNarration) {
      _playNarration();
    }
  }

  Future<void> _playNarration() async {
    final narration = _tripService.pendingNarration;
    if (narration == null) return;
    _playingNarration = true;
    _trackTourProgress(narration.locationId);
    if (mounted) setState(() => _narrationVisible = true);

    if (narration.isTourProgress) {
      // Tour progress notification — show card briefly, no audio playback
      await Future.delayed(const Duration(seconds: 4));
    } else {
      // Normal story narration — play audio
      _positionStreamSub?.cancel();
      _positionStreamSub =
          _audioService.positionStream.listen(_onAudioPositionChanged);

      await _audioService.playBase64(narration.audioBase64);

      _positionStreamSub?.cancel();
      _positionStreamSub = null;
    }

    // Advance queue (confirms played to backend, removes from local queue)
    _tripService.advanceQueue();

    // If more narrations in queue, play next after brief pause
    if (_tripService.pendingNarration != null) {
      // Reset scroll for the next narration
      if (_narrationScrollController.hasClients) {
        _narrationScrollController.jumpTo(0);
      }
      if (mounted) setState(() {}); // refresh card with new narration info
      await Future.delayed(const Duration(milliseconds: 500));
      if (mounted && _tripService.pendingNarration != null) {
        _playingNarration = false;
        _playNarration();
        return;
      }
    }

    if (mounted) setState(() => _narrationVisible = false);
    _playingNarration = false;
  }

  void _onAudioPositionChanged(Duration position) {
    final total = _audioService.duration;
    if (total == null || total.inMilliseconds == 0) return;
    if (!_narrationScrollController.hasClients) return;
    final progress = position.inMilliseconds / total.inMilliseconds;
    final maxScroll = _narrationScrollController.position.maxScrollExtent;
    _narrationScrollController
        .jumpTo((progress * maxScroll).clamp(0.0, maxScroll));
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
            _buildTourProgressCard(),
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
        // Zone overlays — polygons
        PolygonLayer(
          polygons: _locations
              .where((loc) => loc.isPolygon)
              .map((loc) => Polygon(
                    points: loc.polygonCoordinates
                        .map((c) => LatLng(c[0], c[1]))
                        .toList(),
                    color: const Color(0x330d9488),
                    borderColor: _teal,
                    borderStrokeWidth: 1,
                  ))
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

  // ── Narration card ─────────────────────────────────────────────────────────

  Widget _buildNarrationCard() {
    final narration = _tripService.pendingNarration;
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
      bottom: _narrationVisible ? 120 : -250,
      left: 16,
      right: 16,
      child: Card(
        elevation: 8,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Top row: guide photo + location name + narrator
              Row(
                children: [
                  // Guide photo or fallback icon
                  _buildGuideAvatar(narration),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          narration?.locationName ?? '',
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 16),
                        ),
                        if ((narration?.narrator ?? '').isNotEmpty)
                          Text(
                            narration!.narrator,
                            style: const TextStyle(
                                color: Colors.grey, fontSize: 13),
                          ),
                      ],
                    ),
                  ),
                  // Queue badge ("2 of 5")
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
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                ],
              ),
              // Narration text (scrolling)
              if ((narration?.narrationText ?? '').isNotEmpty) ...[
                const SizedBox(height: 10),
                const Divider(height: 1),
                const SizedBox(height: 8),
                SizedBox(
                  height: 52,
                  child: ShaderMask(
                    shaderCallback: (bounds) => const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.white, Colors.white, Colors.transparent],
                      stops: [0.0, 0.7, 1.0],
                    ).createShader(bounds),
                    blendMode: BlendMode.dstIn,
                    child: SingleChildScrollView(
                      controller: _narrationScrollController,
                      physics: const ClampingScrollPhysics(),
                      child: Text(
                        narration!.narrationText,
                        style: const TextStyle(
                          fontSize: 13,
                          height: 1.4,
                          color: Color(0xFF444444),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGuideAvatar(PendingNarration? narration) {
    if (narration?.isTourProgress == true) {
      return Container(
        width: 48,
        height: 48,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: Color(0xFFFFF8E1),
        ),
        child: const Icon(Icons.emoji_events, color: Color(0xFFF9A825), size: 26),
      );
    }
    if (narration?.guidePhotoUrl != null) {
      return ClipOval(
        child: Image.network(
          narration!.guidePhotoUrl!,
          width: 48,
          height: 48,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _fallbackAvatar(),
        ),
      );
    }
    return _fallbackAvatar();
  }

  Widget _fallbackAvatar() {
    return Container(
      width: 48,
      height: 48,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: Color(0xFFe0f2f1),
      ),
      child: const Icon(Icons.volume_up, color: _teal, size: 24),
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
        borderRadius: BorderRadius.circular(28),
        color: Colors.white,
        child: InkWell(
          borderRadius: BorderRadius.circular(28),
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
    final top = MediaQuery.of(context).padding.top + 62;
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
    final top = MediaQuery.of(context).padding.top + 62;
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

  // ── Tour progress card ──────────────────────────────────────────────────────

  Widget _buildTourProgressCard() {
    if (_activeTour == null || !_narrationVisible) {
      return const SizedBox.shrink();
    }
    final narration = _tripService.pendingNarration;
    // Only show if the current narration is for a tour location
    if (narration?.locationId == null ||
        !_activeTour!.locationIds.contains(narration!.locationId)) {
      return const SizedBox.shrink();
    }
    final visited = _visitedTourLocations.length;
    final total = _activeTour!.locationCount;
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
      bottom: _narrationVisible ? 290 : -80,
      left: 16,
      right: 16,
      child: Card(
        elevation: 8,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              const Icon(Icons.map_outlined, color: _teal, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _activeTour!.name,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 14),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                '$visited of $total',
                style: const TextStyle(
                    color: _teal, fontWeight: FontWeight.w600, fontSize: 14),
              ),
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
