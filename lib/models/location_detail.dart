class LocationDetail {
  final String id;
  final String name;
  final String? description;
  final double lat;
  final double lng;
  final String? photoUrl;
  final String? county;
  final String? stateCode;
  final String? locationType;
  final bool visited;

  const LocationDetail({
    required this.id,
    required this.name,
    this.description,
    required this.lat,
    required this.lng,
    this.photoUrl,
    this.county,
    this.stateCode,
    this.locationType,
    this.visited = false,
  });

  factory LocationDetail.fromJson(Map<String, dynamic> j) => LocationDetail(
        id: j['id'] as String,
        name: j['name'] as String,
        description: j['description'] as String?,
        lat: (j['lat'] as num).toDouble(),
        lng: (j['lng'] as num).toDouble(),
        photoUrl: j['photo_url'] as String?,
        county: j['county'] as String?,
        stateCode: j['state_code'] as String?,
        locationType: j['location_type'] as String?,
        visited: j['visited'] as bool? ?? false,
      );
}

class StorySummary {
  final String id;
  final String? title;
  final String? narrator;
  final String? bodyText;
  final double? audioDurationS;
  final int guideAudioCount;
  final String? guideName;
  final String? guideId;

  const StorySummary({
    required this.id,
    this.title,
    this.narrator,
    this.bodyText,
    this.audioDurationS,
    this.guideAudioCount = 0,
    this.guideName,
    this.guideId,
  });

  factory StorySummary.fromJson(Map<String, dynamic> j) => StorySummary(
        id: j['id'] as String,
        title: j['title'] as String?,
        narrator: j['narrator'] as String?,
        bodyText: j['body_text'] as String?,
        audioDurationS: (j['audio_duration_s'] as num?)?.toDouble(),
        guideAudioCount: (j['guide_audio_count'] as num?)?.toInt() ?? 0,
        guideName: j['guide_name'] as String?,
        guideId: j['guide_id'] as String?,
      );
}
