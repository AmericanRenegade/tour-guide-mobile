import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../auth_service.dart';

enum TripState { idle, active, paused }

/// Represents a narration received from a /ping response.
class PendingNarration {
  final String locationName;
  final String narrator;
  final String audioBase64;
  final String narrationText;
  final String? guidePhotoUrl;
  final String? locationId;

  const PendingNarration({
    required this.locationName,
    required this.narrator,
    required this.audioBase64,
    this.narrationText = '',
    this.guidePhotoUrl,
    this.locationId,
  });
}

/// Manages trip state, GPS pinging, and narration delivery.
///
/// State machine:
///   idle → active    startTrip()   force_new_session ping → save tripId → start 15s timer
///   active → paused  pauseTrip()   cancel timer, keep tripId
///   paused → active  resumeTrip()  restart 15s timer
///   active/paused→idle stopTrip()  POST /session/end → clear tripId + timer
class TripService extends ChangeNotifier {
  static const String _backendBase =
      'https://tour-guide-backend-production.up.railway.app';
  static const Duration _pingInterval = Duration(seconds: 15);

  TripState _tripState = TripState.idle;
  String? _tripId;
  String _deviceId = '';
  Timer? _pingTimer;
  PendingNarration? _pendingNarration;

  TripState get tripState => _tripState;
  String? get tripId => _tripId;
  PendingNarration? get pendingNarration => _pendingNarration;
  bool get isActive => _tripState == TripState.active;

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
    _pendingNarration = null;
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

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final sid = data['session_id'] as String?;
        if (sid != null && _tripId == null) { _tripId = sid; }

        final narrationData = data['narration'];
        if (narrationData != null) {
          final narration = narrationData as Map<String, dynamic>;
          final audio = narration['audio'] as String?;
          if (audio != null && audio.isNotEmpty) {
            final guideId = narration['guide_id'] as String?;
            _pendingNarration = PendingNarration(
              locationName: narration['subject'] as String? ?? '',
              narrator: narration['narrator'] as String? ?? '',
              audioBase64: audio,
              narrationText: narration['narration_text'] as String? ?? '',
              guidePhotoUrl: guideId != null
                  ? '$_backendBase/tour-guides/$guideId/photo'
                  : null,
              locationId: narration['location_id'] as String?,
            );
            notifyListeners();
          }
        }
      }
    } catch (e) {
      debugPrint('TripService ping error: $e');
    }
  }

  Future<void> _endSession(String tripId) async {
    try {
      final headers = <String, String>{'Content-Type': 'application/json'};
      final token = await AuthService.getIdToken();
      if (token != null) headers['Authorization'] = 'Bearer $token';
      await http.post(
        Uri.parse('$_backendBase/session/end'),
        headers: headers,
        body: jsonEncode({'session_id': tripId}),
      ).timeout(const Duration(seconds: 10));
    } catch (e) {
      debugPrint('TripService endSession error: $e');
    }
  }

  /// Called by MapScreen after audio finishes playing to clear the narration card.
  void clearNarration() {
    _pendingNarration = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _pingTimer?.cancel();
    super.dispose();
  }
}
