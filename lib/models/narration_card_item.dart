import '../services/trip_service.dart';

enum NarrationCardState { active, played }

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
  /// Dropped after playback to save memory.
  String? audioBase64;

  NarrationCardState state;
  final DateTime addedAt;
  DateTime? playedAt;

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
