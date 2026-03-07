import 'dart:async';
import '../services/trip_service.dart';

enum NarrationCardState { active, queued, played }

// ── Playback phase ──────────────────────────────────────────────────────────

enum PhaseType { audio, tourProgressDelay, triviaInterstitial, breatheDelay }

/// A single step in a card's playback sequence.
class PlaybackPhase {
  final PhaseType type;
  final String narrationId;
  final String contentType; // 'story', 'trivia_question', etc.
  String? audioBase64; // mutable for dropAudio()
  final String? narrationText;
  final int? revealDelayS;

  PlaybackPhase({
    required this.type,
    required this.narrationId,
    required this.contentType,
    this.audioBase64,
    this.narrationText,
    this.revealDelayS,
  });

  bool get isTriviaQuestion => contentType == 'trivia_question';
  bool get isTriviaInterstitial => contentType == 'trivia_interstitial';
  bool get isTriviaAnswer => contentType == 'trivia_answer';
  bool get isTourProgress =>
      contentType == 'tour_progress';
}

// ── Narration card ──────────────────────────────────────────────────────────

/// A single card in the narration carousel.
/// Holds an ordered list of PlaybackPhases (1 for stories, 3 for trivia).
class NarrationCardItem {
  final String id;
  final String locationName;
  final String narrator;
  final String? guidePhotoUrl;
  final String? storyTitle;
  final String? groupId;
  final bool isPlaceholder;

  /// All narration IDs in this group (for batch advanceGroup).
  final List<String> narrationIds;

  /// Ordered playback sequence.
  final List<PlaybackPhase> phases;
  int _phaseIndex = 0;

  NarrationCardState state;
  final DateTime addedAt;
  DateTime? playedAt;
  bool liked;

  /// Resume point for the current phase's audio.
  Duration lastPosition = Duration.zero;

  /// True when this card's audio is paused by the user (or swipe-away).
  bool paused = false;

  /// True when all phases finished naturally (not interrupted by swipe).
  bool completed = false;

  /// Trivia interstitial: waiting for user to reveal the answer.
  bool waitingForReveal = false;
  int countdownSeconds = 0;
  Completer<void>? revealCompleter;

  NarrationCardItem({
    required this.id,
    required this.locationName,
    required this.narrator,
    this.guidePhotoUrl,
    this.storyTitle,
    this.groupId,
    required this.phases,
    List<String>? narrationIds,
    this.state = NarrationCardState.active,
    this.liked = false,
    this.isPlaceholder = false,
    DateTime? addedAt,
  })  : narrationIds = narrationIds ?? phases.map((p) => p.narrationId).toList(),
        addedAt = addedAt ?? DateTime.now();

  // ── Phase navigation ────────────────────────────────────────────────────

  PlaybackPhase get currentPhase => phases[_phaseIndex];
  bool get hasMorePhases => _phaseIndex < phases.length - 1;

  /// Advance to next phase, reset lastPosition. Returns false if done.
  bool advancePhase() {
    if (_phaseIndex < phases.length - 1) {
      _phaseIndex++;
      lastPosition = Duration.zero;
      return true;
    }
    return false;
  }

  void resetPhases() {
    _phaseIndex = 0;
    lastPosition = Duration.zero;
  }

  // ── Factories ───────────────────────────────────────────────────────────

