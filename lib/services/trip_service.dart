import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../auth_service.dart';

enum TripState { idle, active, paused }

/// Represents a narration pulled from the server queue.
class PendingNarration {
  final String narrationId;
  final String locationName;
  final String narrator;
  final String audioBase64;
  final String narrationText;
  final String? guidePhotoUrl;
  final String? locationId;
  final String topic;
  final String? tourId;
  final String? storyTitle;
  final String contentType;   // 'story', 'trivia_question', 'trivia_interstitial', 'trivia_answer', 'tour_progress'
  final String? groupId;
  final int groupSeq;
  final int? revealDelayS;
  // Pacing fields
  final String? storyId;
  final String? triviaId;
  final double? locationLat;
  final double? locationLng;
  final double geofenceRadiusM;
  final String triggerGeometryType; // 'circle', 'multipolygon', 'polygon'
  final String locationType;
  final int delayS;
  final int playOrder;

  const PendingNarration({
    required this.narrationId,
    required this.locationName,
    required this.narrator,
    required this.audioBase64,
    this.narrationText = '',
    this.guidePhotoUrl,
    this.locationId,
    this.topic = 'location',
    this.tourId,
    this.storyTitle,
    this.contentType = 'story',
    this.groupId,
    this.groupSeq = 0,
    this.revealDelayS,
    this.storyId,
    this.triviaId,
    this.locationLat,
    this.locationLng,
    this.geofenceRadiusM = 300,
    this.triggerGeometryType = 'circle',
    this.locationType = 'Other',
    this.delayS = 0,
    this.playOrder = 0,
  });

  bool get isTourProgress => contentType == 'tour_progress' || topic == 'tour_progress';
  bool get isTriviaQuestion => contentType == 'trivia_question';
  bool get isTriviaInterstitial => contentType == 'trivia_interstitial';
  bool get isTriviaAnswer => contentType == 'trivia_answer';
  bool get isTrivia => contentType.startsWith('trivia_');
}

/// Manages trip state, GPS pinging, and narration pool with priority scheduling.
///
/// State machine:
///   idle → active    startTrip()   force_new_session ping → save tripId → start 15s timer
///   active → paused  pauseTrip()   cancel timer, keep tripId
///   paused → active  resumeTrip()  restart 15s timer
///   active/paused→idle stopTrip()  POST /session/end → clear tripId + timer
///
/// Narration flow:
///   /ping queues stories server-side → mobile eagerly dequeues all into local pool
///   → _resolveNext() picks highest-priority in-geofence narration respecting breathe timer
///   → MapScreen plays sequentially → advanceQueue() confirms each as played
class TripService extends ChangeNotifier {
  static const String _backendBase =
      'https://tour-guide-backend-production.up.railway.app';
  static const Duration _pingInterval = Duration(seconds: 15);

  TripState _tripState = TripState.idle;
  String? _tripId;
  String _deviceId = '';
  Timer? _pingTimer;

  // ── Narration pool (priority-based, replaces FIFO queue) ────────────────
  final List<PendingNarration> _narrationPool = [];
  bool _draining = false;
  int _totalNarrationsInBatch = 0;
  int _playedInBatch = 0;

  // ── Dedup (discard duplicates if backend re-sends) ──────────────────────
  final Set<String> _seenStoryIds = {};
  final Set<String> _seenTriviaIds = {};

  // ── Position (updated on each ping, used for geofence checks) ───────────
  double _currentLat = 0;
  double _currentLng = 0;

  // ── Pacing ──────────────────────────────────────────────────────────────
  double _defaultBreatheS = 3;
  double _userMinBreatheS = 0;
  DateTime? _lastPlaybackEndedAt;
  Timer? _breatheTimer;

  // ── Trivia group atomicity ──────────────────────────────────────────────
  String? _activeGroupId;

  // ── Currently served to MapScreen ───────────────────────────────────────
  PendingNarration? _currentlyServed;

  TripState get tripState => _tripState;
  String? get tripId => _tripId;
  String get deviceId => _deviceId;
  bool get isActive => _tripState == TripState.active;

  /// The narration currently being played or next to play.
  /// Uses priority scheduling: highest-priority in-geofence item wins.
  /// Returns null during breathe cooldown or if pool is empty.
  PendingNarration? get pendingNarration {
    if (_currentlyServed != null) return _currentlyServed;
    final next = _resolveNext();
    if (next != null) {
      _currentlyServed = next;
      if (next.isTrivia && next.groupId != null) {
        _activeGroupId = next.groupId;
      }
    }
    return _currentlyServed;
  }

