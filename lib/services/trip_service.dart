import 'dart:async';
import 'dart:convert';
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
  });

  bool get isTourProgress => contentType == 'tour_progress' || topic == 'tour_progress';
  bool get isTriviaQuestion => contentType == 'trivia_question';
  bool get isTriviaInterstitial => contentType == 'trivia_interstitial';
  bool get isTriviaAnswer => contentType == 'trivia_answer';
  bool get isTrivia => contentType.startsWith('trivia_');
}

/// Manages trip state, GPS pinging, and narration queue.
///
/// State machine:
///   idle → active    startTrip()   force_new_session ping → save tripId → start 15s timer
///   active → paused  pauseTrip()   cancel timer, keep tripId
///   paused → active  resumeTrip()  restart 15s timer
///   active/paused→idle stopTrip()  POST /session/end → clear tripId + timer
///
/// Narration flow:
///   /ping queues stories server-side → mobile eagerly dequeues all into local queue
///   → MapScreen plays sequentially → advanceQueue() confirms each as played
class TripService extends ChangeNotifier {
  static const String _backendBase =
      'https://tour-guide-backend-production.up.railway.app';
  static const Duration _pingInterval = Duration(seconds: 15);

  TripState _tripState = TripState.idle;
  String? _tripId;
  String _deviceId = '';
  Timer? _pingTimer;

  // ── Narration queue ───────────────────────────────────────────────────────
  final List<PendingNarration> _narrationQueue = [];
  bool _draining = false;
  int _totalNarrationsInBatch = 0;
  int _playedInBatch = 0;

  TripState get tripState => _tripState;
  String? get tripId => _tripId;
  String get deviceId => _deviceId;
  bool get isActive => _tripState == TripState.active;

  /// The narration at the front of the local queue (being played or about to play).
  PendingNarration? get pendingNarration =>
      _narrationQueue.isNotEmpty ? _narrationQueue.first : null;

  /// Number of narrations remaining in the local queue.
  int get narrationQueueLength => _narrationQueue.length;

  /// Total narrations in the current batch (for "X of Y" display).
  int get totalNarrationsInBatch => _totalNarrationsInBatch;

  /// 1-based index of the narration currently playing.
  int get currentPlayingIndex => _playedInBatch + 1;

  TripService() {
    _loadDeviceId();
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

  // ── Trip lifecycle ──────────────────────────────────────────────────────────

  Future<void> startTrip() async {
    if (_tripState != TripState.idle) return;
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
    _clearQueue();
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
          permission == LocationPermission.deniedForever) return;

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      ).timeout(const Duration(seconds: 10));

      final headers = <String, String>{'Content-Type': 'application/json'};
      final token = await AuthService.getIdToken();
      if (token != null) headers['Authorization'] = 'Bearer $token';

      // Include preferred guide as preferred_narrators if set
      final prefs = await SharedPreferences.getInstance();
      final preferredGuide = prefs.getString('preferred_guide') ?? '';
      final preferredNarrators = preferredGuide.isNotEmpty ? [preferredGuide] : <String>[];

      final response = await http.post(
        Uri.parse('$_backendBase/ping'),
        headers: headers,
        body: jsonEncode({
          'device_id': _deviceId,
          'latitude': position.latitude,
          'longitude': position.longitude,
          'force_new_session': forceNewSession,
          'preferred_narrators': preferredNarrators,
        }),
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final sid = data['session_id'] as String?;
        if (sid != null && _tripId == null) { _tripId = sid; }

        final pendingCount = (data['pending_count'] as num?)?.toInt() ?? 0;
        if (pendingCount > 0 && _tripId != null) {
          _drainServerQueue();
        }
      }
    } catch (e) {
      debugPrint('TripService ping error: $e');
    }
  }

  // ── Dequeue: eagerly pull all pending narrations from server ──────────────

  Future<void> _drainServerQueue() async {
    if (_draining || _tripId == null) return;
    _draining = true;
    try {
      while (true) {
        final result = await _dequeueGroup();
        if (result == null) break; // nothing left
      }
    } finally {
      _draining = false;
    }
  }

  /// Dequeue a narration group from the server. Returns the first narration
  /// in the group, or null if nothing is available. All narrations in the
  /// group are added to the local queue.
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

        // Check for narrations array (group-aware response)
        final narrationsList = data['narrations'] as List?;
        PendingNarration? first;

        if (narrationsList != null && narrationsList.isNotEmpty) {
          // Parse all narrations in the group
          for (final item in narrationsList) {
            final m = item as Map<String, dynamic>;
            final guideId = m['guide_id'] as String?;
            final narration = PendingNarration(
              narrationId: m['narration_id'] as String,
              locationName: m['subject'] as String? ?? '',
              narrator: m['narrator'] as String? ?? '',
              audioBase64: m['audio'] as String? ?? '',
              narrationText: m['narration_text'] as String? ?? '',
              guidePhotoUrl: guideId != null
                  ? '$_backendBase/tour-guides/$guideId/photo'
                  : null,
              locationId: m['location_id'] as String?,
              topic: data['topic'] as String? ?? 'location',
              tourId: m['tour_id'] as String?,
              storyTitle: m['story_title'] as String?,
              contentType: m['content_type'] as String? ?? 'story',
              groupId: data['group_id'] as String?,
              groupSeq: (m['group_seq'] as num?)?.toInt() ?? 0,
              revealDelayS: (m['reveal_delay_s'] as num?)?.toInt(),
            );
            _narrationQueue.add(narration);
            first ??= narration;
          }
        } else {
          // Fallback: flat fields (backward compat for older servers)
          final guideId = data['guide_id'] as String?;
          first = PendingNarration(
            narrationId: data['narration_id'] as String,
            locationName: data['subject'] as String? ?? '',
            narrator: data['narrator'] as String? ?? '',
            audioBase64: data['audio'] as String? ?? '',
            narrationText: data['narration_text'] as String? ?? '',
            guidePhotoUrl: guideId != null
                ? '$_backendBase/tour-guides/$guideId/photo'
                : null,
            locationId: data['location_id'] as String?,
            topic: data['topic'] as String? ?? 'location',
            tourId: data['tour_id'] as String?,
            storyTitle: data['story_title'] as String?,
            contentType: data['content_type'] as String? ?? 'story',
          );
          _narrationQueue.add(first);
        }

        _totalNarrationsInBatch = _narrationQueue.length + _playedInBatch;
        notifyListeners();
        return first;
      }
    } catch (e) {
      debugPrint('TripService dequeue error: $e');
    }
    return null;
  }

  // ── Queue management (called by MapScreen after playback) ─────────────────

  /// Remove the front narration after playback and confirm it as played.
  void advanceQueue() {
    if (_narrationQueue.isEmpty) return;
    final played = _narrationQueue.removeAt(0);
    _playedInBatch++;

    // Fire-and-forget played confirmation to backend
    _confirmPlayed(played.narrationId);

    if (_narrationQueue.isEmpty) {
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

  void _clearQueue() {
    _narrationQueue.clear();
    _totalNarrationsInBatch = 0;
    _playedInBatch = 0;
    _draining = false;
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
    super.dispose();
  }
}
