import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

/// Handles base64 MP3 playback via just_audio.
class AudioService {
  final AudioPlayer _player = AudioPlayer();

  bool get isPlaying => _player.playing;

  /// Stream of current playback position (for narration text sync).
  Stream<Duration> get positionStream => _player.positionStream;

  /// Total duration of the current audio (available after setFilePath).
  Duration? get duration => _player.duration;

  /// Decode a base64-encoded MP3, write it to a temp file, play it,
  /// and return a Future that completes when playback finishes.
  Future<void> playBase64(String base64Audio) async {
    try {
      final bytes = base64Decode(base64Audio);
      final tempDir = await getTemporaryDirectory();
      final tempFile = File('${tempDir.path}/narration.mp3');
      await tempFile.writeAsBytes(bytes);
      await _player.setFilePath(tempFile.path);
      await _player.play();
      // Wait until playback completes or is stopped.
      await _player.playerStateStream.firstWhere((s) =>
          s.processingState == ProcessingState.completed ||
          s.processingState == ProcessingState.idle);
    } catch (e) {
      debugPrint('AudioService.playBase64 error: $e');
    }
  }

  Future<void> pause() => _player.pause();

  Future<void> resume() => _player.play();

  Future<void> stop() => _player.stop();

  bool _muted = false;
  bool get isMuted => _muted;

  Future<void> toggleMute() async {
    _muted = !_muted;
    await _player.setVolume(_muted ? 0.0 : 1.0);
  }

  void dispose() => _player.dispose();
}
