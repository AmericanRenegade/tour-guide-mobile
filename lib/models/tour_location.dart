class TourLocation {
  final String id;
  final String name;
  final double lat;
  final double lng;
  final String? photoUrl;
  final String? county;
  final String? stateCode;
  final int storyCount;
  final bool visited;

  const TourLocation({
    required this.id,
    required this.name,
    required this.lat,
    required this.lng,
    this.photoUrl,
    this.county,
    this.stateCode,
    this.storyCount = 0,
    this.visited = false,
  });

  factory TourLocation.fromJson(Map<String, dynamic> j) => TourLocation(
        id: j['id'] as String,
        name: j['name'] as String,
        lat: (j['lat'] as num).toDouble(),
        lng: (j['lng'] as num).toDouble(),
        photoUrl: j['photo_url'] as String?,
        county: j['county'] as String?,
        stateCode: j['state_code'] as String?,
        storyCount: (j['story_count'] as num?)?.toInt() ?? 0,
        visited: j['visited'] as bool? ?? false,
      );
}
