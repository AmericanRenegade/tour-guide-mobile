part of 'map_screen.dart';

/// Learn / preview card widget.
extension LearnWidgets on _MapScreenState {
  Widget buildLearnCard() {
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
        color: Colors.white,
        surfaceTintColor: Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
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

  Widget _buildGuideAvatar(PendingNarration? narration) {
    if (narration?.isTourProgress == true) {
      return Container(
        width: 60, height: 60,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: Color(0xFFFFF8E1),
        ),
        child: const Icon(Icons.emoji_events, color: Color(0xFFF9A825), size: 32),
      );
    }
    if (narration?.isTriviaQuestion == true) {
      return Container(
        width: 60, height: 60,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: Color(0xFFF3E8FF),
        ),
        child: const Center(
          child: Text('\u2753', style: TextStyle(fontSize: 28)),
        ),
      );
    }
    if (narration?.isTriviaInterstitial == true) {
      return Container(
        width: 60, height: 60,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: Color(0xFFF3E8FF),
        ),
        child: const Icon(Icons.timer, color: Color(0xFF7C3AED), size: 32),
      );
    }
    if (narration?.isTriviaAnswer == true) {
      return Container(
        width: 60, height: 60,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: Color(0xFFDCFCE7),
        ),
        child: const Center(
          child: Text('\u{1F4A1}', style: TextStyle(fontSize: 28)),
        ),
      );
    }
    if (narration?.guidePhotoUrl != null) {
      return ClipOval(
        child: Image.network(
          narration!.guidePhotoUrl!,
          width: 60, height: 60,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _fallbackAvatar(),
        ),
      );
    }
    return _fallbackAvatar();
  }

  Widget _fallbackAvatar() {
    return Container(
      width: 60, height: 60,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: Color(0xFFe0f2f1),
      ),
      child: const Icon(Icons.volume_up, color: _kTeal, size: 30),
    );
  }
}