  /// Create a card from a group of narrations (sorted by groupSeq).
  /// For non-trivia, the list has exactly 1 element.
  factory NarrationCardItem.fromGroup(List<PendingNarration> group) {
    assert(group.isNotEmpty);
    final sorted = List<PendingNarration>.from(group)
      ..sort((a, b) => a.groupSeq.compareTo(b.groupSeq));

    final primary = sorted.first;
    final phases = <PlaybackPhase>[];
    final narrationIds = <String>[];

    for (final n in sorted) {
      narrationIds.add(n.narrationId);
      if (n.isTourProgress) {
        phases.add(PlaybackPhase(
          type: PhaseType.tourProgressDelay,
          narrationId: n.narrationId,
          contentType: n.contentType,
          narrationText: n.narrationText,
        ));
      } else if (n.isTriviaInterstitial) {
        phases.add(PlaybackPhase(
          type: PhaseType.triviaInterstitial,
          narrationId: n.narrationId,
          contentType: n.contentType,
          revealDelayS: n.revealDelayS,
        ));
      } else {
        // story, trivia_question, trivia_answer — all are audio phases
        phases.add(PlaybackPhase(
          type: PhaseType.audio,
          narrationId: n.narrationId,
          contentType: n.contentType,
          audioBase64: n.audioBase64,
          narrationText: n.narrationText,
        ));
      }
    }

    // Prepend a breathe delay phase (skipped on user-initiated plays)
    phases.insert(0, PlaybackPhase(
      type: PhaseType.breatheDelay,
      narrationId: primary.narrationId,
      contentType: 'breathe_delay',
    ));

    return NarrationCardItem(
      id: primary.narrationId,
      locationName: primary.locationName,
      narrator: primary.narrator,
      guidePhotoUrl: primary.guidePhotoUrl,
      storyTitle: primary.storyTitle,
      groupId: primary.groupId,
      phases: phases,
      narrationIds: narrationIds,
    );
  }

  /// Convenience: create from a single PendingNarration.
  factory NarrationCardItem.fromPending(PendingNarration p) {
    return NarrationCardItem.fromGroup([p]);
  }

  /// A placeholder card shown while waiting for the next tour stop.
  factory NarrationCardItem.waitingPlaceholder() {
    return NarrationCardItem(
      id: '__waiting__',
      locationName: '',
      narrator: '',
      phases: [
        PlaybackPhase(
          type: PhaseType.tourProgressDelay,
          narrationId: '__waiting__',
          contentType: 'waiting',
        ),
      ],
      isPlaceholder: true,
      state: NarrationCardState.queued,
    );
  }

  // ── Lifecycle ───────────────────────────────────────────────────────────

  void activate({bool skipBreathe = false}) {
    // If card finished playing, reset to beginning for replay
    if (completed) {
      _phaseIndex = 0;
      lastPosition = Duration.zero;
      completed = false;
    }
    // Skip breathe phase on user-initiated plays (swipe, replay, button)
    if (skipBreathe && _phaseIndex == 0 &&
        phases.isNotEmpty && phases[0].type == PhaseType.breatheDelay) {
      _phaseIndex = 1;
    }
    state = NarrationCardState.active;
    paused = false;
  }

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

  // ── Derived properties ──────────────────────────────────────────────────

  /// The "real" content phase (skipping breatheDelay).
  PlaybackPhase get _contentPhase =>
      currentPhase.type == PhaseType.breatheDelay && phases.length > 1
          ? phases[1]
          : currentPhase;

  String get contentType => _contentPhase.contentType;
  String get narrationText =>
      _contentPhase.narrationText ?? phases.first.narrationText ?? '';

  bool get isPlayed => state == NarrationCardState.played;
  bool get isActive => state == NarrationCardState.active;
  bool get isTrivia => groupId != null && groupId!.isNotEmpty;
  bool get hasAudio => phases.any((p) => p.audioBase64 != null && p.audioBase64!.isNotEmpty);

  bool get isTourProgress => _contentPhase.isTourProgress;
  bool get isTriviaQuestion => _contentPhase.isTriviaQuestion;
  bool get isTriviaInterstitial => _contentPhase.isTriviaInterstitial;
  bool get isTriviaAnswer => _contentPhase.isTriviaAnswer;

  /// Answer text for history display on played trivia cards.
  String? get answerText {
    final answer = phases.where((p) => p.isTriviaAnswer).firstOrNull;
    return answer?.narrationText;
  }

  /// Drop all audio data to free memory.
  void dropAudio() {
    for (final phase in phases) {
      phase.audioBase64 = null;
    }
  }
}
