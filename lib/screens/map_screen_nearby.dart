part of 'map_screen.dart';

/// Nearby POIs card widget.
extension NearbyWidgets on _MapScreenState {
  IconData _iconForPoiType(String? type) {
    switch (type?.toLowerCase()) {
      case 'city': return Icons.location_city;
      case 'town': return Icons.home_work;
      case 'neighborhood': return Icons.map;
      default: return Icons.place;
    }
  }

  Widget buildNearbyCard() {
    if (!_nearbyVisible) return const SizedBox.shrink();
    final top = MediaQuery.of(context).padding.top + 8 + 40 + 8;
    final pois = _tripService.nearbyPois;
    final radius = _tripService.nearbyRadiusMiles;

    return Positioned(
      top: top,
      left: 16,
      right: 16,
      child: Card(
        elevation: 6,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        color: Colors.white,
        surfaceTintColor: Colors.transparent,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 220),
          child: pois.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'Nothing within $radius ${radius == 1 ? "mile" : "miles"}.\nExpand your distance limit in Settings → Explore Settings.',
                    style: const TextStyle(color: Colors.grey, fontSize: 13),
                  ),
                )
              : ListView.separated(
                  controller: _nearbyScrollController,
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: pois.length,
                  separatorBuilder: (_, _) => const Divider(height: 1, indent: 56),
                  itemBuilder: (_, i) {
                    final poi = pois[i];
                    return ListTile(
                      dense: true,
                      leading: Icon(_iconForPoiType(poi.locationType),
                          color: _kTeal, size: 20),
                      title: Text(poi.name,
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      subtitle: Text('${poi.distanceMiles} mi',
                          style: const TextStyle(fontSize: 11, color: Colors.grey)),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Learn
                          SizedBox(
                            height: 28,
                            child: OutlinedButton.icon(
                              onPressed: (poi.hasPreview && !_learnPlaying && _loadingLearnPoiId == null)
                                  ? () async {
                                      setState(() => _loadingLearnPoiId = poi.id);
                                      try {
                                        await _tripService.learnPoi(poi);
                                      } catch (_) {
                                        if (mounted) {
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            const SnackBar(content: Text('No preview available')),
                                          );
                                        }
                                      } finally {
                                        if (mounted) setState(() => _loadingLearnPoiId = null);
                                      }
                                    }
                                  : null,
                              icon: _loadingLearnPoiId == poi.id
                                  ? const SizedBox(
                                      width: 14, height: 14,
                                      child: CircularProgressIndicator(strokeWidth: 2))
                                  : const Icon(Icons.play_circle_outline, size: 14),
                              label: const Text('Learn', style: TextStyle(fontSize: 11)),
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 8),
                                minimumSize: Size.zero,
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          // Save
                          SizedBox(
                            height: 28,
                            child: OutlinedButton.icon(
                              onPressed: () => _tripService.toggleSavePoi(poi.id),
                              icon: Icon(
                                poi.isSaved ? Icons.bookmark : Icons.bookmark_border,
                                size: 14,
                                color: poi.isSaved ? _kTeal : null,
                              ),
                              label: Text(poi.isSaved ? 'Saved' : 'Save',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: poi.isSaved ? _kTeal : null,
                                  )),
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 8),
                                minimumSize: Size.zero,
                                side: poi.isSaved
                                    ? const BorderSide(color: _kTeal)
                                    : null,
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          // Go
                          SizedBox(
                            height: 28,
                            child: OutlinedButton.icon(
                              onPressed: () async {
                                final name = Uri.encodeComponent(poi.name);
                                final uri = Uri.parse(
                                    'geo:${poi.lat},${poi.lng}?q=${poi.lat},${poi.lng}($name)');
                                if (await canLaunchUrl(uri)) {
                                  await launchUrl(uri,
                                      mode: LaunchMode.externalApplication);
                                }
                              },
                              icon: const Icon(Icons.directions, size: 14),
                              label: const Text('Go', style: TextStyle(fontSize: 11)),
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 8),
                                minimumSize: Size.zero,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ),
    );
  }
}
