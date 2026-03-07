part of 'map_screen.dart';

/// Narration carousel widget builders.
extension CarouselWidgets on _MapScreenState {
  Widget buildNarrationCarousel() {
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
      bottom: _carouselVisible ? 120 : -600,
      left: 0,
      right: 0,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 500),
        opacity: _carouselOpacity,
        child: _carouselItems.isEmpty
            ? const SizedBox.shrink()
            : _ExpandablePageView(
                controller: _carouselController,
                physics: const BouncingScrollPhysics(),
                onPageChanged: _onCarouselPageChanged,
                itemCount: _carouselItems.length,
                itemBuilder: (context, index) {
                  return buildCarouselCard(
                    _carouselItems[index],
                    index == _activeCardIndex,
                  );
                },
              ),
      ),
    );
  }

  Widget buildCarouselCard(NarrationCardItem item, bool isActive) {
    // Waiting placeholder card
    if (item.isPlaceholder) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Card(
          elevation: 6,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          color: Colors.white,
          surfaceTintColor: Colors.transparent,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.explore, color: _kTeal.withValues(alpha: 0.4), size: 40),
                const SizedBox(height: 12),
                Text(
                  'Waiting for next tour stop...',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    color: Colors.grey.shade600,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final isQueued = item.state == NarrationCardState.queued;
    final realCards = _carouselItems.where((c) => !c.isPlaceholder);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Card(
        elevation: 6,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        color: Colors.white,
        surfaceTintColor: Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // "Playing in Xs..." banner for queued cards with breathe delay
              if (isQueued && item.countdownSeconds > 0) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  margin: const EdgeInsets.only(bottom: 10),
                  decoration: BoxDecoration(
                    color: _kTeal.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'Playing in ${item.countdownSeconds}s...',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: _kTeal.withValues(alpha: 0.8),
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
              // Top row: guide avatar + title + narrator
              Row(
                children: [
                  _buildCardAvatar(item, 56),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (isActive)
                          _MarqueeText(
                            text: _cardTitle(item),
                            style: const TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 18),
                          )
                        else
                          Text(
                            _cardTitle(item),
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        if (item.locationName.isNotEmpty)
                          Text(
                            item.locationName,
                            style: const TextStyle(color: Colors.grey, fontSize: 13),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        if (item.narrator.isNotEmpty && !item.isTriviaInterstitial)
                          Text(
                            item.narrator,
                            style: const TextStyle(color: Colors.grey, fontSize: 13),
                          ),
                      ],
                    ),
                  ),
                  if (realCards.length > 1)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: _kTeal.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        '${realCards.toList().indexOf(item) + 1} of ${realCards.length}',
                        style: const TextStyle(
                          color: _kTeal,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                ],
              ),
              // Trivia interstitial: countdown or tap-to-reveal (active only)
              if (isActive && item.isTriviaInterstitial && item.waitingForReveal) ...[
                const SizedBox(height: 16),
                if (item.countdownSeconds > 0) ...[
                  Text(
                    'Answer in ${item.countdownSeconds} s...',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF7C3AED),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                SizedBox(
                  width: double.infinity,
                  height: 44,
                  child: ElevatedButton.icon(
                    onPressed: _revealTriviaAnswer,
                    icon: const Icon(Icons.lightbulb_outline, size: 20),
                    label: Text(
                      item.countdownSeconds > 0 ? 'Reveal Now' : 'Tap to Reveal Answer',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF7C3AED),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
                    ),
                  ),
                ),
              ],
              // Controls row: Play/Pause + Like + Feedback
              if (!item.isTourProgress && !item.isTriviaInterstitial) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    // Play / Pause
                    () {
                      final cardIndex = _carouselItems.indexOf(item);
                      final showPause = isActive && !item.paused;
                      final buttonLabel = showPause
                          ? 'Pause'
                          : item.completed
                              ? 'Replay'
                              : 'Play';
                      return SizedBox(
                        height: 42,
                        width: 110,
                        child: ElevatedButton.icon(
                          onPressed: () {
                            if (isActive) {
                              _togglePause();
                            } else if (cardIndex >= 0) {
                              _activateCard(cardIndex, skipBreathe: true);
                            }
                          },
                          icon: Icon(
                            showPause
                                ? Icons.pause
                                : item.completed
                                    ? Icons.replay
                                    : Icons.play_arrow,
                            size: 22,
                          ),
                          label: Text(
                            buttonLabel,
                            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: showPause
                                ? const Color(0xFFFBBF24)
                                : const Color(0xFF22C55E),
                            foregroundColor: showPause ? Colors.black87 : Colors.white,
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(21),
                            ),
                          ),
                        ),
                      );
                    }(),
                    const SizedBox(width: 10),
                    // Like (heart)
                    SizedBox(
                      width: 42,
                      height: 42,
                      child: IconButton(
                        padding: EdgeInsets.zero,
                        icon: Icon(
                          item.liked ? Icons.favorite : Icons.favorite_border,
                          color: item.liked ? Colors.red : Colors.grey.shade400,
                          size: 28,
                        ),
                        onPressed: () {
                          setState(() => item.liked = !item.liked);
                        },
                      ),
                    ),
                    const Spacer(),
                    // Feedback
                    GestureDetector(
                      onTap: () {},
                      child: const Text(
                        'Feedback',
                        style: TextStyle(
                          fontSize: 15,
                          color: Color(0xFF2563EB),
                          decoration: TextDecoration.underline,
                          decorationColor: Color(0xFF2563EB),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _cardTitle(NarrationCardItem item) {
    if (item.isTriviaQuestion) return 'Trivia';
    if (item.isTriviaInterstitial) return 'Think About It...';
    if (item.isTriviaAnswer) return 'Answer';
    if ((item.storyTitle ?? '').isNotEmpty) return item.storyTitle!;
    return item.locationName;
  }

  Widget _buildCardAvatar(NarrationCardItem item, double size) {
    if (item.isTourProgress) {
      return Container(
        width: size, height: size,
        decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFFFFF8E1)),
        child: Icon(Icons.emoji_events, color: const Color(0xFFF9A825), size: size * 0.53),
      );
    }
    if (item.isTriviaQuestion) {
      return Container(
        width: size, height: size,
        decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFFF3E8FF)),
        child: Center(child: Text('\u2753', style: TextStyle(fontSize: size * 0.47))),
      );
    }
    if (item.isTriviaInterstitial) {
      return Container(
        width: size, height: size,
        decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFFF3E8FF)),
        child: Icon(Icons.timer, color: const Color(0xFF7C3AED), size: size * 0.53),
      );
    }
    if (item.isTriviaAnswer) {
      return Container(
        width: size, height: size,
        decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFFDCFCE7)),
        child: Center(child: Text('\u{1F4A1}', style: TextStyle(fontSize: size * 0.47))),
      );
    }
    if (item.guidePhotoUrl != null) {
      return ClipOval(
        child: Image.network(
          item.guidePhotoUrl!,
          width: size, height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _fallbackAvatarSized(size),
        ),
      );
    }
    return _fallbackAvatarSized(size);
  }

  Widget _fallbackAvatarSized(double size) {
    return Container(
      width: size, height: size,
      decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFFe0f2f1)),
      child: Icon(Icons.volume_up, color: _kTeal, size: size * 0.5),
    );
  }
}
