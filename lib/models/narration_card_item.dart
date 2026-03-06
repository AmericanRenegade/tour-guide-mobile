import 'dart:async';
import '../services/trip_service.dart';

enum NarrationCardState { active, queued, played }

enum TriviaPhase { question, interstitial, answer }

/// A single card in the narration carousel.
/// Wraps PendingNarration with carousel state and trivia grouping.
class NarrationCardItem {
  final String id;
  final String locationName;
  final String narrator;
  final String? guidePhotoUrl;
  final String? storyTitle;
  String contentType;
  final String? groupId;
  int groupSeq;
  final int? revealDelayS;
  final String narrationText;

  /// Audio for the primary content (question for trivia, story otherwise).
  /// Kept after playback so users can re-listen.
  String? audioBase64;

  NarrationCardState state;
  final DateTime addedAt;
  DateTime? playedAt;
  bool liked;
  final bool isPlaceholder;

  /// Last playback position — stored when audio pauses/stops so replay can resume.
  Duration lastPosition = Duration.zero;

  /// True when this card's audio is paused by the user (or swipe-away).
  bool paused = false;

  /// Trivia interstitial: waiting for user to reveal the answer.
  bool waitingForReveal = false;
  int countdownSeconds = 0;
  Completer<void>? revealCompleter;

  // ── Trivia single-card support ──

  TriviaPhase? triviaPhase;
  String? answerText;
  String? answerAudioBase64;

  NarrationCardItem({
    required this.id,
    required this.locationName,
    required this.narrator,
    this.guidePhotoUrl,
    this.storyTitle,
    required this.contentType,
    this.groupId,
    this.groupSeq = 0,
    this.revealDelayS,
    this.narrationText = '',
    this.audioBase64,
    this.state = NarrationCardState.active,
    this.triviaPhase,
    this.liked = false,
    this.isPlaceholder = false,
    DateTime? addedAt,
  }) : addedAt = addedAt ?? DateTime.now();

  factory NarrationCardItem.fromPending(PendingNarration p) {
    final isTrivia = p.contentType.startsWith('trivia_');
    return NarrationCardItem(
      id: p.narrationId,
      locationName: p.locationName,
      narrator: p.narrator,
      guidePhotoUrl: p.guidePhotoUrl,
      storyTitle: p.storyTitle,
      contentType: p.contentType,
      groupId: p.groupId,
      groupSeq: p.groupSeq,
      revealDelayS: p.revealDelayS,
      narrationText: p.narrationText,
      audioBase64: p.audioBase64,
      triviaPhase: isTrivia && p.isTriviaQuestion ? TriviaPhase.question : null,
    );
  }

  /// A placeholder card shown while waiting for the next tour stop.
  factory NarrationCardItem.waitingPlaceholder() {
    return NarrationCardItem(
      id: '__waiting__',
      locationName: '',
      narrator: '',
      contentType: 'waiting',
      isPlaceholder: true,
      state: NarrationCardState.queued,
    );
  }

  /// Absorb a trivia interstitial or answer into this card.
  void absorb(PendingNarration p) {
    if (p.isTriviaInterstitial) {
      triviaPhase = TriviaPhase.interstitial;
      contentType = p.contentType;
      groupSeq = p.groupSeq;
    } else if (p.isTriviaAnswer) {
      triviaPhase = TriviaPhase.answer;
      contentType = p.contentType;
      groupSeq = p.groupSeq;
      answerText = p.narrationText;
      answerAudioBase64 = p.audioBase64;
    }
  }

  /// Make this card the active playing card.
  void activate() {
    state = NarrationCardState.active;
    paused = false;
  }

  /// Clean up when this card loses focus / stops playing.
  void deactivate() {
    if (state == NarrationCardState.active) {
      state = NarrationCardState.played;
      playedAt = DateTime.now();
    }
    paused = false;
    waitingForReveal = false;
    countdownSeconds = 0;
    if (revealCompleter != null && !revealCompleter!.isCompleted) {
      revealCompleter!.complete();
    }
    revealCompleter = null;
  }

  bool get isPlayed => state == NarrationCardState.played;
  bool get isActive => state == NarrationCardState.active;
  bool get isTrivia => groupId != null && groupId!.isNotEmpty;
  bool get hasAudio => (audioBase64 != null && audioBase64!.isNotEmpty) ||
      (answerAudioBase64 != null && answerAudioBase64!.isNotEmpty);

  bool get isTourProgress => contentType == 'tour_progress';
  bool get isTriviaQuestion => triviaPhase == TriviaPhase.question;
  bool get isTriviaInterstitial => triviaPhase == TriviaPhase.interstitial;
  bool get isTriviaAnswer => triviaPhase == TriviaPhase.answer;

  /// Drop all audio data to free memory.
  void dropAudio() {
    audioBase64 = null;
    answerAudioBase64 = null;
  }
}