  /// Number of narrations remaining in the local pool.
  int get narrationQueueLength => _narrationPool.length;

  /// Total narrations in the current batch (for "X of Y" display).
  int get totalNarrationsInBatch => _totalNarrationsInBatch;

  /// 1-based index of the narration currently playing.
  int get currentPlayingIndex => _playedInBatch + 1;

  TripService() {
    _loadDeviceId();
    _loadUserPreferences();
  }

  Future<void> _loadDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString('device_id') ?? '';
    if (id.isEmpty) {
      id = const Uuid().v4();
      await prefs.setString('device_id', id);
    }
    _deviceId = id;
  }

  Future<void> _loadUserPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    _userMinBreatheS = (prefs.getInt('min_breathe_s') ?? 0).toDouble();
  }

  /// Reload user preferences (call from Settings when min breathe time changes).
  Future<void> refreshPreferences() async {
    await _loadUserPreferences();
  }

  // ── Trip lifecycle ──────────────────────────────────────────────────────────

  Future<void> startTrip() async {
    if (_tripState != TripState.idle) return;
    _clearPool(); // ensure clean state (guards against stop/drain race)
    _tripState = TripState.active;
    notifyListeners();
    await _doPing(forceNewSession: true);
    _startTimer();
  }

  void pauseTrip() {
    if (_tripState != TripState.active) return;
    _tripState = TripState.paused;
    _pingTimer?.cancel();
    _pingTimer = null;
    notifyListeners();
  }

  void resumeTrip() {
    if (_tripState != TripState.paused) return;
    _tripState = TripState.active;
    notifyListeners();
    _startTimer();
  }

  Future<void> stopTrip() async {
    if (_tripState == TripState.idle) return;
    _pingTimer?.cancel();
    _pingTimer = null;
    final tripId = _tripId;
    _tripState = TripState.idle;
    _tripId = null;
    _clearPool();
    notifyListeners();
    if (tripId != null) {
      await _endSession(tripId);
    }
  }

  // ── Timer ───────────────────────────────────────────────────────────────────

  void _startTimer() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(_pingInterval, (_) => _doPing());
  }

  // ── Ping ────────────────────────────────────────────────────────────────────

  Future<void> _doPing({bool forceNewSession = false}) async {
    if (_deviceId.isEmpty) return;
    try {
      final bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return;
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      ).timeout(const Duration(seconds: 10));

      // Update position for geofence checks
      _currentLat = position.latitude;
      _currentLng = position.longitude;

      final headers = <String, String>{'Content-Type': 'application/json'};
      final token = await AuthService.getIdToken();
      if (token != null) headers['Authorization'] = 'Bearer $token';

      final response = await http.post(
        Uri.parse('$_backendBase/ping'),
        headers: headers,
        body: jsonEncode({
          'device_id': _deviceId,
          'latitude': position.latitude,
          'longitude': position.longitude,
          'force_new_session': forceNewSession,
        }),
      ).timeout(const Duration(seconds: 15));

      debugPrint('PING response status=${response.statusCode}');
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final sid = data['session_id'] as String?;
        if (sid != null && _tripId == null) { _tripId = sid; }

        final queuedCount = (data['queued_count'] as num?)?.toInt() ?? 0;
        final pendingCount = (data['pending_count'] as num?)?.toInt() ?? 0;
        debugPrint('PING queued=$queuedCount pending=$pendingCount tripId=$_tripId poolSize=${_narrationPool.length}');
        if (pendingCount > 0 && _tripId != null) {
          _drainServerQueue();
        }
      }

      // Position changed → re-evaluate geofence eligibility
      notifyListeners();
    } catch (e, st) {
      debugPrint('TripService ping error: $e\n$st');
    }
  }

  // ── Dequeue: eagerly pull all pending narrations from server ──────────────

  Future<void> _drainServerQueue() async {
    if (_draining || _tripId == null) {
      debugPrint('DRAIN skipped: draining=$_draining tripId=$_tripId');
      return;
    }
    _draining = true;
    debugPrint('DRAIN starting');
    try {
      while (true) {
        final result = await _dequeueGroup();
        if (result == null) break; // nothing left
      }
    } finally {
      _draining = false;
      debugPrint('DRAIN done: poolSize=${_narrationPool.length} seenStories=${_seenStoryIds.length}');
    }
  }

  /// Dequeue a narration group from the server. Returns the first narration
  /// in the group, or null if nothing is available. All narrations in the
  /// group are added to the local pool.
  Future<PendingNarration?> _dequeueGroup() async {
    if (_tripId == null) return null;
    try {
      final response = await http.post(
        Uri.parse('$_backendBase/narration/dequeue'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'session_id': _tripId}),
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        if (data['available'] != true) return null;

        // Read server breathe config
        final breathe = data['default_breathe_s'];
        if (breathe != null) {
          _defaultBreatheS = (breathe as num).toDouble();
        }

        // Check for narrations array (group-aware response)
        final narrationsList = data['narrations'] as List?;
        PendingNarration? first;

        if (narrationsList != null && narrationsList.isNotEmpty) {
          // Parse all narrations in the group
          for (final item in narrationsList) {
            final m = item as Map<String, dynamic>;
            final narration = _parseNarration(m, data);
            if (_isDuplicate(narration)) {
              debugPrint('DEQUEUE skip duplicate: storyId=${narration.storyId} triviaId=${narration.triviaId}');
              continue;
            }
            _narrationPool.add(narration);
            _markSeen(narration);
            first ??= narration;
          }
        } else {
          // Fallback: flat fields (backward compat for older servers)
          final narration = _parseNarration(data, data);
          if (!_isDuplicate(narration)) {
            _narrationPool.add(narration);
            _markSeen(narration);
            first = narration;
          }
        }

        _totalNarrationsInBatch = _narrationPool.length + _playedInBatch;
        notifyListeners();
        return first;
      }
    } catch (e) {
      debugPrint('TripService dequeue error: $e');
    }
    return null;
  }

  PendingNarration _parseNarration(Map<String, dynamic> m, Map<String, dynamic> envelope) {
    final guideId = m['guide_id'] as String?;
    return PendingNarration(
      narrationId: m['narration_id'] as String,
      locationName: m['subject'] as String? ?? '',
      narrator: m['narrator'] as String? ?? '',
      audioBase64: m['audio'] as String? ?? '',
      narrationText: m['narration_text'] as String? ?? '',
      guidePhotoUrl: guideId != null
          ? '$_backendBase/tour-guides/$guideId/photo'
          : null,
      locationId: m['location_id'] as String?,
      topic: envelope['topic'] as String? ?? m['topic'] as String? ?? 'location',
      tourId: m['tour_id'] as String?,
      storyTitle: m['story_title'] as String?,
      contentType: m['content_type'] as String? ?? 'story',
      groupId: envelope['group_id'] as String? ?? m['group_id'] as String?,
      groupSeq: (m['group_seq'] as num?)?.toInt() ?? 0,
      revealDelayS: (m['reveal_delay_s'] as num?)?.toInt(),
      // Pacing fields from enriched dequeue response
      storyId: m['story_id'] as String?,
      triviaId: m['trivia_id'] as String?,
      locationLat: (m['location_lat'] as num?)?.toDouble(),
      locationLng: (m['location_lng'] as num?)?.toDouble(),
      geofenceRadiusM: (m['trigger_radius_m'] as num?)?.toDouble() ?? 300,
      triggerGeometryType: (m['trigger_geometry'] as Map<String, dynamic>?)?['type'] as String? ?? 'circle',
      locationType: m['location_type'] as String? ?? 'Other',
      delayS: (m['delay_s'] as num?)?.toInt() ?? 0,
      playOrder: (m['play_order'] as num?)?.toInt() ?? 0,
    );
  }

  // ── Dedup ───────────────────────────────────────────────────────────────────

  bool _isDuplicate(PendingNarration n) {
    if (n.storyId != null && _seenStoryIds.contains(n.storyId)) return true;
    // For trivia groups, only dedup on the question (groupSeq 0).
    // Interstitial and answer share the same triviaId and must pass through.
    if (n.triviaId != null && n.groupSeq == 0 && _seenTriviaIds.contains(n.triviaId)) return true;
    return false;
  }

  void _markSeen(PendingNarration n) {
    if (n.storyId != null) _seenStoryIds.add(n.storyId!);
    if (n.triviaId != null && n.groupSeq == 0) _seenTriviaIds.add(n.triviaId!);
  }

  // ── Priority resolution ─────────────────────────────────────────────────────

  /// Select the next candidate from the pool (ignoring breathe timing).
  /// Used by both _resolveNext() and the public up-next getters.
  PendingNarration? _selectCandidate() {
    if (_narrationPool.isEmpty) return null;

    // 1. Trivia group continuation (atomic — no breathe/priority/geofence)
    if (_activeGroupId != null) {
      final groupItems = _narrationPool
          .where((n) => n.groupId == _activeGroupId)
          .toList()
        ..sort((a, b) => a.groupSeq.compareTo(b.groupSeq));
      if (groupItems.isNotEmpty) return groupItems.first;
      _activeGroupId = null; // group exhausted
    }

    // 2. Filter to items in geofence (or items without location data)
    final eligible = _narrationPool.where(_isInGeofence).toList();
    if (eligible.isEmpty) return null;

    // 3. Sort by priority (higher = more specific location = plays first),
    //    then by play_order (admin-configured sequence within same priority)
    eligible.sort((a, b) {
      final priCmp =
          _priorityOf(b.locationType).compareTo(_priorityOf(a.locationType));
      if (priCmp != 0) return priCmp;
      return a.playOrder.compareTo(b.playOrder);
    });
    return eligible.first;
  }

  PendingNarration? _resolveNext() {
    final candidate = _selectCandidate();
    if (candidate == null) {
      debugPrint('RESOLVE pool empty or no eligible');
      return null;
    }
    debugPrint('RESOLVE pool=${_narrationPool.length} lastPlayed=$_lastPlaybackEndedAt');

    // Check breathe/delay timing
    //    delay_s > 0 → admin explicitly set this story's gap (use it)
    //    delay_s == 0 → no specific gap, fall back to server default breathe
    //    User min breathe is always applied as a floor on top.
    if (_lastPlaybackEndedAt != null) {
      final storyDelay = candidate.delayS > 0
          ? candidate.delayS.toDouble()
          : _defaultBreatheS;
      final effectiveWait = max(storyDelay, _userMinBreatheS);
      final elapsed =
          DateTime.now().difference(_lastPlaybackEndedAt!).inSeconds;
      if (elapsed < effectiveWait) return null;
    }

    return candidate;
  }

  /// The next narration that will play after the breathe gap.
  /// Returns null if pool is empty or a narration is currently being served.
  PendingNarration? get upNextNarration {
    if (_currentlyServed != null) return null;
    return _selectCandidate();
  }

  /// Seconds remaining in the breathe gap for the next candidate.
  /// Returns 0 if no gap is active.
  int get breatheSecondsRemaining {
    if (_lastPlaybackEndedAt == null) return 0;
    final candidate = _selectCandidate();
    if (candidate == null) return 0;
    final storyDelay = candidate.delayS > 0
        ? candidate.delayS.toDouble()
        : _defaultBreatheS;
    final effectiveWait = max(storyDelay, _userMinBreatheS);
    final elapsed =
        DateTime.now().difference(_lastPlaybackEndedAt!).inSeconds;
    return max(0, effectiveWait.toInt() - elapsed);
  }

  bool _isInGeofence(PendingNarration n) {
    if (n.locationLat == null || n.locationLng == null) return true;
    if (_currentLat == 0 && _currentLng == 0) return true;
    // Polygon-based geometries (multipolygon, polygon): the backend already
    // verified the user was inside the shape when it queued the story.
    // Mobile can't recheck polygons, so trust the backend determination.
    if (n.triggerGeometryType != 'circle') return true;
    final dist = _haversineMeters(
        _currentLat, _currentLng, n.locationLat!, n.locationLng!);
    return dist <= n.geofenceRadiusM;
  }

  static int _priorityOf(String locationType) {
    switch (locationType) {
      case 'Landmark': return 8;
      case 'Neighborhood': return 7;
      case 'Town': return 6;
      case 'City': return 5;
      case 'County': return 4;
      case 'State': return 3;
      case 'Nation': return 2;
      case 'World': return 1;
      default: return 4; // 'Other' → same as County
    }
  }

  static double _haversineMeters(
      double lat1, double lng1, double lat2, double lng2) {
    const R = 6371000.0; // Earth radius in meters
    final dLat = _toRad(lat2 - lat1);
    final dLng = _toRad(lng2 - lng1);
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_toRad(lat1)) * cos(_toRad(lat2)) *
        sin(dLng / 2) * sin(dLng / 2);
    return R * 2 * atan2(sqrt(a), sqrt(1 - a));
  }

  static double _toRad(double deg) => deg * pi / 180;

  // ── Breathe timer ───────────────────────────────────────────────────────────

  void _startBreatheTimer() {
    _breatheTimer?.cancel();
    final waitS = [_defaultBreatheS, _userMinBreatheS].reduce(max).toInt();
    _breatheTimer = Timer(Duration(seconds: waitS), () {
      _breatheTimer = null;
      notifyListeners(); // wake up MapScreen to check pendingNarration
    });
  }

  // ── Queue management (called by MapScreen after playback) ─────────────────

  /// Remove the served narration after playback and confirm it as played.
  void advanceQueue() {
    if (_currentlyServed == null) return;
    final played = _currentlyServed!;
    _narrationPool.removeWhere((n) => n.narrationId == played.narrationId);
    _playedInBatch++;
    _currentlyServed = null;

    // Fire-and-forget played confirmation to backend
    _confirmPlayed(played.narrationId);

    // Check if trivia group is continuing
    final groupContinues = played.groupId != null &&
        _narrationPool.any((n) => n.groupId == played.groupId);

    if (!groupContinues) {
      // Group done or non-group item → start breathe timer
      // Breathe gap = time from when audio ends (or is skipped) to next narration.
      _activeGroupId = null;
      _lastPlaybackEndedAt = DateTime.now();
      _startBreatheTimer();
    }

    if (_narrationPool.isEmpty) {
      _totalNarrationsInBatch = 0;
      _playedInBatch = 0;
    }
    notifyListeners();
  }

  Future<void> _confirmPlayed(String narrationId) async {
    try {
      final headers = <String, String>{'Content-Type': 'application/json'};
      final token = await AuthService.getIdToken();
      if (token != null) headers['Authorization'] = 'Bearer $token';
      await http.post(
        Uri.parse('$_backendBase/narration/played'),
        headers: headers,
        body: jsonEncode({'narration_id': narrationId}),
      ).timeout(const Duration(seconds: 10));
    } catch (e) {
      debugPrint('TripService confirmPlayed error: $e');
    }
  }

  void _clearPool() {
    _narrationPool.clear();
    _seenStoryIds.clear();
    _seenTriviaIds.clear();
    _totalNarrationsInBatch = 0;
    _playedInBatch = 0;
    _draining = false;
    _currentlyServed = null;
    _activeGroupId = null;
    _lastPlaybackEndedAt = null;
    _breatheTimer?.cancel();
    _breatheTimer = null;
  }

  // ── Clear play history ──────────────────────────────────────────────────────

  /// Call DELETE /user/play-history to reset cross-trip dedup.
  Future<bool> clearPlayHistory() async {
    try {
      final token = await AuthService.getIdToken();
      if (token == null) return false;
      final response = await http.delete(
        Uri.parse('$_backendBase/user/play-history'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 10));
      return response.statusCode == 200;
    } catch (e) {
      debugPrint('TripService clearPlayHistory error: $e');
      return false;
    }
  }

  // ── Session end ──────────────────────────────────────────────────────────

  Future<void> _endSession(String tripId) async {
    try {
      final headers = <String, String>{'Content-Type': 'application/json'};
      final token = await AuthService.getIdToken();
      if (token != null) headers['Authorization'] = 'Bearer $token';
      await http.post(
        Uri.parse('$_backendBase/session/end'),
        headers: headers,
        body: jsonEncode({'device_id': _deviceId}),
      ).timeout(const Duration(seconds: 10));
    } catch (e) {
      debugPrint('TripService endSession error: $e');
    }
  }

  // ── Tour enrollment ──────────────────────────────────────────────────────

  Future<bool> joinTour(String tourId) async {
    try {
      final token = await AuthService.getIdToken();
      if (token == null) return false;
      final response = await http.post(
        Uri.parse('$_backendBase/user/tours/$tourId/join'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
      ).timeout(const Duration(seconds: 10));
      return response.statusCode == 200;
    } catch (e) {
      debugPrint('TripService joinTour error: $e');
      return false;
    }
  }

  Future<bool> leaveTour(String tourId) async {
    try {
      final token = await AuthService.getIdToken();
      if (token == null) return false;
      final response = await http.post(
        Uri.parse('$_backendBase/user/tours/$tourId/leave'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
      ).timeout(const Duration(seconds: 10));
      return response.statusCode == 200;
    } catch (e) {
      debugPrint('TripService leaveTour error: $e');
      return false;
    }
  }

  @override
  void dispose() {
    _pingTimer?.cancel();
    _breatheTimer?.cancel();
    super.dispose();
  }
}
